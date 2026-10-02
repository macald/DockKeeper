import Foundation
import CoreGraphics

/// A point-in-time view of the display environment, used to decide whether and
/// how to pin the Dock to a preferred display. Captured as a value so the
/// decision logic is pure and unit-testable without real hardware.
public struct DisplaySnapshot: Sendable, Equatable {
    public let displays: [DisplayInfo]
    public let mainDisplayID: CGDirectDisplayID
    public let separateSpacesEnabled: Bool
    public let observedDockEdge: DockOrientation?
    public let dockHostDisplayID: CGDirectDisplayID?

    public init(displays: [DisplayInfo], mainDisplayID: CGDirectDisplayID, separateSpacesEnabled: Bool,
                observedDockEdge: DockOrientation? = nil, dockHostDisplayID: CGDirectDisplayID? = nil) {
        self.displays = displays
        self.mainDisplayID = mainDisplayID
        self.separateSpacesEnabled = separateSpacesEnabled
        self.observedDockEdge = observedDockEdge
        self.dockHostDisplayID = dockHostDisplayID
    }

    /// The displays offered to fingerprint matching (ADR-004).
    public var identityCandidates: [FingerprintMatcher.Candidate] {
        displays.compactMap { display in
            display.fingerprint.map {
                FingerprintMatcher.Candidate(displayID: display.displayID, fingerprint: $0)
            }
        }
    }
}

/// The result of a pin attempt. All non-`pinned` cases are safe no-ops.
public enum PinOutcome: Sendable, Equatable {
    case pinned                     // Reconfigured; target is now the main display.
    case alreadyOnTarget            // Target was already the main display.
    case dockOnOtherDisplay         // Main display is correct; observed Dock host is not.
    case dockPlacementUnverified    // No unambiguous observation for the requested side edge.
    case singleDisplay              // Only one display; nothing to pin.
    case displayNotConnected        // Preferred display isn't currently attached.
    case ambiguousIdentity          // Two candidates are indistinguishable — never guess (TDD §7.2).
    case unsupportedSeparateSpaces  // "Displays have separate Spaces" is on (Decision 2A).
    case bottomDockFollowsPointer   // Bottom Dock roams by pointer; no preference set (ADR-009).
    case noPreference               // No preferred display configured.
    case failed(Int32)              // CoreGraphics reconfigure error (CGError raw value).

    /// Short, user-facing explanation for the menu / preferences.
    ///
    /// Newlines are **load-bearing**: a macOS menu item renders one line and
    /// middle-truncates the rest, so a long sentence silently loses its middle.
    /// The separate-Spaces copy lost exactly the cheaper of its two remedies
    /// that way — users saw "…is on....turn the setting off", never learning
    /// that a left/right edge works today (#57). `MenuBarContent` renders one
    /// `Text` per line; consumers that want a flat string use `userMessage`,
    /// which joins them with spaces.
    public var userMessageLines: [String] {
        (userMessage ?? "").split(separator: "\n").map(String.init)
    }

    public var userMessage: String? {
        switch self {
        case .pinned, .alreadyOnTarget, .noPreference:
            return nil  // Nothing to explain; it worked or isn't set.
        case .dockOnOtherDisplay:
            return "Dock is on another display.\n"
                + "Your preferred display is already main, but the Dock did not follow it.\n"
                + "Try a different edge or display arrangement."
        case .dockPlacementUnverified:
            return "Your preferred display is main; Dock placement is not verified."
        case .singleDisplay:
            return "Only one display is connected."
        case .displayNotConnected:
            return "Your preferred display isn't connected."
        case .ambiguousIdentity:
            return "Two connected displays look identical, so DockKeeper won't "
                + "guess. Please pick your preferred display again."
        case .bottomDockFollowsPointer:
            return "macOS gives a bottom Dock to whichever display you summon it on.\n"
                + "To keep it on one display: use a Left or Right edge, and pick a "
                + "preferred display.\n"
                + "Or turn off \u{201C}Displays have separate Spaces\u{201D} in System "
                + "Settings \u{203A} Desktop & Dock."
        case .unsupportedSeparateSpaces:
            return "A bottom Dock can\u{2019}t be pinned while \u{201C}Displays have "
                + "separate Spaces\u{201D} is on.\n"
                + "To pin in this mode: use a Left or Right edge.\n"
                + "Or turn that setting off in System Settings \u{203A} Desktop & Dock. "
                + "Edge locking still works."
        case .failed:
            return "Couldn't move the Dock to your preferred display."
        }
    }

