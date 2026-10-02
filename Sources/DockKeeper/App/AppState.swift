import Foundation
import SwiftUI
import ApplicationServices  // AXIsProcessTrusted / kAXTrustedCheckOptionPrompt
import DockKeeperCore

/// Observable bridge between SwiftUI and the `DockKeeperCore` engine.
///
/// Owns the long-lived monitor (event sources) and coordinator (the single
/// owner of reconciliation) and exposes the settings the menu and preferences
/// bind to. Lives on the main actor.
@MainActor
final class AppState: ObservableObject {

    /// The live instance, exposed so the `dockkeeper://` URL handler and App
    /// Intents can funnel through the same control surface. Set on `init`;
    /// there is exactly one `AppState` for the app's lifetime, held strongly by
    /// the `@StateObject` in `DockKeeperApp`.
    static private(set) weak var shared: AppState?

    private let settings = Settings.shared
    private let controller: DockController
    private let monitor: DockMonitor
    private let coordinator: RecoveryCoordinator
    private let hotKeyCenter = HotKeyCenter()
    private let screenShareHider = ScreenShareHider()
    private let bottomDockGuardTap = BottomDockGuardTap()
    private let pointerBridgeTap = PointerBridgeTap()


    /// This process's own kernel identity, read once.
    ///
    /// It cannot change while the process lives — that is the entire property
    /// that makes it a liveness key — so re-reading it on every reconcile would
    /// be a `sysctl` per poll tick to learn something already known. `nil` means
    /// the read failed, and the publisher then writes nothing at all: a record
    /// whose writer cannot be proved alive is the unverifiable artifact
    /// DK-FR-015 exists to replace, so publishing none is the honest failure.
    private lazy var liveGuardWriterIdentity: ProcessIdentity? = ProcessIdentity.current()

    @Published var isEnabled: Bool {
        didSet {
            guard !isSyncingFromExternal else { return }
            settings.isEnabled = isEnabled
            applyEnabledState()
        }
    }

    @Published var lockEdge: DockOrientation {
        didSet {
            guard !isSyncingFromExternal else { return }
            settings.lockEdge = lockEdge
            // The guard is bottom-only, so leaving or entering `.bottom` arms or
            // releases the tap regardless of whether we reconcile below.
            applyBottomDockGuard()
            guard isEnabled else { return }
            // Apply immediately for snappy UX, then let the coordinator verify
            // (and re-pin) through the normal reconcile path.
            controller.forceOrientation(lockEdge)
            coordinator.requestReconcile()
        }
    }

