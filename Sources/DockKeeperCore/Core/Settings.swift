import Foundation

/// Persistent user settings, backed by `UserDefaults`.
///
/// `DockKeeperCore` deliberately keeps this as a plain `ObservableObject`-free
/// store so it is usable from the CLI. The menu-bar app layers SwiftUI
/// observation on top via its own wrapper.
public final class Settings: @unchecked Sendable {

    /// The domain both the app and the CLI read and write.
    ///
    /// **Not** `UserDefaults.standard`: that resolves by bundle identifier for
    /// the app but by *process name* for an unbundled executable, so the CLI
    /// silently wrote to its own `dockkeeper`/`dockkeeper-cli` domain and
    /// `dockkeeper unlock` never reached the running app (v0.9.0 bug). Naming
    /// the suite explicitly makes the two share one store, as documented.
    public static let suiteName = "com.dockkeeper.app"

    /// How one process reaches ``suiteName``.
    ///
    /// The app's own bundle identifier *is* `com.dockkeeper.app`, and passing
    /// your own identifier to `UserDefaults(suiteName:)` is the documented
    /// no-op: it returns `nil` and AppKit logs *"does not make sense and will
    /// not work"*. The fallback below caught that and the app did reach the
    /// right store — but by accident, and with that warning as the first line
    /// of every `--diagnostics` report a user pastes into a bug report (#34).
    /// Deciding per process makes the intent explicit and the log clean. Both
    /// cases name the same domain; only the handle used to open it differs.
    enum DefaultsResolution: Equatable {
        /// The process *is* the suite, so `.standard` already is that domain.
        case standard
        /// Every other process — the CLI, a test host — must name it outright.
        case suite(String)
    }

    static func resolution(forBundleIdentifier bundleID: String?) -> DefaultsResolution {
        bundleID == suiteName ? .standard : .suite(suiteName)
    }

    /// The store both executables must use.
    ///
    /// The `?? .standard` fallback is load-bearing, not defensive padding, and
    /// it is **not** a second correct answer. Post-fix only a non-app process
    /// can reach it, and for one of those `.standard` resolves by *process
    /// name*, i.e. a private per-executable domain — exactly the v0.9.0 split
    /// that naming the suite exists to prevent. It stays because a degraded
    /// store beats trapping at launch, but anything landing there has a broken
    /// container and is off the shared domain.
    public static func sharedDefaults() -> UserDefaults {
        switch resolution(forBundleIdentifier: Bundle.main.bundleIdentifier) {
        case .standard:
            return .standard
        case .suite(let name):
            return UserDefaults(suiteName: name) ?? .standard
        }
    }

