import CoreGraphics
import Foundation
import Testing

@testable import DockKeeperCore

// Frames are CG global, top-left origin, as in `DisplayInfo.frame` and the
// space an event tap reports. The owner's measured rig (fork, 2026-10-02):
// LG ULTRAWIDE main at (0, 0, 2560, 1080); built-in 1512×982, which the bridge
// expects below-left of it, e.g. at (-1400, 1080).

private let lg = CGRect(x: 0, y: 0, width: 2560, height: 1080)
private let builtinDiagonal = CGRect(x: -1400, y: 1080, width: 1512, height: 982)
private let builtinSideBySide = CGRect(x: -1512, y: 149, width: 1512, height: 982)

private func display(_ id: CGDirectDisplayID, _ frame: CGRect, main: Bool = false) -> DisplayInfo {
    DisplayInfo(id: "cg-\(id)", displayID: id, name: "D\(id)", isMain: main, frame: frame)
}

private func snapshot(
    displays: [DisplayInfo] = [display(1, lg, main: true), display(2, builtinDiagonal)],
    preferred: CGDirectDisplayID? = 1,
    edge: DockOrientation = .left,
    appEnabled: Bool = true,
    enabled: Bool = true,
    trusted: Bool = true
) -> PointerBridge.Snapshot {
    PointerBridge.Snapshot(
        displays: displays, preferredDisplayID: preferred, dockEdge: edge,
        appEnabled: appEnabled, featureEnabled: enabled, accessibilityTrusted: trusted
    )
}

private func plan(_ snapshot: PointerBridge.Snapshot = snapshot()) -> PointerBridge.Plan {
    guard case .bridging(let plan) = PointerBridge.decide(snapshot) else {
        Issue.record("expected a bridging decision")
        return PointerBridge.Plan(side: .left, preferred: .zero, partner: .zero)
    }
    return plan
}

// MARK: - decide

@Test func bridgesTheMeasuredDiagonalRig() {
    #expect(PointerBridge.decide(snapshot()) == .bridging(
        PointerBridge.Plan(side: .left, preferred: lg, partner: builtinDiagonal)
    ))
}

@Test func idleReasonsFollowPrecedence() {
    #expect(PointerBridge.decide(snapshot(appEnabled: false, enabled: false)) == .idle(.appDisabled))
    #expect(PointerBridge.decide(snapshot(enabled: false, trusted: false)) == .idle(.featureDisabled))
    #expect(PointerBridge.decide(snapshot(edge: .bottom, trusted: false)) == .idle(.notTrusted))
    #expect(PointerBridge.decide(snapshot(edge: .bottom)) == .idle(.notSideEdge))
    #expect(PointerBridge.decide(snapshot(preferred: nil)) == .idle(.noPreferredDisplay))
    #expect(PointerBridge.decide(snapshot(preferred: 9)) == .idle(.noPreferredDisplay))
    #expect(PointerBridge.decide(snapshot(displays: [display(1, lg, main: true)])) == .idle(.notTwoDisplays))
}

/// The owner's everyday arrangement: the built-in shares the LG's left edge,
/// so macOS keeps a Left Dock on the built-in and there is nothing to bridge.
@Test func sideBySideIsNotBridged() {
    let s = snapshot(displays: [display(1, lg, main: true), display(2, builtinSideBySide)])
    #expect(PointerBridge.decide(s) == .idle(.partnerNotBeyondDockEdge))
}

/// Stacked and centred below: both left edges free, but the partner does not
/// extend past the Dock edge, so there is no outward push to bridge from.
@Test func centredBelowIsNotBridged() {
    let below = CGRect(x: 524, y: 1080, width: 1512, height: 982)
    let s = snapshot(displays: [display(1, lg, main: true), display(2, below)])
    #expect(PointerBridge.decide(s) == .idle(.partnerNotBeyondDockEdge))
}

@Test func partnerAboveIsBridged() {
    let above = CGRect(x: -1400, y: -982, width: 1512, height: 982)
    let s = snapshot(displays: [display(1, lg, main: true), display(2, above)])
    #expect(PointerBridge.decide(s) == .bridging(PointerBridge.Plan(side: .left, preferred: lg, partner: above)))
}

@Test func rightDockMirrorsTheGeometry() {
    let belowRight = CGRect(x: 2448, y: 1080, width: 1512, height: 982)
    let s = snapshot(displays: [display(1, lg, main: true), display(2, belowRight)], edge: .right)
    #expect(PointerBridge.decide(s) == .bridging(PointerBridge.Plan(side: .right, preferred: lg, partner: belowRight)))
    // A right Dock never bridges to a partner sticking out on the left.
    let left = snapshot(edge: .right)
    #expect(PointerBridge.decide(left) == .idle(.partnerNotBeyondDockEdge))
}

/// Mirrored displays report identical frames: never "beyond" anything.
@Test func mirroredDisplaysAreNotBridged() {
    let s = snapshot(displays: [display(1, lg, main: true), display(2, lg)])
    #expect(PointerBridge.decide(s) == .idle(.partnerNotBeyondDockEdge))
}

// MARK: - pushed edge and landing

