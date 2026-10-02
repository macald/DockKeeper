import CoreGraphics
import Foundation

/// Lets the pointer cross a side Dock's edge to the other display as if the two
/// were side by side, while the arrangement macOS sees keeps that edge free
/// (fork DK-FR-F01, ADR-F002).
///
/// **Why the arrangement has to change at all.** On the fork's measured rig
/// (macOS 27.0.1), a Left or Right Dock is placed only on a display whose Dock
/// edge touches no other display; with another display flush against that edge,
/// the Dock goes to the other display even when the preferred one is main. That
/// held with separate Spaces on and off, and with as little as 22 pt of shared
/// edge outside the Dock's own span. See `docs/spikes/side-dock-display.md`.
///
/// So the user arranges the other display *diagonally* — above or below the
/// preferred one, sticking out past its Dock edge — and this feature recreates
/// the lost side crossing: a sustained push against the preferred display's
/// Dock edge lands just inside the partner's far edge, and back. Heights map
/// proportionally, so every point of either edge has a partner.
///
/// This is the pure half: it decides **whether** to bridge and **where** a push
/// lands. The event tap is `PointerBridgeTap` in the app target. Coordinates are
/// Core Graphics global, top-left origin, like `DisplayInfo.frame`.
public enum PointerBridge {

    // MARK: - Tuning (each value measured on the fork's rig, 2026-10-02)

    /// Outward push, in points of accumulated `deltaX`, needed to cross. Run 4
    /// (24 pt) removed the bounce-back of runs 2–3 and felt like a natural edge.
    public static let pushThreshold: Double = 24

    /// How far inside the destination edge the pointer lands, so the landing
    /// point is never itself a pushed edge (runs 2–3 bounced without it).
    public static let landingInset: CGFloat = 6

    /// Pushes ignored after a crossing. Run 4's trace: the first event after a
    /// crossing carries the jump itself as its delta (e.g. dx = +75).
    public static let cooldown: TimeInterval = 0.2

    /// Float noise only; arrangements are integral in practice.
    private static let tolerance: CGFloat = 1

    // MARK: - Decision

    public struct Snapshot: Sendable, Equatable {
        public var displays: [DisplayInfo]
        public var preferredDisplayID: CGDirectDisplayID?
        public var dockEdge: DockOrientation
        public var appEnabled: Bool
        public var featureEnabled: Bool
        public var accessibilityTrusted: Bool

        public init(displays: [DisplayInfo], preferredDisplayID: CGDirectDisplayID?, dockEdge: DockOrientation,
                    appEnabled: Bool, featureEnabled: Bool, accessibilityTrusted: Bool) {
            self.displays = displays
            self.preferredDisplayID = preferredDisplayID
            self.dockEdge = dockEdge
            self.appEnabled = appEnabled
            self.featureEnabled = featureEnabled
            self.accessibilityTrusted = accessibilityTrusted
        }
    }

    /// Why nothing is bridged, in precedence order.
    public enum IdleReason: Sendable, Equatable {
        case appDisabled
        case featureDisabled
        case notTrusted
        case notSideEdge
        case noPreferredDisplay
        case notTwoDisplays
        /// The other display does not sit above or below the preferred one
        /// while sticking out past its Dock edge — including the side-by-side
        /// arrangement this feature exists to replace.
        case partnerNotBeyondDockEdge
    }

    public struct Plan: Sendable, Equatable {
        public let side: DockOrientation
        public let preferred: CGRect
        public let partner: CGRect

        public init(side: DockOrientation, preferred: CGRect, partner: CGRect) {
            self.side = side
            self.preferred = preferred
            self.partner = partner
        }
    }

    public enum Decision: Sendable, Equatable {
        case idle(IdleReason)
        case bridging(Plan)
    }

    public static func decide(_ s: Snapshot) -> Decision {
        guard s.appEnabled else { return .idle(.appDisabled) }
        guard s.featureEnabled else { return .idle(.featureDisabled) }
        guard s.accessibilityTrusted else { return .idle(.notTrusted) }
        guard s.dockEdge == .left || s.dockEdge == .right else { return .idle(.notSideEdge) }
        guard let id = s.preferredDisplayID,
              let preferred = s.displays.first(where: { $0.displayID == id })?.frame else {
            return .idle(.noPreferredDisplay)
        }
        // Two displays only: with more, "the other display" is ambiguous and a
        // third screen could sit flush against an edge this would hijack.
        guard s.displays.count == 2,
              let partner = s.displays.first(where: { $0.displayID != id })?.frame else {
            return .idle(.notTwoDisplays)
        }
        let verticallyDisjoint = partner.minY >= preferred.maxY - tolerance
            || partner.maxY <= preferred.minY + tolerance
        let beyond = s.dockEdge == .left
            ? partner.minX < preferred.minX - tolerance
            : partner.maxX > preferred.maxX + tolerance
        // Disjoint vertically means nothing touches either bridged edge, so
        // a push there would otherwise go nowhere — the bridge never competes
        // with a native crossing.
        guard verticallyDisjoint, beyond else { return .idle(.partnerNotBeyondDockEdge) }
        return .bridging(Plan(side: s.dockEdge, preferred: preferred, partner: partner))
    }

