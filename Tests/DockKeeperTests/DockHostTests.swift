import CoreGraphics
import Testing
@testable import DockKeeperCore

private let lg = DisplayInfo(id: "lg", displayID: 2, name: "LG ULTRAWIDE", isMain: true,
                             frame: CGRect(x: 0, y: 0, width: 2560, height: 1080), fingerprint: DisplayFingerprint(uuid: "lg"))
private let laptop = DisplayInfo(id: "laptop", displayID: 1, name: "Built-in", isMain: false,
                                 frame: CGRect(x: -1512, y: 149, width: 1512, height: 982), fingerprint: DisplayFingerprint(uuid: "laptop"))

@Suite("Dock host verification")
struct DockHostTests {
    @Test("Regression: main LG does not mean a left Dock is on the LG", arguments: [true, false])
    func wrongDisplay(spaces: Bool) {
        let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
            separateSpacesEnabled: spaces, observedDockEdge: .left, dockHostDisplayID: 1)
        let decision = MainDisplayPinner.decide(snapshot: snapshot,
            resolution: .resolved(2, repaired: nil), dockEdge: .left)
        #expect(decision == .terminal(.dockOnOtherDisplay))
        let input = ReconcileInput(currentEdge: .left, desiredEdge: .left,
            primaryMechanismAvailable: true, includesPinning: true,
            pinDecision: .terminal(.dockOnOtherDisplay))
        #expect(RecoveryMachine.decide(input: input).isEmpty, "Do not fight the OS with repeated reconfiguration")
    }

    @Test("Known host on target confirms the placement", arguments: [DockOrientation.left, .right])
    func matched(edge: DockOrientation) {
        let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
            separateSpacesEnabled: true, observedDockEdge: edge, dockHostDisplayID: 2)
        #expect(MainDisplayPinner.decide(snapshot: snapshot,
            resolution: .resolved(2, repaired: nil), dockEdge: edge) == .terminal(.alreadyOnTarget))
    }

    @Test("Missing observation and an edge in transition cannot confirm placement")
    func uncertain() {
        for edge: DockOrientation? in [nil, .bottom, .left] {
            let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
                separateSpacesEnabled: true, observedDockEdge: edge, dockHostDisplayID: nil)
            #expect(MainDisplayPinner.decide(snapshot: snapshot,
                resolution: .resolved(2, repaired: nil), dockEdge: .left) == .terminal(.dockPlacementUnverified))
        }
        let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
            separateSpacesEnabled: true, observedDockEdge: .right, dockHostDisplayID: 2)
        #expect(MainDisplayPinner.decide(snapshot: snapshot,
            resolution: .resolved(2, repaired: nil), dockEdge: .left) == .terminal(.dockPlacementUnverified))
    }

    @Test("A host ID absent from the snapshot cannot confirm placement")
    func disconnectedHost() {
        let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
            separateSpacesEnabled: true, observedDockEdge: .left, dockHostDisplayID: 999)
        #expect(MainDisplayPinner.decide(snapshot: snapshot,
            resolution: .resolved(2, repaired: nil), dockEdge: .left) == .terminal(.dockPlacementUnverified))
    }

    @Test("Canvas detection tracks the host across left/right changes, without a cached frame")
    func canvas() {
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [laptop.frame], displays: [lg, laptop]) == 1)
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [lg.frame], displays: [lg, laptop]) == 2)
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [laptop.frame], displays: [lg, laptop]) == 1)
    }

    @Test("No canvas, conflicting canvases, mirrors, and arbitrary windows are unknown")
    func ambiguous() {
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [], displays: [lg, laptop]) == nil)
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [lg.frame, laptop.frame], displays: [lg, laptop]) == nil)
        let mirror = DisplayInfo(id: "mirror", displayID: 3, name: "Mirror", isMain: false, frame: lg.frame)
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [lg.frame], displays: [lg, mirror]) == nil)
        #expect(DockHostDetector.hostDisplayID(canvasFrames: [CGRect(x: 0, y: 0, width: 300, height: 200)], displays: [lg, laptop]) == nil)
    }

    @Test("Diagnostic reports the observed laptop even though LG is main")
    func diagnosticMismatch() {
        let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
            separateSpacesEnabled: true, observedDockEdge: .left, dockHostDisplayID: 1)
        let lines = DockPlacementReport.lines(snapshot: snapshot,
            preferred: DisplayFingerprint(uuid: "lg"), desiredEdge: .left)
        #expect(lines.contains("Preferred:       LG ULTRAWIDE"))
        #expect(lines.contains("Observed host:   Built-in"))
        #expect(lines.last!.contains("Dock is on another display"))
        #expect(!lines.joined().contains("observed on preferred display"))
    }

    @Test("Diagnostic distinguishes matched and unobserved placement")
    func diagnosticEvidence() {
        for host: UInt32? in [nil, 2] {
            let snapshot = DisplaySnapshot(displays: [lg, laptop], mainDisplayID: 2,
                separateSpacesEnabled: true, observedDockEdge: .right, dockHostDisplayID: host)
            let lines = DockPlacementReport.lines(snapshot: snapshot,
                preferred: DisplayFingerprint(uuid: "lg"), desiredEdge: .right)
            #expect(lines.last!.contains(host == nil ? "not verified" : "observed on preferred display"))
        }
    }

    @Test("Warnings fit menu lines and do not mistake main-display selection for success")
    func messages() {
        for outcome: PinOutcome in [.dockOnOtherDisplay, .dockPlacementUnverified] {
            #expect(outcome.userMessage != nil)
            #expect(outcome.userMessageLines.allSatisfy { $0.count <= 110 })
        }
        #expect(PinOutcome.dockOnOtherDisplay.userMessage!.contains("another display"))
        #expect(PinOutcome.dockPlacementUnverified.userMessage!.contains("not verified"))
    }
}