    /// The menu's message, given the bottom-Dock guard's current decision.
    ///
    /// `userMessage` alone cannot be right for `.unsupportedSeparateSpaces`
    /// since the guard shipped (#79): it told a user a bottom Dock can't be kept
    /// in this mode and never named the guard as a remedy. The wording keeps
    /// ADR-015's binding distinction: the guard *prevents* a summon, it does not
    /// pin the Dock and cannot move it back.
    ///
    /// **Decision-only, so it claims no active protection.** `.guarding` is the
    /// geometry plan, not evidence the event tap is filtering: the tap can fail
    /// to start or be disabled by the system after the decision is published,
    /// and even a healthy guard never observes where the Dock currently is
    /// (enabled after it already moved, or summoned through an open shared
    /// strip). So the text says the feature is on, what it does when active,
    /// and where its details are — never that the Dock *is* being kept. Not
    /// "live status" either: that caption is decision-derived too (#105).
    ///
    /// One element per `\n` line, like `userMessage`, so no line is
    /// middle-truncated in a menu item (#57). Every other outcome passes through.
    public func userMessage(guardDecision: BottomDockGuard.Decision) -> String? {
        guard self == .unsupportedSeparateSpaces else { return userMessage }
        let toggleName = "\u{201C}Keep a bottom Dock on my preferred display\u{201D}"
        switch guardDecision {
        case .guarding(_, let skipped, let partial):
            var message = "macOS can\u{2019}t pin a bottom Dock while \u{201C}Displays have "
                + "separate Spaces\u{201D} is on.\n"
                + "\(toggleName) is on \u{2014} details in Preferences \u{203A} Advanced.\n"
                + "When active, it blocks new summons on guarded edges; it can\u{2019}t move the Dock back."
            if !skipped.isEmpty || !partial.isEmpty {
                message += "\nSome bottom edges are left open, so the Dock can still be summoned there."
            }
            message += "\nOther options: a Left or Right edge, or turn that setting off."
            return message
        case .idle(.appDisabled):
            // The master switch is off, and it is disqualified before the
            // feature toggle, so this says nothing about that toggle — which
            // may well be on. `lastPinOutcome` outlives the disable, so a
            // separate-Spaces advisory here would be a stale one about a
            // DockKeeper that is not running its checks. Suppressed.
            return nil
        case .idle(.featureDisabled):
            return (userMessage ?? "") + "\n"
                + "Or turn on \(toggleName) in Preferences \u{203A} Advanced.\n"
                + "When active, it blocks new summons on guarded edges; it can\u{2019}t move the Dock back."
        case .idle:
            // The user has turned the guard on, so offering it would be the
            // same contradiction in a milder form. Its caption names the
            // unmet condition; a menu line cannot hold every one of them.
            return (userMessage ?? "") + "\n"
                + "\(toggleName) is on but inactive \u{2014} see Preferences \u{203A} Advanced."
        }
    }

    /// `userMessage(guardDecision:)` split for a menu, one element per line.
    public func userMessageLines(guardDecision: BottomDockGuard.Decision) -> [String] {
        (userMessage(guardDecision: guardDecision) ?? "").split(separator: "\n").map(String.init)
    }
}

/// Abstraction over "keep the Dock on the user's preferred monitor". v1.0 has a
/// single public-API implementation; the protocol leaves room for an
/// experimental private-API strategy later without touching call sites.
/// Main-actor because live snapshots read `NSScreen`.
@MainActor
public protocol DisplayPinner {
    /// Attempt to pin to a concrete, already-resolved display. `dockEdge` is
    /// the user's locked edge — it gates separate-Spaces support (ADR-009).
    func pin(toDisplayID targetID: CGDirectDisplayID, dockEdge: DockOrientation) -> PinOutcome
}

/// Pins the Dock by making the preferred display the **main** display (moving
/// its origin to `(0,0)` and shifting the others to preserve the arrangement).
///
/// Per Decision 1 this also relocates the menu bar — an accepted, documented
/// consequence. Per Decision 2A, when "Displays have separate Spaces" is on we
/// decline rather than fight the OS. Identity resolution (fingerprint →
/// display) happens *before* the pinner via `DisplayIdentityResolver`.
@MainActor
public struct MainDisplayPinner: DisplayPinner {

    /// What `decide` concludes: either a terminal outcome, or "go make this
    /// display the main one".
    enum Decision: Equatable {
        case terminal(PinOutcome)
        case reconfigure(CGDirectDisplayID)
    }

    private let snapshotProvider: @MainActor () -> DisplaySnapshot
    private let applyMain: @MainActor (_ targetID: CGDirectDisplayID, _ displays: [DisplayInfo]) -> Int32

    /// Default initializer wires up real CoreGraphics. Tests inject fakes.
    public init(
        snapshotProvider: @escaping @MainActor () -> DisplaySnapshot = MainDisplayPinner.liveSnapshot,
        applyMain: @escaping @MainActor (_ targetID: CGDirectDisplayID, _ displays: [DisplayInfo]) -> Int32 = MainDisplayPinner.liveApplyMain
    ) {
        self.snapshotProvider = snapshotProvider
        self.applyMain = applyMain
    }

    public func pin(toDisplayID targetID: CGDirectDisplayID, dockEdge: DockOrientation) -> PinOutcome {
        let snapshot = snapshotProvider()
        guard snapshot.displays.contains(where: { $0.displayID == targetID }) else {
            // The display vanished between resolution and application.
            return .displayNotConnected
        }
        switch Self.decide(snapshot: snapshot, resolution: .resolved(targetID, repaired: nil), dockEdge: dockEdge) {
        case .terminal(let outcome):
            Log.display.debug("Pin decision: \(String(describing: outcome), privacy: .public)")
            return outcome
        case .reconfigure(let targetID):
            let code = applyMain(targetID, snapshot.displays)
            if code == 0 {
                Log.display.info("Made display \(targetID) main; Dock placement still needs verification")
                return .pinned
            }
            Log.display.error("Display reconfigure failed with CGError \(code)")
            return .failed(code)
        }
    }

