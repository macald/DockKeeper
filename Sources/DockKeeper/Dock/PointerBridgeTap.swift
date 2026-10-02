import ApplicationServices
import CoreGraphics
import DockKeeperCore
import Foundation

/// The side-effecting half of fork DK-FR-F01: a `CGEventTap` that carries the
/// pointer across a side Dock's edge to the other display (ADR-F002).
///
/// All policy lives in `PointerBridge`; this type owns the tap's lifecycle and
/// the per-event crossing. Built like `BottomDockGuardTap`: main run loop,
/// silent and safe failure, nothing persisted, nothing to repair after a crash.
///
/// **How a crossing moves the pointer — measured, not assumed** (fork spike,
/// `docs/spikes/pointer-bridge.md`, 2026-10-02):
/// - Editing `event.location` holds the pointer inside one display (the bottom
///   guard relies on that) but never moved it to another: 0 of 143 (run 1).
/// - `CGWarpMouseCursorPosition` crossed, but froze the pointer 250–272 ms
///   after every crossing (run 4).
/// - Posting a replacement event from a source whose local-events suppression
///   interval is zero crossed with the pointer moving again in 1–14 ms (run 5).
///   That is what this does: the original event is dropped and replaced.
@MainActor
final class PointerBridgeTap {

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var plan: PointerBridge.Plan?
    private var tracker = PointerBridge.PushTracker()

    /// Our own source for the replacement events. Its suppression interval is
    /// set to zero while armed and put back on `stop()`.
    private let postSource = CGEventSource(stateID: .combinedSessionState)
    private var originalSuppression: CFTimeInterval?

    private(set) var crossingCount = 0
    private(set) var reenableCount = 0

    var isActive: Bool { tap != nil }

    /// Applies a decision. Idempotent: the same plan keeps the existing tap.
    func apply(_ decision: PointerBridge.Decision) {
        switch decision {
        case .idle:
            stop()
        case .bridging(let newPlan):
            if newPlan != plan { tracker = PointerBridge.PushTracker() }
            plan = newPlan
            if tap == nil { start() }
        }
    }

    // MARK: - Lifecycle

    private func start() {
        // Re-checked here: the grant can be revoked between decision and call.
        guard AXIsProcessTrusted() else {
            Log.app.notice("Pointer bridge: not starting, Accessibility not granted")
            return
        }
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // must be able to drop and replace
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<PointerBridgeTap>.fromOpaque(userInfo).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: context
        ) else {
            Log.app.error("Pointer bridge: CGEventTapCreate returned nil; bridge inactive")
            return
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        // `handle` uses `MainActor.assumeIsolated`; see BottomDockGuardTap.
        precondition(Thread.isMainThread, "PointerBridgeTap must be started on the main thread")
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)

        originalSuppression = postSource?.localEventsSuppressionInterval
        postSource?.localEventsSuppressionInterval = 0
        tap = created
        source = runLoopSource
        tracker = PointerBridge.PushTracker()
        crossingCount = 0
        reenableCount = 0
        Log.app.notice("Pointer bridge: armed")
    }

    func stop() {
        plan = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        if let originalSuppression { postSource?.localEventsSuppressionInterval = originalSuppression }
        originalSuppression = nil
        Log.app.notice("Pointer bridge: released after \(self.crossingCount) crossing(s)")
    }

    // MARK: - Per-event

    /// Main run loop only. Short on purpose: a slow callback gets the tap
    /// disabled by macOS.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { self.reenable() }
            return Unmanaged.passUnretained(event)
        }
        let location = event.location
        let deltaX = event.getDoubleValueField(.mouseEventDeltaX)
        let now = ProcessInfo.processInfo.systemUptime
        let crossed: Bool = MainActor.assumeIsolated {
            guard let plan = self.plan else { return false }
            let edge = PointerBridge.pushedEdge(at: location, deltaX: deltaX, plan: plan)
            guard self.tracker.register(edge: edge, deltaX: deltaX, now: now), let edge else { return false }
            self.crossingCount += 1
            let landing = PointerBridge.landing(from: location, edge: edge, plan: plan)
            let button: CGMouseButton = type == .rightMouseDragged ? .right
                : (type == .otherMouseDragged ? .center : .left)
            // The replacement lands inside the destination, away from any
            // bridged edge, so when it passes back through this tap it is left
            // alone. Built and posted here so no `CGEvent` crosses the actor.
            CGEvent(mouseEventSource: self.postSource, mouseType: type,
                    mouseCursorPosition: landing, mouseButton: button)?
                .post(tap: .cghidEventTap)
            return true
        }
        return crossed ? nil : Unmanaged.passUnretained(event)
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        reenableCount += 1
        Log.app.notice("Pointer bridge: tap re-enabled")
    }

    // Lifetime: owned by `AppState` for the whole process and stopped from
    // `prepareForTermination()`, the same arrangement — and the same caveat
    // about a shorter-lived owner — as `BottomDockGuardTap`.
}