    /// Launch DockKeeper at login. Source of truth is `SMAppService`; this
    /// mirrors it for the UI. Guarded against re-entrancy when we revert on
    /// failure.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLoginItem else { return }
            applyLaunchAtLogin()
        }
    }
    private var isSyncingLoginItem = false

    /// Guards the published-property didSets while syncing FROM settings
    /// (external CLI edits observed via KVO), so we don't write back or loop.
    private var isSyncingFromExternal = false

    /// User-facing note about the login-item state (approval needed, etc.).
    @Published private(set) var loginItemMessage: String?

    /// Whether a preferred display is stored at all (drives the "Any" row).
    @Published private(set) var hasPreferredDisplay = false

    /// `DisplayInfo.id` of the connected display the stored fingerprint
    /// resolves to (drives the menu checkmark); `nil` when no preference is
    /// stored or the display isn't connected / is ambiguous.
    @Published private(set) var preferredDisplaySelectionID: String?

    @Published private(set) var displays: [DisplayInfo] = []

    /// Last pin result, surfaced to the UI (e.g. "separate Spaces is on").
    ///
    /// Derived rather than stored, from the outcome *and* the guard's current
    /// decision: the separate-Spaces copy depends on the bottom-Dock guard's
    /// decision (#79), which can change between pin passes — a stored string
    /// would keep saying whatever was true at the last pass. The decision is
    /// the plan, not the tap's live state, so that copy claims no protection.
    var lastPinMessage: String? {
        lastPinOutcome?.userMessage(guardDecision: bottomDockGuardDecision)
    }
    /// Previous pin outcome, so the diagnostics log records transitions
    /// rather than one line per reconcile pass (#44). Published because
    /// `lastPinMessage` is derived from it.
    @Published private(set) var lastPinOutcome: PinOutcome?

    /// Recovery-state note (degraded / preferred display missing / error);
    /// `nil` when everything is healthy.
    @Published private(set) var statusMessage: String?

    /// One-line note that a cross-launch repair changed a system setting the
    /// user did not just ask for (DK-FR-013 S5). A silent mutation of a global
    /// preference is the one thing that would make this fix worse than the bug;
    /// this is the cheapest honest disclosure, on the surface the menu already
    /// has. Cleared by the next real screen-share transition.
    @Published private(set) var screenShareRepairMessage: String?

    /// Set when a launch repair `.adopt`ed a leftover hide, so the restore that
    /// eventually discharges it is announced instead of passing silently. Not
    /// published: it only decides which string the next transition writes.
    private var pendingRepairDisclosure = false

    /// Current recovery state — drives the state-distinct menu-bar icon.
    @Published private(set) var recoveryState: RecoveryState = .disabled

    /// Whether corrections are currently paused (DK-FR-009) — drives the menu's
    /// pause/resume section. Mirrors the coordinator via `onStateChange`.
    @Published private(set) var isPaused = false

    /// When a timed pause auto-resumes; `nil` when paused until resumed (or not
    /// paused). Drives the "Paused until …" menu note.
    @Published private(set) var pausedUntil: Date?

    /// Opt-in global hotkey (⌃⌥⌘D) to toggle pause (DK-FR-009). Off by default;
    /// registered only while on (kickoff rule 20 — no surprise global hotkey).
    @Published var pauseHotkeyEnabled: Bool {
        didSet {
            settings.pauseHotkeyEnabled = pauseHotkeyEnabled
            applyHotkeyState()
        }
    }

    /// Opt-in bounded diagnostics file (DK-PRIV-001 S2).
    @Published var diagnosticsFileEnabled: Bool {
        didSet {
            settings.diagnosticsFileEnabled = diagnosticsFileEnabled
            FileDiagnostics.shared.isEnabled = diagnosticsFileEnabled
        }
    }

    @Published var verboseLogging: Bool {
        didSet { settings.verboseLogging = verboseLogging }
    }

    /// Opt-in "hide the Dock while screen sharing" (DK-FR-011, ADR-011). Off by
    /// default. When on, a dedicated poll toggles Dock auto-hide for the
    /// duration of a screen capture and restores it after — only if the user
    /// wasn't already running auto-hide (`ScreenShareHider`). Gated on the
    /// private screen-watcher symbol resolving; `screenCaptureAvailable` drives
    /// the disabled-with-a-note UI when it doesn't.
    @Published var hideDockDuringScreenShare: Bool {
        didSet {
            settings.hideDockDuringScreenShare = hideDockDuringScreenShare
            applyScreenShareHiderState()
        }
    }

    /// Hold a bottom Dock on the preferred display in separate-Spaces mode by
    /// blocking the pointer summon that would move it (DK-FR-014, ADR-015).
    /// Opt-in, default false, and needs Accessibility. Every unmet precondition
    /// is a silent no-op that `--diagnostics` explains.
    @Published var lockBottomDockToDisplay: Bool {
        didSet {
            // Guarded like every other synced setting: without it, a CLI write
            // arriving through `syncFromSettings` would raise an unsolicited
            // system permission dialog, which DK-FR-014 S5 forbids.
            guard !isSyncingFromExternal else { return }
            settings.lockBottomDockToDisplay = lockBottomDockToDisplay
            // ADR-010's pattern, which ADR-015 claims to follow: prompt once, on
            // enable, only when untrusted. Without this the toggle is inert and
            // the caption asks for a permission nothing ever requests.
            if lockBottomDockToDisplay, !AXIsProcessTrusted() {
                requestAccessibilityPermission()
            }
            applyBottomDockGuard()
        }
    }

    /// The guard's latest decision, for the menu and `--diagnostics`.
    @Published private(set) var bottomDockGuardDecision: BottomDockGuard.Decision =
        .idle(.featureDisabled)

    /// Carry the pointer across a side Dock's edge to the other display (fork
    /// DK-FR-F01, ADR-F002). Opt-in, default false, needs Accessibility; asks
    /// for it once on enable, like the bottom-Dock guard.
    @Published var bridgePointerAcrossDockEdge: Bool {
        didSet {
            guard !isSyncingFromExternal else { return }
            settings.bridgePointerAcrossDockEdge = bridgePointerAcrossDockEdge
            if bridgePointerAcrossDockEdge, !AXIsProcessTrusted() {
                requestAccessibilityPermission()
            }
            applyPointerBridge()
        }
    }

    /// The bridge's latest decision, for the Advanced-tab caption.
    @Published private(set) var pointerBridgeDecision: PointerBridge.Decision = .idle(.featureDisabled)

    var pointerBridgeCaption: String { PointerBridge.caption(for: pointerBridgeDecision) }

    /// Whether the private screen-watcher symbol resolved on this macOS. Fixed
    /// for the process lifetime; drives the Advanced-tab "unavailable" note.
    let screenCaptureAvailable = ScreenCapture.isAvailable

    /// Whether the private Dock *auto-hide* symbols resolved. Distinct from
    /// `screenCaptureAvailable` (SkyLight) and from `CoreDock.isAvailable`
    /// (the orientation pair): the manual recovery writes auto-hide, so this is
    /// the only honest gate for it. Held here rather than read from the view so
    /// the private-API wrapper stays behind the adapter (kickoff rule 8).
    let coreDockAutoHideAvailable = CoreDock.isAutoHideAvailable

    /// Opt-in window restore across a pin (ADR-010). Enabling without the
    /// Accessibility grant prompts once (the caption is the contextual
    /// explanation shown *before* this point — TDD §10); the toggle may stay on
    /// while the grant is pending — `WindowLayoutPreserver` no-ops until trusted.
    @Published var preserveWindowLayout: Bool {
        didSet {
            settings.preserveWindowLayout = preserveWindowLayout
            if preserveWindowLayout, !AXIsProcessTrusted() {
                requestAccessibilityPermission()
            }
            refreshAccessibilityStatus()
        }
    }

    /// Whether Accessibility is currently granted — drives the "waiting for
    /// permission" caption. Refreshed on toggle and when the app reactivates
    /// (the user may grant it in System Settings and switch back).
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    init() {
        let controller = DockController(settings: settings)
        self.controller = controller
        self.monitor = DockMonitor(settings: settings)
        self.coordinator = RecoveryCoordinator(
            controller: controller,
            settings: settings,
            machine: RecoveryMachine(config: RecoveryMachine.Config(debounce: settings.restoreDelay))
        )
        self.isEnabled = settings.isEnabled
        self.lockEdge = settings.lockEdge
        self.diagnosticsFileEnabled = settings.diagnosticsFileEnabled
        self.verboseLogging = settings.verboseLogging
        self.preserveWindowLayout = settings.preserveWindowLayout
        self.pauseHotkeyEnabled = settings.pauseHotkeyEnabled
        self.hideDockDuringScreenShare = settings.hideDockDuringScreenShare
        self.lockBottomDockToDisplay = settings.lockBottomDockToDisplay
        self.bridgePointerAcrossDockEdge = settings.bridgePointerAcrossDockEdge
        FileDiagnostics.shared.isEnabled = settings.diagnosticsFileEnabled
        // System is the source of truth for login-item state.
        self.launchAtLogin = LoginItemManager.isEnabled
        self.loginItemMessage = LoginItemManager.statusMessage
        self.displays = DisplayManager.activeDisplays()

        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            self.coordinator.handle(event)
            switch event {
            case .settingsChanged:
                self.syncFromSettings()
            case .displayReconfigured, .screenParametersChanged:
                self.refreshDisplays()
            case .pollTick:
                // ADR-005's safety net now covers the guard's geometry too: a
                // missed reconfiguration event would otherwise leave clamp zones
                // computed from frames that no longer describe the desk.
                self.refreshDisplays()
            default:
                break
            }
        }
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            if state != self.recoveryState {
                FileDiagnostics.shared.note("state", String(describing: state))
            }
            self.recoveryState = state
            self.statusMessage = state.userMessage
            self.isPaused = (state == .paused)
            self.pausedUntil = self.coordinator.pausedUntil
        }
        hotKeyCenter.onHotKey = { [weak self] in self?.togglePause() }
        // Accessibility is granted in System Settings, i.e. in another app. The
        // Preferences view already polls on appear and on activation, but a user
        // who closes Preferences, grants, and comes back would never re-arm — the
        // observer has to live on AppState, not on the view.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityStatus() }
        }

        screenShareHider.onTransition = { [weak self] transition in
            // State only — no PII (DK-PRIV-001 S2). Mirrors the pin/state notes.
            FileDiagnostics.shared.note("screenshare", transition.rawValue)
            guard let self else { return }
            switch transition {
            case .repaired:
                break                       // the note is set by the repair path itself
            case .restored where self.pendingRepairDisclosure:
                // This is the restore an `.adopt` was waiting for: the cross-launch
                // mutation has now happened, so say so rather than going quiet.
                self.pendingRepairDisclosure = false
                self.screenShareRepairMessage = Self.repairRestoredMessage
            case .restored, .hidden, .manual:
                self.pendingRepairDisclosure = false
                self.screenShareRepairMessage = nil
            }
        }
        coordinator.onPinOutcome = { [weak self] outcome in
            guard let self else { return }
            // Terminal outcomes re-fire on every reconcile pass, so note
            // transitions, not repetitions — a constant line appended per pass
            // rotates real history out of a bounded log. `.pinned` is exempt:
            // it is the one outcome that mutated the display arrangement, and
            // each occurrence is a distinct event worth its own line.
            let isRepeat = outcome == self.lastPinOutcome && outcome != .pinned
            if !isRepeat, outcome != .noPreference, outcome != .alreadyOnTarget {
                FileDiagnostics.shared.note("pin", String(describing: outcome))
            }
            self.lastPinOutcome = outcome
        }

        // Property observers don't fire from within init, so start explicitly.
        Log.verbose = settings.verboseLogging
        refreshPreferredSelection()
        resumeStalePauseIfNeeded()        // ADR-014 — a restart is an implicit resume
        repairScreenShareHideIfNeeded()   // DK-FR-013 — before any start/stop gating
        applyEnabledState()
        applyHotkeyState()

        Self.shared = self
    }

    /// Set the lock edge from the menu and immediately enforce it.
    func lock(to edge: DockOrientation) {
        lockEdge = edge
    }

    // MARK: - Termination (DK-FR-013)

    /// Last-chance cleanup, driven by `AppDelegate.applicationWillTerminate`.
    ///
    /// Exactly one line here is *correctness*: putting Dock auto-hide back if
    /// the screen-share hider turned it on (DK-FR-011). It therefore runs
    /// *first*, before any hygiene teardown that could block or throw.
    ///
    /// This is a **latency optimization, not the mechanism**. It fires for
    /// `NSApp.terminate(nil)` and, via `TerminationSignals`, for SIGTERM and
    /// SIGINT; at logout/restart the Quit Apple Event is sent to a background
    /// (`LSUIElement`) process but *not waited for* before loginwindow kills it
    /// (ADR-013), and SIGKILL, Force Quit, and a crash are untrappable by
    /// construction. Restoring on those paths is the job of the persisted
    /// `ScreenShareHideRecord` and `repairScreenShareHideIfNeeded()` at the next
    /// launch (DK-FR-013). Restoring here simply means the user never sees the
    /// leftover auto-hide at all.
    ///
    /// What is deliberately **not** done here:
    /// - The locked edge and the display pin are left exactly as they are.
    ///   They are the user's persisted preference (`Settings.lockEdge`,
    ///   `preferredDisplayFingerprint`), not something DockKeeper borrowed:
    ///   no "previous edge" is stored anywhere to restore *to*, and undoing a
    ///   main-display re-base at logout would shuffle the user's screens on the
    ///   way out.
    /// - `isEnabled` is never written. Quitting is not disabling; persisting a
    ///   disable here would bring DockKeeper back inert at the next login.
    ///   Note that the ordinary disable path reaches the hider through
    ///   `applyEnabledState()` — do not reuse it here for that reason.
    /// - `coordinator.disable()` is not called. It **used** to persist nothing;
    ///   since ADR-014 it writes through `notifyState()` → `syncPauseRecord()`,
    ///   so that half of the old rationale is retired — but the conclusion
    ///   stands and the remaining half is now the whole reason: it would publish
    ///   a state change into a scene graph being torn down. The pause record is
    ///   cleared directly below instead, which is the same effect without the
    ///   state-machine transition.
    /// - `WindowLayoutPreserver` holds no state between pins (its snapshot is
    ///   created and consumed inside a single `applyPin`), so there is nothing
    ///   of its to unwind.
    func prepareForTermination() {
        // `restore: true` is the default: it invalidates the poll timer first
        // and only then restores, so no tick can re-hide behind the restore.
        // Idempotent, and a no-op when we never hid anything.
        screenShareHider.stop()
        bottomDockGuardTap.stop()
        pointerBridgeTap.stop()
        // Retract, so a record that *survives* means the process died by a route
        // that skipped this line — a crash, Force Quit, `kill -9`, or the logout
        // kill. That asymmetry is the only crash signal this app has, and it is
        // the reason the reader can say "it was killed rather than quit" instead
        // of merely "stale" (DK-FR-015).
        retractLiveGuardState()

        // Drop the pause record on the way out (ADR-014). This is a **latency
        // optimization, not the mechanism** — exactly as the auto-hide restore
        // above is — because an ordinary ⌘Q is trappable and a SIGKILL is not;
        // `resumeStalePauseIfNeeded()` at the next launch remains the guarantee.
        //
        // Without it a quit-while-paused left a record behind, so `dockkeeper
        // status` reported a pause for the whole interval between quitting and
        // relaunching. That is not the crash case the record was designed
        // around: a restart is an implicit resume, so a quit should read as one
        // immediately rather than only after the next launch clears it.
        settings.pauseRecord = nil

        // Hygiene, strictly after the restore. Both are idempotent and both
        // close the window in which a callback could fire into a half-torn-down
        // engine between this hook and process exit — the Carbon hot-key
        // trampoline in particular holds an *unretained* reference. Neither is
        // load-bearing: process exit would reclaim them anyway.
        hotKeyCenter.stop()
        monitor.stop()
    }

    // MARK: - Automation funnel (DK-FR-010)

    /// Single entry point for automation (`dockkeeper://` URLs and App Intents),
    /// routing a pure `ControlCommand` through the same published control
    /// surface the menu drives. No new engine mechanism — just the existing
    /// enable/lock/pause/resume paths.
    func perform(_ command: ControlCommand) {
        switch command {
        case .lock(let edge):
            // Parity with the CLI `lock`: enable, then pin to the edge.
            if !isEnabled { isEnabled = true }
            lock(to: edge)
        case .unlock:
            isEnabled = false
        case .pause(let duration):
            pause(for: duration)
        case .resume:
            resume()
        }
    }

    /// Live status for `DockKeeperStatusIntent` — the *same* builder the CLI
    /// uses, not a re-spelling of it.
    ///
    /// This used to hand-roll the construction, and that is exactly how the
    /// Siri/Shortcuts path missed the pause field: `StatusSummary.init` gained
    /// `pauseRecord` with a default, so the stale copy kept compiling and kept
    /// answering "enabled" while paused. `AppState.shared` is non-nil whenever
    /// the app is running — which is precisely when a pause can be live — so
    /// the intent always preferred this copy over `StatusSummary.live()` and the
    /// bug was reachable on every real pause.
    ///
    /// `isEnabled` and `lockEdge` are written through to `settings` on every
    /// mutation, so reading settings here yields the same values the published
    /// properties hold, with no third source of truth to drift.
    func statusSummary() -> StatusSummary {
        StatusSummary.live(settings: settings)
    }

    // MARK: - Pause (DK-FR-009)

    /// Pause corrections. `duration == nil` pauses until an explicit resume.
    /// This is the "temporary move" path: pause, drag the Dock via normal
    /// macOS, then resume — a full reconcile re-enforces the edge/pin. A no-op
    /// while disabled (the menu hides pause items; the hotkey guards here).
    func pause(for duration: TimeInterval?) {
        guard isEnabled else { return }
        FileDiagnostics.shared.note("pause", Self.pauseLabel(for: duration))
        coordinator.pause(for: duration)
    }

    /// Resume corrections now and re-enforce (a full reconcile runs).
    func resume() {
        FileDiagnostics.shared.note("resume", "manual")
        coordinator.resume()
    }

    /// Toggle pause/resume — the shared code path for the menu and the hotkey.
    /// Pausing via toggle pauses until resumed (predictable; no hidden timer).
    func togglePause() {
        if coordinator.isPaused {
            resume()
        } else {
            pause(for: nil)
        }
    }

    /// Discard a pause record left behind by a previous process — ADR-014's
    /// "a restart is an implicit resume".
    ///
    /// ADR-013 persists borrowed state and *reconciles* it at launch, because
    /// the Dock's auto-hide belongs to the user and DockKeeper owes it back.
    /// Pause is not borrowed; it is DockKeeper's own runtime state, and nothing
    /// is owed. So the record is discarded rather than honoured, which also
    /// makes the failure direction safe: no crash can leave DockKeeper silently
    /// not enforcing forever, which is the exact outcome an untimed
    /// `dockkeeper://pause` (no timer at all) would otherwise be one SIGKILL
    /// away from.
    ///
    /// The explicit clear is load-bearing, not belt-and-braces. A fresh
    /// `RecoveryCoordinator` starts unpaused with an empty `persistedPause`
    /// shadow, so its `syncPauseRecord()` sees "not paused, nothing persisted",
    /// finds no change, and writes nothing — leaving a stale record on disk
    /// forever. Nothing else clears it.
    ///
    /// A `--diagnostics` process never reaches this: `Diagnostics.runIfRequested()`
    /// prints and `exit()`s inside `App.init()`, before the `@StateObject`
    /// autoclosure that builds `AppState`. The support command therefore reports
    /// the record it found rather than destroying the evidence.
    ///
    /// One interleaving is accepted rather than designed against, matching how
    /// ADR-013 treats its equivalent: in the explicitly unsupported
    /// multi-instance modes (`swift run` unbundled, or
    /// `DOCKKEEPER_ALLOW_MULTIPLE_INSTANCES=1`) a second instance launching
    /// clears the *incumbent's live* record here. The incumbent's coordinator
    /// holds a write-through shadow (`persistedPause`) with no invalidation
    /// path, so it sees no change and never rewrites: the incumbent stays
    /// genuinely paused while `status` reports otherwise. The same is true of
    /// any external writer clearing the key, which is out of contract for a key
    /// deliberately absent from `externallyObservedKeys`. Both are confined to
    /// modes DK-FR-012 already documents as unsupported, and the failure is a
    /// stale *report*, never a wrong enforcement decision.
    private func resumeStalePauseIfNeeded() {
        guard settings.pauseRecord != nil else { return }
        settings.pauseRecord = nil
        FileDiagnostics.shared.note("pause", "stale-record-discarded")
    }

    /// Menu note while paused: "Paused" (until resumed) or "Paused until 3:45 PM".
    var pausedStatusText: String {
        guard isPaused else { return "" }
        guard let pausedUntil else { return "Paused" }
        return "Paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))"
    }

    private static func pauseLabel(for duration: TimeInterval?) -> String {
        guard let duration else { return "until-resumed" }
        let minutes = Int(duration / 60)
        return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    private func applyHotkeyState() {
        if pauseHotkeyEnabled {
            hotKeyCenter.start()
        } else {
            hotKeyCenter.stop()
        }
    }

    /// Choose (or clear, with `nil`) the preferred display from the menu.
    /// Persists the full fingerprint (ADR-004), never a bare pseudo-UUID.
    func setPreferredDisplay(_ display: DisplayInfo?) {
        if let display {
            settings.setPreferredDisplay(fingerprint: DisplayManager.fingerprint(for: display.displayID))
        } else {
            settings.setPreferredDisplay(fingerprint: nil)
        }
        refreshPreferredSelection()
        if isEnabled { coordinator.requestReconcile() }
    }

    func refreshDisplays() {
        displays = DisplayManager.activeDisplays()
        refreshPreferredSelection()
    }

    /// Re-resolve the stored fingerprint against the connected displays so the
    /// menu checkmark tracks identity, not a raw string comparison.
    private func refreshPreferredSelection() {
        let stored = settings.preferredDisplayFingerprint
        hasPreferredDisplay = stored != nil
        let candidates = displays.compactMap { display in
            display.fingerprint.map {
                FingerprintMatcher.Candidate(displayID: display.displayID, fingerprint: $0)
            }
        }
        if case .resolved(let displayID, _) = DisplayIdentityResolver.resolve(stored: stored, candidates: candidates) {
            preferredDisplaySelectionID = displays.first { $0.displayID == displayID }?.id
            resolvedPreferredDisplayID = displayID
        } else {
            preferredDisplaySelectionID = nil
            resolvedPreferredDisplayID = nil
        }
        // The guard's zones are a function of the arrangement and of which
        // display is preferred, so both re-resolutions must re-apply it.
        applyBottomDockGuard()
    }

    /// The live status caption under the bottom-Dock toggle. The wording,
    /// and every count in it, is `BottomDockGuard.caption(for:)` — a pure
    /// function in Core so it is reachable from a test (#84). This property
    /// is the SwiftUI binding and nothing else.
    var bottomDockGuardCaption: String {
        BottomDockGuard.caption(for: bottomDockGuardDecision)
    }

    /// The preferred display's live `CGDirectDisplayID`, or `nil` when no
    /// preference is stored, it is not connected, or two candidates tie.
    /// Distinct from `preferredDisplaySelectionID`, which is a UI-facing string.
    private(set) var resolvedPreferredDisplayID: CGDirectDisplayID?

    /// Recompute the bottom-Dock guard and arm or release the tap.
    ///
    /// Cheap and idempotent, so every path that could change an input calls it
    /// rather than trying to work out whether it needs to — the same anti-drift
    /// reasoning as `screenShareHiderShouldRun`.
    private func applyBottomDockGuard() {
        let trusted = AXIsProcessTrusted()
        let decision = BottomDockGuard.decide(
            BottomDockGuard.Snapshot(
                displays: displays,
                preferredDisplayID: resolvedPreferredDisplayID,
                dockEdge: lockEdge,
                separateSpacesEnabled: MainDisplayPinner.readSeparateSpacesEnabled(),
                appEnabled: isEnabled,
                featureEnabled: lockBottomDockToDisplay,
                // Read once and reused below. Two calls a few lines apart can
                // legitimately disagree — a grant can be revoked between them —
                // and the record is supposed to say what *this* decision was
                // made on, not what a second, later question answered.
                accessibilityTrusted: trusted
            )
        )
        bottomDockGuardDecision = decision
        bottomDockGuardTap.apply(decision)
        // Every input the guard depends on — arrangement, preferred display,
        // edge, enable, grant — is an input of the pointer bridge too, so it
        // rides this function's call sites instead of growing its own.
        applyPointerBridge(accessibilityTrusted: trusted)
        // Strictly after `apply`, so the record describes the tap as it is and
        // not as it was about to be. Publishing from the tail of this one
        // function rather than from its call sites is the same anti-drift rule
        // the function's own docstring argues above: a sixth input path added in
        // two years inherits the publish without anyone remembering to add it.
        publishLiveGuardState(accessibilityTrusted: trusted)
    }

    /// Recompute the pointer bridge and arm or release its tap. Cheap and
    /// idempotent. Reached from `applyBottomDockGuard()` and its own toggle.
    private func applyPointerBridge(accessibilityTrusted: Bool = AXIsProcessTrusted()) {
        let decision = PointerBridge.decide(
            PointerBridge.Snapshot(
                displays: displays,
                preferredDisplayID: resolvedPreferredDisplayID,
                dockEdge: lockEdge,
                appEnabled: isEnabled,
                featureEnabled: bridgePointerAcrossDockEdge,
                accessibilityTrusted: accessibilityTrusted
            )
        )
        if decision != pointerBridgeDecision {
            Log.app.notice("Pointer bridge: \(PointerBridge.caption(for: decision), privacy: .public)")
        }
        pointerBridgeDecision = decision
        pointerBridgeTap.apply(decision)
    }

    /// Publish what this instance is actually holding, for DK-FR-015.
    ///
    /// **Never on the tap's callback.** Every caller reaches here through
    /// `applyBottomDockGuard()`, which runs on the main actor from a settings
    /// change, a display change, an Accessibility re-check, or the poll tick —
    /// never from `BottomDockGuardTap.handle`, where an encoder and a defaults
    /// write would lengthen the mouse-move path that macOS disables a tap for
    /// being slow. The cost of that choice is stated rather than hidden: the
    /// clamp counter is refreshed at the poll cadence, so it can be up to
    /// `recoveryInterval` seconds behind. The record carries `observedAt` and
    /// every reader prints its age, so a stale count is *visibly* stale — which
    /// is the property that matters, since the alternative was a fresher number
    /// that could stop the guard working.
    ///
    /// Two writes are skipped rather than made. Nothing is written when the
    /// substantive state and both counters are unchanged (DK-NFR-001: an
    /// unchanged rewrite spends the quietness budget to say nothing new), and
    /// nothing is written at all when this process cannot read its own kernel
    /// identity — a record whose writer cannot be proved alive is exactly the
    /// unverifiable artifact this requirement exists to replace, so publishing
    /// none is the honest failure.
    private func publishLiveGuardState(accessibilityTrusted: Bool) {
        guard let writer = liveGuardWriterIdentity else { return }
        let now = Date()
        let tap = bottomDockGuardTap.vitals
        let candidate = LiveGuardRecord(
            writer: writer,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            // Reported only for a genuinely bundled process. An unbundled
            // `swift run DockKeeper` has no bundle, and `Bundle.main.bundlePath`
            // then names the *directory the executable sits in* — a plausible
            // path that is not an install location, which is worse than saying
            // nothing. The reader renders `nil` as "running unbundled".
            bundlePath: Bundle.main.bundleIdentifier == nil ? nil : Bundle.main.bundlePath,
            observedAt: now,
            stateChangedAt: now,
            held: LiveGuardRecord.HeldSettings(
                isEnabled: isEnabled,
                lockEdge: lockEdge,
                lockBottomDockToDisplay: lockBottomDockToDisplay
            ),
            // The app's own answer, because TCC resolves `AXIsProcessTrusted()`
            // for the *responsible* process — which is why a `--diagnostics` run
            // from a granted terminal reported a permission the GUI app did not
            // have (#77). Only this process can answer this about this process.
            accessibilityTrusted: accessibilityTrusted,
            decision: LiveGuardRecord.DecisionRecord(bottomDockGuardDecision),
            tap: tap
        )

        // The policy — ownership, the change guard, the armed heartbeat and the
        // change-stamp carry-forward — lives in Core so it is reachable from a
        // test. What is left here is gathering live values and one call.
        switch LiveGuardPublisher.next(candidate: candidate, stored: settings.liveGuardRecord) {
        case .write(let record):
            settings.publishLiveGuardRecord(record)
        case .skip:
            break
        }
    }

    /// Withdraw this instance's record on a clean exit.
    ///
    /// **Ownership-checked, and that is not a nicety.** DK-FR-012 documents two
    /// supported modes in which a second instance runs — an unbundled
    /// `swift run`, and `DOCKKEEPER_ALLOW_MULTIPLE_INSTANCES=1` — and both share
    /// this one key. An unconditional retraction would let one instance's quit
    /// delete a *live* instance's record, and the reader would then report "no
    /// instance has published" about an app that is running and guarding. That is
    /// the class of wrong answer this whole requirement exists to remove, so the
    /// retraction refuses to touch a record it did not write.
    private func retractLiveGuardState() {
        guard let writer = liveGuardWriterIdentity else { return }
        guard LiveGuardPublisher.shouldRetract(stored: settings.liveGuardRecord, writer: writer) else { return }
        settings.publishLiveGuardRecord(nil)
    }

    /// Open System Settings so the user can approve the login item.
    func openLoginItemsSettings() {
        LoginItemManager.openLoginItemsSettings()
    }

    /// Re-check the Accessibility grant and publish it if changed. Called from
    /// the Advanced tab on appear and on app reactivation.
    func refreshAccessibilityStatus() {
        let granted = AXIsProcessTrusted()
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        // Publishing the flag re-renders the view but does not re-run the
        // decision, so without this the guard never arms after the user grants —
        // and the caption keeps asking for a permission they already gave. The
        // latch is symmetric: a revoked grant must release the tap too.
        // `refreshDisplays()` rather than `applyBottomDockGuard()` because the
        // arrangement may have changed while the user was in System Settings,
        // and stale frames are what make a clamp dangerous.
        refreshDisplays()
    }

    /// Deep-link to the Accessibility pane so the user can grant the permission.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Explain-then-prompt: the caption is the contextual explanation, shown
    /// before the user enables the toggle; this fires the system prompt once.
    private func requestAccessibilityPermission() {
        // Literal value of `kAXTrustedCheckOptionPrompt` — referencing the SDK
        // global directly is a Swift 6 concurrency-unsafe shared-mutable read.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Reveal the diagnostics file in Finder (support-bundle flow).
    func revealDiagnosticsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([FileDiagnostics.shared.fileURL])
    }

    private func applyLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(launchAtLogin)
            settings.launchAtLogin = launchAtLogin
            loginItemMessage = LoginItemManager.statusMessage
            Log.app.info("Launch at Login set to \(self.launchAtLogin, privacy: .public)")
        } catch {
            Log.app.error("Launch at Login change failed: \(error.localizedDescription, privacy: .public)")
            loginItemMessage = "Couldn't update Launch at Login: \(error.localizedDescription)"
            // Revert the toggle to the real system state without re-triggering.
            isSyncingLoginItem = true
            launchAtLogin = LoginItemManager.isEnabled
            isSyncingLoginItem = false
        }
    }

    private func applyEnabledState() {
        if isEnabled {
            monitor.start()
            coordinator.enable()  // performs the initial full reconcile
        } else {
            coordinator.disable()
            monitor.stop()
        }
        // The screen-share hider follows the master enable switch too — disabling
        // DockKeeper stops it (and restores the Dock if it was hidden).
        applyScreenShareHiderState()
        // Same for the bottom-Dock guard: disabling DockKeeper must not leave an
        // event tap clamping the pointer.
        //
        // On the enable path the geometry must be re-read first. `displays` is
        // only written by `refreshDisplays()`, whose sole caller is the monitor's
        // reconfiguration arm — and `monitor.stop()` removes those observers
        // while `start()` emits no initial event. So across disable → rearrange →
        // enable the frames are stale, and a clamp computed from an arrangement
        // that no longer exists is exactly the trapped-pointer case. Ends in
        // `applyBottomDockGuard()` itself, so the call below is a harmless
        // idempotent repeat on this path.
        if isEnabled {
            refreshDisplays()
        }
        applyBottomDockGuard()
    }

    /// The one spelling of "the screen-share poll should be running", shared by
    /// the launch repair and the start/stop path so the two can never disagree —
    /// the same anti-drift reason `InstanceGuard.oneShotFlags` is shared rather
    /// than re-spelled. `repairIfNeeded` may only *adopt* a leftover hide if the
    /// poll that would later restore it is definitely going to run.
    private var screenShareHiderShouldRun: Bool {
        isEnabled && hideDockDuringScreenShare && screenCaptureAvailable
    }

    /// Start or stop the screen-share Dock hider. Runs the poll only while the
    /// feature is on, DockKeeper is enabled, and the private screen-watcher
    /// symbol resolved (ADR-011). Stopping restores the Dock if we had hidden
    /// it, so turning the feature off never leaves the Dock auto-hidden.
    private func applyScreenShareHiderState() {
        if screenShareHiderShouldRun {
            screenShareHider.start()
        } else {
            screenShareHider.stop()
        }
    }

    /// Repair a Dock left auto-hidden by a DockKeeper that was killed rather
    /// than quit — SIGKILL, Force Quit, a crash, `run-app.sh`'s escalation, or
    /// the logout kill (DK-FR-013). `prepareForTermination()` is the trappable
    /// half; this is the half that cannot be trapped and therefore has to be
    /// persisted. Because loginwindow does not wait for a background process's
    /// Quit reply (ADR-013), this — not the terminate hook — is the mechanism.
    ///
    /// Runs **before** `applyEnabledState()` and is gated on nothing: a Dock
    /// stuck auto-hidden must be repaired even if the user has since turned the
    /// feature — or DockKeeper — off, which is exactly what a frustrated user
    /// does. `ScreenShareHider.repair` handles the unavailable-symbol case, so
    /// no `CoreDock.isAvailable` gate is needed here.
    private func repairScreenShareHideIfNeeded() {
        let action = screenShareHider.repairIfNeeded(featureActive: screenShareHiderShouldRun)
        switch action {
        case .none:
            return
        case .discard, .adopt:
            // State only — no PII (DK-PRIV-001 S2), matching the pin/state notes.
            // `.restore` is deliberately absent here: it fires
            // `onTransition(.repaired)`, which already writes the note — two
            // lines for one event otherwise.
            FileDiagnostics.shared.note("screenshare", "repair-" + String(describing: action))
        case .restore:
            break
        }
        // Disclosure is decided separately from the note, because `.adopt`'s
        // user-visible consequence is deferred: it takes ownership now and the
        // Dock write lands when the share ends. Announcing only `.restore` would
        // leave ADR-013's A7 ("do not restore silently") — and R-014's
        // "announced in the menu" mitigation — true on only one of the two
        // branches that actually mutate a global system preference.
        switch action {
        case .restore:
            screenShareRepairMessage = Self.repairRestoredMessage
        case .adopt:
            pendingRepairDisclosure = true
            screenShareRepairMessage = "DockKeeper is holding your Dock hidden for the screen share "
                + "in progress, and will put it back when the share ends."
        case .none, .discard:
            break
        }
    }

    /// The one spelling of the post-repair note, shared by the `.restore` branch
    /// and by the deferred `.adopt` discharge so the two cannot drift apart.
    private static let repairRestoredMessage =
        "Restored your Dock after a screen share ended unexpectedly." 

    /// User-initiated recovery (DK-FR-013 S11). Unconditional by design — see
    /// `ScreenShareHider.restoreAutoHideByUserRequest()`.
    func restoreDockAutoHide() {
        screenShareRepairMessage = screenShareHider.restoreAutoHideByUserRequest()
            ? nil
            : "Couldn't change Dock auto-hide on this version of macOS."
    }

    /// Whether to offer the manual recovery in the menu: only when the Dock is
    /// *currently* auto-hiding and this feature is the plausible cause. Reading
    /// the live value keeps the offer honest rather than cached-and-stale.
    ///
    /// Gated on the auto-hide symbols, not on `screenCaptureAvailable`: the
    /// action this offers is a CoreDock auto-hide write, and a macOS that drops
    /// the SkyLight watcher is exactly when a user poisoned by an earlier one
    /// still needs the recovery.
    ///
    /// Cost, labelled honestly (kickoff rule 19, kickoff rule 5): this is **not**
    /// only read when the menu opens. A `MenuBarExtra(.menu)` content body is
    /// re-evaluated on any `AppState` publish, menu open or closed [INFERRED —
    /// SwiftUI invalidation is not a documented contract], so the frequency is
    /// set by publishes (recovery-state changes, display events), not by a timer.
    /// It stays a live read because the alternative — caching with no reliable
    /// menu-open edge — offers a control that disagrees with the real Dock, and
    /// the read is one `dlsym`'d C call with no side effect.
    var canOfferAutoHideRestore: Bool {
        guard coreDockAutoHideAvailable, hideDockDuringScreenShare else { return false }
        return screenShareHider.currentAutoHide() == true
    }

    /// Refresh published values after an external (CLI) settings edit
    /// (DK-FR-007-S3). Assignments are skipped when unchanged so the guarded
    /// didSets stay quiet.
    private func syncFromSettings() {
        isSyncingFromExternal = true
        defer { isSyncingFromExternal = false }
        if lockEdge != settings.lockEdge {
            lockEdge = settings.lockEdge
        }
        if lockBottomDockToDisplay != settings.lockBottomDockToDisplay {
            lockBottomDockToDisplay = settings.lockBottomDockToDisplay
        }
        if bridgePointerAcrossDockEdge != settings.bridgePointerAcrossDockEdge {
            bridgePointerAcrossDockEdge = settings.bridgePointerAcrossDockEdge
        }
        refreshPreferredSelection()
        if isEnabled != settings.isEnabled {
            isEnabled = settings.isEnabled
            // The didSet was suppressed; enact the enable/disable transition.
            applyEnabledState()
        }
    }
}