    public static let shared = Settings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = Settings.sharedDefaults()) {
        self.defaults = defaults
        self.defaults.register(defaults: Self.registrationDomain())
        migratePreferredDisplayIfNeeded()
    }

    private static func registrationDomain() -> [String: Any] { [
        Keys.enabled: true,
        Keys.lockEdge: DockOrientation.bottom.rawValue,
        Keys.launchAtLogin: false,
        Keys.verboseLogging: false,
        Keys.diagnosticsFileEnabled: false,
        Keys.preserveWindowLayout: false,
        Keys.pauseHotkeyEnabled: false,
        Keys.hideDockDuringScreenShare: false,
        Keys.lockBottomDockToDisplay: false,
        Keys.bridgePointerAcrossDockEdge: false,
        Keys.restoreDelay: 0.4,
        Keys.recoveryInterval: 30.0,
        Keys.settingsVersion: 1,
    ] }

    // Retired keys, ignored if present on disk: `autoRecover` (ADR-007 —
    // `enabled` is the single switch) and `showMenuBarIcon` (dead in v0.1; a
    // menu-bar-only app without its icon would be unreachable).
    enum Keys {
        static let enabled = "enabled"
        static let lockEdge = "lockEdge"
        static let preferredDisplayUUID = "preferredDisplayUUID"          // legacy (pre-ADR-004); kept in sync for rollback until v1.1
        static let preferredDisplayFingerprint = "preferredDisplayFingerprint"
        static let launchAtLogin = "launchAtLogin"
        static let verboseLogging = "verboseLogging"
        static let diagnosticsFileEnabled = "diagnosticsFileEnabled"
        static let preserveWindowLayout = "preserveWindowLayout"
        static let pauseHotkeyEnabled = "pauseHotkeyEnabled"
        static let hideDockDuringScreenShare = "hideDockDuringScreenShare"
        static let lockBottomDockToDisplay = "lockBottomDockToDisplay"
        static let bridgePointerAcrossDockEdge = "bridgePointerAcrossDockEdge"
        static let screenShareHideRecord = "screenShareHideRecord"
        static let pauseRecord = "pauseRecord"
        static let liveGuardRecord = "liveGuardRecord"
        static let restoreDelay = "restoreDelay"
        static let recoveryInterval = "recoveryInterval"
        static let settingsVersion = "settingsVersion"
    }

    /// The keys whose external (e.g. CLI) edits should refresh a running app —
    /// observed via KVO by `DockMonitor` (DK-FR-007-S3).
    ///
    /// `screenShareHideRecord` is deliberately **absent**. This app writes it on
    /// every capture hide and every restore; observing it would turn each one
    /// into a `.settingsChanged` event and a full reconcile, falsifying ADR-011's
    /// verified "Coordinator interaction" claim that the auto-hide path never
    /// reaches `DockMonitor`/`RecoveryCoordinator`. There is a test for this.
    ///
    /// `pauseRecord` is **absent for a related but distinct reason** (ADR-014).
    /// It is written far less often than the hide record, so churn is not the
    /// argument; the argument is `resume()`. Resume clears the record *and*
    /// already runs a full reconcile of its own by design — observing the key
    /// would fire a second, redundant reconcile off the same resume. (The pause
    /// side is harmless either way: `RecoveryMachine.shouldProcess` refuses
    /// every event while `.paused`, so the write during a pause could not be
    /// acted on.) Letting an external writer *drive* pause by writing this key
    /// is a separate feature, and would need that double reconcile solved first.
    static let externallyObservedKeys = [Keys.enabled, Keys.lockEdge, Keys.preferredDisplayFingerprint]

    /// Backing store handle for KVO observation by `DockMonitor`.
    var observableDefaults: UserDefaults { defaults }

    // MARK: General

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    // MARK: Dock

    public var lockEdge: DockOrientation {
        get { DockOrientation(rawValue: defaults.integer(forKey: Keys.lockEdge)) ?? .bottom }
        set { defaults.set(newValue.rawValue, forKey: Keys.lockEdge) }
    }

    /// The fingerprint of the display the Dock should stay on (ADR-004).
    /// `nil` means "any / don't pin to a specific display". Set via
    /// `setPreferredDisplay(fingerprint:)`.
    public var preferredDisplayFingerprint: DisplayFingerprint? {
        guard let data = defaults.data(forKey: Keys.preferredDisplayFingerprint) else { return nil }
        return try? JSONDecoder().decode(DisplayFingerprint.self, from: data)
    }

    /// Store (or clear, with `nil`) the preferred display. The legacy UUID key
    /// is mirrored so a rolled-back pre-fingerprint build still works
    /// (implementation-plan M2 rollback note; drop with v1.1).
    public func setPreferredDisplay(fingerprint: DisplayFingerprint?) {
        guard let fingerprint else {
            defaults.removeObject(forKey: Keys.preferredDisplayFingerprint)
            defaults.removeObject(forKey: Keys.preferredDisplayUUID)
            return
        }
        defaults.set(try? JSONEncoder().encode(fingerprint), forKey: Keys.preferredDisplayFingerprint)
        defaults.set(fingerprint.uuid, forKey: Keys.preferredDisplayUUID)
    }

    /// Stale-preference repair (TDD §7.3): a fallback-evidence match rewrites
    /// the stored fingerprint with fresh identifiers so it heals instead of
    /// rotting.
    public func repairPreferredDisplay(_ fresh: DisplayFingerprint) {
        Log.display.info("Repairing stale preferred-display fingerprint")
        setPreferredDisplay(fingerprint: fresh)
    }

    /// v0.1 stored a bare UUID string. Build a fingerprint from it once;
    /// unstable `"cg-<id>"` placeholders are discarded outright (they must
    /// never be persisted — TDD §7.1). The legacy key itself is kept in sync
    /// for rollback.
    private func migratePreferredDisplayIfNeeded() {
        guard
            defaults.data(forKey: Keys.preferredDisplayFingerprint) == nil,
            let legacy = defaults.string(forKey: Keys.preferredDisplayUUID)
        else { return }
        if legacy.hasPrefix("cg-") {
            Log.display.info("Discarding unstable legacy display preference")
            defaults.removeObject(forKey: Keys.preferredDisplayUUID)
            return
        }
        setPreferredDisplay(fingerprint: DisplayFingerprint(uuid: legacy))
    }

    // MARK: Advanced

    public var verboseLogging: Bool {
        get { defaults.bool(forKey: Keys.verboseLogging) }
        set {
            defaults.set(newValue, forKey: Keys.verboseLogging)
            Log.verbose = newValue
        }
    }

    /// Seconds to wait after a display/wake event before restoring the Dock,
    /// letting the system settle first.
    public var restoreDelay: TimeInterval {
        get { defaults.double(forKey: Keys.restoreDelay) }
        set { defaults.set(newValue, forKey: Keys.restoreDelay) }
    }

    /// Polling interval (seconds) for the periodic recovery check.
    public var recoveryInterval: TimeInterval {
        get { defaults.double(forKey: Keys.recoveryInterval) }
        set { defaults.set(newValue, forKey: Keys.recoveryInterval) }
    }

    /// Opt-in bounded diagnostics file (TDD §12; DK-PRIV-001 S2).
    public var diagnosticsFileEnabled: Bool {
        get { defaults.bool(forKey: Keys.diagnosticsFileEnabled) }
        set { defaults.set(newValue, forKey: Keys.diagnosticsFileEnabled) }
    }

    /// Opt-in window restore across a pin (ADR-010). Off by default; when on
    /// *and* Accessibility is granted, DockKeeper moves windows back to their
    /// original display after a main-display re-base. No-op without the grant.
    public var preserveWindowLayout: Bool {
        get { defaults.bool(forKey: Keys.preserveWindowLayout) }
        set { defaults.set(newValue, forKey: Keys.preserveWindowLayout) }
    }

    /// Opt-in global hotkey (⌃⌥⌘D) to toggle pause (DK-FR-009). Off by default
    /// — no surprise system-wide hotkey (kickoff rule 20: predictability
    /// first). When on, the app registers a Carbon hot key (no permission).
    public var pauseHotkeyEnabled: Bool {
        get { defaults.bool(forKey: Keys.pauseHotkeyEnabled) }
        set { defaults.set(newValue, forKey: Keys.pauseHotkeyEnabled) }
    }

    /// Opt-in "hide the Dock while screen sharing" (DK-FR-011, ADR-011). Off by
    /// default. When on *and* the private screen-watcher symbol resolves,
    /// DockKeeper turns Dock auto-hide on for the duration of a screen capture
    /// and restores it afterward — only if the user wasn't already running
    /// auto-hide. Uses the private `CGSIsScreenWatcherPresent` detector; inert
    /// (and the toggle is disabled with a note) when the symbol is absent.
    public var hideDockDuringScreenShare: Bool {
        get { defaults.bool(forKey: Keys.hideDockDuringScreenShare) }
        set { defaults.set(newValue, forKey: Keys.hideDockDuringScreenShare) }
    }

    /// Hold a bottom Dock on the preferred display in separate-Spaces mode by
    /// blocking the pointer summon (DK-FR-014, ADR-015). Opt-in and **false by
    /// default**: it is the only feature that needs Accessibility for a
    /// *continuous* event tap — window restore needs the permission too, but
    /// only for one-shot window moves — and it leaves unguarded any display
    /// whose bottom edge is also a crossing boundary.
    public var lockBottomDockToDisplay: Bool {
        get { defaults.bool(forKey: Keys.lockBottomDockToDisplay) }
        set { defaults.set(newValue, forKey: Keys.lockBottomDockToDisplay) }
    }

    /// Carry the pointer across a side Dock's edge to the other display, for a
    /// diagonal arrangement that keeps the Dock on the preferred display (fork
    /// DK-FR-F01, ADR-F002). Opt-in, **false by default**, needs Accessibility
    /// for a continuous event tap, like `lockBottomDockToDisplay`.
    public var bridgePointerAcrossDockEdge: Bool {
        get { defaults.bool(forKey: Keys.bridgePointerAcrossDockEdge) }
        set { defaults.set(newValue, forKey: Keys.bridgePointerAcrossDockEdge) }
    }

    /// Breadcrumb saying "DockKeeper is holding Dock auto-hide ON for a screen
    /// capture right now" (DK-FR-013, ADR-013). Absent means we hold nothing.
    ///
    /// One key holding one JSON blob, exactly like `preferredDisplayFingerprint`
    /// above: a single `set` is atomic, so the record can never be read
    /// half-written, and an undecodable value degrades to `nil` — "no record",
    /// which is the safe answer in every branch of `ScreenShareHider.repair`.
    /// A struct rather than a bare `Date` so a later field can be added without
    /// a key migration.
    ///
    /// Deliberately **not** in `registrationDomain()`: absence is a real state,
    /// and a registered default cannot be removed. Deliberately **not** in
    /// `externallyObservedKeys` — see the note there. No `settingsVersion` bump:
    /// that hook is for migrations that *reinterpret existing keys*; an optional,
    /// absent-by-default key is compatible in both directions (an older build
    /// ignores it; a newer build reading an older domain sees no record).
    public var screenShareHideRecord: ScreenShareHideRecord? {
        get {
            guard let data = defaults.data(forKey: Keys.screenShareHideRecord) else { return nil }
            return try? JSONDecoder().decode(ScreenShareHideRecord.self, from: data)
        }
        set {
            // The encode is folded into the same guard on purpose. `set(nil,
            // forKey:)` is `removeObject`, so passing `try?` straight through
            // would turn an encode failure into a *silent* "no record" while the
            // caller went on to write the Dock — reconstructing the exact
            // unrecoverable state the write-ahead ordering exists to prevent.
            // Unreachable for a `Date`-only struct today, but ADR-013 mints this
            // as the pattern for all future borrowed state.
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Keys.screenShareHideRecord)
                return
            }
            defaults.set(data, forKey: Keys.screenShareHideRecord)
        }
    }

    /// A durable note that corrections are paused (DK-FR-009), so a cold process
    /// — `dockkeeper status`, `--diagnostics` — can report a pause it is not
    /// hosting. See `PauseRecord` and ADR-014.
    ///
    /// Same contract as `screenShareHideRecord` above, for the same reasons:
    /// deliberately **not** in `registrationDomain()` (absence is a real state,
    /// and a registered default cannot be removed), deliberately **not** in
    /// `externallyObservedKeys` (see the note there), and **no `settingsVersion`
    /// bump** (an optional, absent-by-default key reads compatibly in both
    /// directions).
    ///
    /// The encode is folded into the guard for **readability, not protection**,
    /// and the distinction was worth correcting (#47): the else-branch is
    /// `removeObject`, so a failed encode clears the key and the record reads as
    /// "not paused" — which is exactly the outcome the fold used to be described
    /// as preventing. `defaults.set(nil, forKey:)` *is* `removeObject`, so the
    /// folded guard and the bare `try?` it was contrasted with produce identical
    /// state on success and on failure alike.
    ///
    /// Clearing is the fail-safe direction **for this record and only this one**:
    /// ADR-014 makes a restart an implicit resume and
    /// `AppState.resumeStalePauseIfNeeded()` discards the key at launch anyway,
    /// so a lost pause record costs a pause that ends early. It is *not*
    /// fail-safe for `screenShareHideRecord`, whose whole purpose is to hand
    /// back borrowed state — losing it there strands the user's Dock. That
    /// asymmetry, and the fact that the sibling's caller writes the Dock
    /// regardless, is filed as its own issue rather than patched here.
    ///
    /// Unreachable today either way: both `Date`s come from the clock, and
    /// `JSONEncoder` only throws on a non-finite one.
    public var pauseRecord: PauseRecord? {
        get {
            guard let data = defaults.data(forKey: Keys.pauseRecord) else { return nil }
            return try? JSONDecoder().decode(PauseRecord.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Keys.pauseRecord)
                return
            }
            defaults.set(data, forKey: Keys.pauseRecord)
        }
    }

    // MARK: Live guard record (DK-FR-015)

    /// What a *running* instance last published about the bottom-Dock guard.
    ///
    /// Read-only here, and paired with `publishLiveGuardRecord(_:)` rather than
    /// exposed as a `var`, because the two directions are not symmetric. A
    /// writer supplies a record or clears it; a reader gets a three-case answer
    /// in which "there is nothing" and "there is something I could not read" are
    /// different verdicts. A `var` would have to collapse them into `nil`, which
    /// is the one thing this record may never do — see `StoredLiveGuardRecord`.
    ///
    /// Stored as a JSON **string**, deliberately unlike `pauseRecord` and
    /// `screenShareHideRecord`, which store `Data`. Those are private state that
    /// happens to persist; this one has "machine-readable" as an acceptance
    /// criterion, and a `Data` value renders in `defaults read` as a hex blob no
    /// support reader can use. As a string, `defaults read com.dockkeeper.app
    /// liveGuardRecord` *is* the machine-readable artifact, with no second
    /// surface to keep in step.
    ///
    /// Absent from `registrationDomain()` because absence is a real state — no
    /// instance has published — and from `externallyObservedKeys` because this
    /// app writes it, and observing a self-written key turns every publish into
    /// a `.settingsChanged` event and a full reconcile (the argument ADR-011 and
    /// ADR-014 already record for the two records above it).
    public var liveGuardRecord: StoredLiveGuardRecord {
        // `object(forKey:)`, not `string(forKey:)`. A non-string value in the
        // domain — someone's stray `defaults write ... -int 1` — makes
        // `string(forKey:)` answer `nil`, which would read as "no instance has
        // published" and collapse the one distinction this enum exists to keep.
        guard let stored = defaults.object(forKey: Keys.liveGuardRecord) else { return .absent }
        guard let text = stored as? String else {
            return .unreadable("stored value is a \(type(of: stored)), not a string")
        }
        guard let data = text.data(using: .utf8) else {
            return .unreadable("stored value is not UTF-8")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The envelope is decoded first, on its own, so a record from a newer
        // DockKeeper is recognised as a version difference rather than as
        // corruption. Decoding the payload to reach `schema` would report every
        // structural change — a field that became required, a case that gained
        // an associated value — as a damaged record, which is a confident wrong
        // answer about the one thing this feature promises to get right.
        guard let envelope = try? decoder.decode(SchemaEnvelope.self, from: data) else {
            return .unreadable("stored value is not a recognisable record")
        }
        guard envelope.schema == LiveGuardRecord.currentSchema else {
            return .wrongSchema(found: envelope.schema)
        }
        do {
            return .present(try decoder.decode(LiveGuardRecord.self, from: data))
        } catch {
            // The reason is carried, not swallowed. A reader that can only say
            // "unreadable" sends its user back to guessing, which is the state
            // this feature exists to end.
            return .unreadable(String(describing: error))
        }
    }

    /// Just enough of a record to learn which version wrote it.
    private struct SchemaEnvelope: Decodable {
        let schema: Int
    }

    /// Publish, or retract with `nil`.
    ///
    /// Retraction on a clean exit is what makes a *surviving* record evidence:
    /// find one whose writer is gone and you know the process died by a route
    /// that skipped its own cleanup. That asymmetry is the only crash signal
    /// this app has ever had.
    ///
    /// An encoding failure retracts rather than leaving the previous record in
    /// place. A record that no longer describes the running state is worse than
    /// none — it is the stale instrument this whole requirement is about — and
    /// the reader is built to report "nothing published" honestly.
    public func publishLiveGuardRecord(_ record: LiveGuardRecord?) {
        guard let record else {
            defaults.removeObject(forKey: Keys.liveGuardRecord)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so an unchanged record encodes to an identical string.
        // The change guard upstream compares records, not strings, but a stable
        // encoding also means `defaults read` output diffs cleanly between two
        // support reports, which is how a maintainer spots what moved.
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(record),
            let text = String(data: data, encoding: .utf8)
        else {
            defaults.removeObject(forKey: Keys.liveGuardRecord)
            return
        }
        defaults.set(text, forKey: Keys.liveGuardRecord)
    }

    /// Schema version hook for future migrations (current: 1).
    public var settingsVersion: Int {
        defaults.integer(forKey: Keys.settingsVersion)
    }
}