@Test func pushAgainstTheDockEdgeLandsInsideThePartnersFarEdge() {
    let p = plan()
    let push = CGPoint(x: 0, y: 540)
    #expect(PointerBridge.pushedEdge(at: push, deltaX: -5, plan: p) == .preferredDockEdge)
    #expect(PointerBridge.pushedEdge(at: push, deltaX: 5, plan: p) == nil)
    #expect(PointerBridge.pushedEdge(at: CGPoint(x: 1, y: 540), deltaX: -5, plan: p) == nil)

    let landing = PointerBridge.landing(from: push, edge: .preferredDockEdge, plan: p)
    // Proportional height: halfway down the LG is halfway down the built-in.
    #expect(landing == CGPoint(x: builtinDiagonal.maxX - 1 - PointerBridge.landingInset, y: 1080 + 491))
    // The landing point must not itself be a pushed edge, or the next event
    // would bounce straight back (fork runs 2 and 3).
    #expect(PointerBridge.pushedEdge(at: landing, deltaX: 75, plan: p) == nil)
}

@Test func pushAgainstThePartnersFarEdgeLandsInsideTheDockEdge() {
    let p = plan()
    let push = CGPoint(x: 111.6, y: 1080 + 491)
    #expect(PointerBridge.pushedEdge(at: push, deltaX: 4, plan: p) == .partnerFarEdge)
    let landing = PointerBridge.landing(from: push, edge: .partnerFarEdge, plan: p)
    #expect(landing == CGPoint(x: PointerBridge.landingInset, y: 540))
    #expect(PointerBridge.pushedEdge(at: landing, deltaX: -80, plan: p) == nil)
}

@Test func landingHeightStaysOnTheDestination() {
    let p = plan()
    let bottom = PointerBridge.landing(from: CGPoint(x: 0, y: 1079.9), edge: .preferredDockEdge, plan: p)
    #expect(bottom.y < builtinDiagonal.maxY)
    let top = PointerBridge.landing(from: CGPoint(x: 100, y: 1080), edge: .partnerFarEdge, plan: p)
    #expect(top.y == 0)
}

@Test func rightDockEdgesAreMirrored() {
    let belowRight = CGRect(x: 2448, y: 1080, width: 1512, height: 982)
    let p = plan(snapshot(displays: [display(1, lg, main: true), display(2, belowRight)], edge: .right))
    let push = CGPoint(x: 2559.6, y: 0)
    #expect(PointerBridge.pushedEdge(at: push, deltaX: 3, plan: p) == .preferredDockEdge)
    #expect(PointerBridge.landing(from: push, edge: .preferredDockEdge, plan: p)
        == CGPoint(x: belowRight.minX + PointerBridge.landingInset, y: 1080))
    let back = CGPoint(x: 2448, y: 1080)
    #expect(PointerBridge.pushedEdge(at: back, deltaX: -3, plan: p) == .partnerFarEdge)
    #expect(PointerBridge.landing(from: back, edge: .partnerFarEdge, plan: p).x == lg.maxX - 1 - PointerBridge.landingInset)
}

// MARK: - push tracker

/// `#expect` cannot call a mutating member, so the tracker is fed through this.
private func push(_ tracker: inout PointerBridge.PushTracker, edge: PointerBridge.Edge?, deltaX: Double, now: TimeInterval) -> Bool {
    tracker.register(edge: edge, deltaX: deltaX, now: now)
}

@Test func crossingNeedsASustainedPush() {
    var tracker = PointerBridge.PushTracker()
    #expect(!push(&tracker, edge: .preferredDockEdge, deltaX: -10, now: 1))
    #expect(!push(&tracker, edge: .preferredDockEdge, deltaX: -10, now: 1.01))
    #expect(push(&tracker, edge: .preferredDockEdge, deltaX: -5, now: 1.02))
}

@Test func leavingTheEdgeResetsThePush() {
    var tracker = PointerBridge.PushTracker()
    #expect(!push(&tracker, edge: .preferredDockEdge, deltaX: -20, now: 1))
    #expect(!push(&tracker, edge: nil, deltaX: 3, now: 1.01))
    #expect(!push(&tracker, edge: .preferredDockEdge, deltaX: -20, now: 1.02))
}

/// Fork run 4: the first event after a crossing carries the jump itself as a
/// delta (dx = +75). The cooldown keeps that from counting as a push back.
@Test func cooldownIgnoresPushesRightAfterACrossing() {
    var tracker = PointerBridge.PushTracker()
    #expect(push(&tracker, edge: .preferredDockEdge, deltaX: -30, now: 1))
    #expect(!push(&tracker, edge: .partnerFarEdge, deltaX: 75, now: 1.01))
    #expect(!push(&tracker, edge: .partnerFarEdge, deltaX: 30, now: 1.1))
    #expect(push(&tracker, edge: .partnerFarEdge, deltaX: 30, now: 1.3))
}

// MARK: - copy

@Test func everyIdleReasonHasACaption() {
    let reasons: [PointerBridge.IdleReason] = [
        .appDisabled, .featureDisabled, .notTrusted, .notSideEdge,
        .noPreferredDisplay, .notTwoDisplays, .partnerNotBeyondDockEdge,
    ]
    let captions = reasons.map { PointerBridge.caption(for: .idle($0)) }
    #expect(Set(captions).count == reasons.count)
    #expect(captions.allSatisfy { !$0.isEmpty })
    #expect(PointerBridge.caption(for: .bridging(plan())).hasPrefix("Active"))
}