    // MARK: - Geometry

    public enum Edge: Sendable, Equatable {
        /// The preferred display's Dock edge (left edge for a Left Dock).
        case preferredDockEdge
        /// The partner's edge on the opposite side (right edge for a Left Dock).
        case partnerFarEdge
    }

    /// The bridged edge `point` is pushing against, if any.
    public static func pushedEdge(at point: CGPoint, deltaX: Double, plan: Plan) -> Edge? {
        let leftward = deltaX < 0, rightward = deltaX > 0
        if spans(plan.preferred, point) {
            if plan.side == .left, leftward, point.x <= plan.preferred.minX + 0.5 { return .preferredDockEdge }
            if plan.side == .right, rightward, point.x >= plan.preferred.maxX - 1.5 { return .preferredDockEdge }
        }
        if spans(plan.partner, point) {
            if plan.side == .left, rightward, point.x >= plan.partner.maxX - 1.5 { return .partnerFarEdge }
            if plan.side == .right, leftward, point.x <= plan.partner.minX + 0.5 { return .partnerFarEdge }
        }
        return nil
    }

    /// Where a crossing from `edge` at `point` lands: just inside the opposite
    /// bridged edge, at the same proportional height.
    public static func landing(from point: CGPoint, edge: Edge, plan: Plan) -> CGPoint {
        let (from, to) = edge == .preferredDockEdge ? (plan.preferred, plan.partner) : (plan.partner, plan.preferred)
        let fraction = min(max((point.y - from.minY) / from.height, 0), 1)
        let y = min(to.minY + fraction * to.height, to.maxY - 1)
        // Landing on the destination's right edge when travelling leftward, and
        // vice versa.
        let landsOnRightEdge = (plan.side == .left) == (edge == .preferredDockEdge)
        let x = landsOnRightEdge ? to.maxX - 1 - landingInset : to.minX + landingInset
        return CGPoint(x: x, y: y)
    }

    /// Vertical containment plus horizontal containment with half a point of
    /// slack, because a pointer pinned at an edge reports fractional x.
    private static func spans(_ frame: CGRect, _ p: CGPoint) -> Bool {
        p.y >= frame.minY && p.y < frame.maxY && p.x >= frame.minX - 0.5 && p.x < frame.maxX + 0.5
    }

    // MARK: - Push tracking

    /// Accumulates outward pushes at one edge and says when to cross. Value
    /// type with injected time, so the timing rules are unit-tested.
    public struct PushTracker: Sendable {
        private var edge: Edge?
        private var accumulated = 0.0
        private var lastCrossing = -Double.infinity

        public init() {}

        /// Feed every pointer event; `edge` is `pushedEdge(...)` for it.
        /// Returns `true` when this event should cross.
        public mutating func register(edge: Edge?, deltaX: Double, now: TimeInterval) -> Bool {
            guard now - lastCrossing >= PointerBridge.cooldown, let edge else {
                self.edge = nil
                accumulated = 0
                return false
            }
            if edge != self.edge {
                self.edge = edge
                accumulated = 0
            }
            accumulated += abs(deltaX)
            guard accumulated >= PointerBridge.pushThreshold else { return false }
            self.edge = nil
            accumulated = 0
            lastCrossing = now
            return true
        }
    }

    // MARK: - Copy

    public static let toggleDescription =
        "Off by default. For a Left or Right Dock that macOS keeps putting on the other display. "
        + "In System Settings › Displays › Arrange, place the other display above or below your "
        + "preferred one, sticking out past its Dock edge: macOS then keeps the Dock on your preferred "
        + "display. Pushing the pointer past that Dock edge, or past the other display's far edge, "
        + "crosses between them as if they were side by side. Needs Accessibility to move the pointer."

    public static func caption(for decision: Decision) -> String {
        switch decision {
        case .bridging:
            return "Active — push past the Dock edge to reach the other display."
        case .idle(.appDisabled):
            return "Inactive — DockKeeper is disabled."
        case .idle(.featureDisabled):
            return "Off."
        case .idle(.notTrusted):
            return "Inactive — needs Accessibility permission."
        case .idle(.notSideEdge):
            return "Inactive — only works with a Left or Right Dock."
        case .idle(.noPreferredDisplay):
            return "Inactive — choose a preferred display first."
        case .idle(.notTwoDisplays):
            return "Inactive — works with exactly two displays."
        case .idle(.partnerNotBeyondDockEdge):
            return "Inactive — place the other display above or below your preferred one, "
                + "sticking out past its Dock edge."
        }
    }
}