    // MARK: - Pure decision logic (unit-tested)

    /// Placement decision for an already-resolved preference. Outcome
    /// precedence: no preference → single display → identity outcomes →
    /// separate-Spaces gate → already-on-target. The no-preference arm carries
    /// one advisory exception, described where it is returned.
    ///
    /// Separate-Spaces gate (ADR-009, hardware-confirmed 2026-07-23): with the
    /// setting ON, a **bottom** Dock is per-display/pointer-summoned and does
    /// not follow the main display — declined honestly. A **left/right** Dock
    /// followed main on the original stacked test rig. This is not universal:
    /// on macOS 27.0.1 with a laptop left of the preferred external, the left
    /// Dock stays on the laptop. A side-edge success now requires a matching
    /// host observation; main-display identity alone is not placement proof.
    nonisolated static func decide(
        snapshot: DisplaySnapshot,
        resolution: PreferredDisplayResolution,
        dockEdge: DockOrientation
    ) -> Decision {
        if case .none = resolution {
            // A bottom Dock in separate-Spaces mode is pointer-summoned, so it
            // roams between displays whether or not a preference is stored. The
            // user who has not stored one is exactly the user who has never been
            // told that — they never reach the `.resolved` gate below, so
            // before #44 they got silence and read it as "the app does nothing".
            // Guarded on multi-display because with one screen nothing roams.
            if snapshot.displays.count > 1, snapshot.separateSpacesEnabled, dockEdge == .bottom {
                return .terminal(.bottomDockFollowsPointer)
            }
            return .terminal(.noPreference)
        }
        guard snapshot.displays.count > 1 else { return .terminal(.singleDisplay) }
        switch resolution {
        case .none:
            return .terminal(.noPreference)  // unreachable; kept exhaustive
        case .notConnected:
            return .terminal(.displayNotConnected)
        case .ambiguous:
            return .terminal(.ambiguousIdentity)
        case .resolved(let targetID, _):
            if snapshot.separateSpacesEnabled && dockEdge == .bottom {
                return .terminal(.unsupportedSeparateSpaces)
            }
            if targetID == snapshot.mainDisplayID {
                if dockEdge == .left || dockEdge == .right {
                    guard snapshot.observedDockEdge == dockEdge,
                          let host = snapshot.dockHostDisplayID,
                          snapshot.displays.contains(where: { $0.displayID == host }) else {
                        return .terminal(.dockPlacementUnverified)
                    }
                    if host != targetID { return .terminal(.dockOnOtherDisplay) }
                }
                return .terminal(.alreadyOnTarget)
            }
            return .reconfigure(targetID)
        }
    }

    // MARK: - Live implementations

    public static let liveSnapshot: @MainActor () -> DisplaySnapshot = {
        let displays = DisplayManager.activeDisplays()
        let edge = CoreDock.current()?.orientation
        return DisplaySnapshot(
            displays: displays,
            mainDisplayID: CGMainDisplayID(),
            separateSpacesEnabled: readSeparateSpacesEnabled(),
            observedDockEdge: edge,
            dockHostDisplayID: (edge == .left || edge == .right)
                ? DockHostDetector.live(displays: displays) : nil
        )
    }

    /// Reconfigure display origins so `targetID` sits at `(0,0)` — making it the
    /// main display — while preserving every display's relative position.
    /// Returns `0` on success or the failing `CGError` raw value.
    public static let liveApplyMain: @Sendable (CGDirectDisplayID, [DisplayInfo]) -> Int32 = { targetID, displays in
        guard let target = displays.first(where: { $0.displayID == targetID }) else {
            return CGError.illegalArgument.rawValue
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return begin.rawValue }

        let dx = target.frame.origin.x
        let dy = target.frame.origin.y
        for display in displays {
            let newX = Int32(display.frame.origin.x - dx)
            let newY = Int32(display.frame.origin.y - dy)
            let err = CGConfigureDisplayOrigin(config, display.displayID, newX, newY)
            if err != .success {
                CGCancelDisplayConfiguration(config)
                return err.rawValue
            }
        }
        return CGCompleteDisplayConfiguration(config, .permanently).rawValue
    }

    /// Reads the "Displays have separate Spaces" setting.
    /// `com.apple.spaces spans-displays` == 1 means displays span one Space
    /// (separate Spaces OFF); absent or 0 means separate Spaces ON (the macOS
    /// default).
    public nonisolated static func readSeparateSpacesEnabled() -> Bool {
        guard
            let spaces = UserDefaults(suiteName: "com.apple.spaces"),
            spaces.object(forKey: "spans-displays") != nil
        else { return true }
        return spaces.integer(forKey: "spans-displays") != 1
    }
}
