import Foundation

/// Diagnostic copy from the same snapshot and decision used by reconciliation.
/// Pure, read-only, and explicit when observation is unavailable.
public enum DockPlacementReport {
    public static func lines(snapshot: DisplaySnapshot, preferred: DisplayFingerprint?,
                             desiredEdge: DockOrientation) -> [String] {
        let resolution = DisplayIdentityResolver.resolve(stored: preferred, candidates: snapshot.identityCandidates)
        let preferredName: String
        if case .resolved(let id, _) = resolution {
            preferredName = snapshot.displays.first { $0.displayID == id }?.name ?? "unknown"
        } else {
            preferredName = "not resolved"
        }
        let hostName = snapshot.dockHostDisplayID.flatMap { id in
            snapshot.displays.first { $0.displayID == id }?.name
        } ?? "unknown (no unambiguous side-Dock canvas)"
        let message: String
        switch MainDisplayPinner.decide(snapshot: snapshot, resolution: resolution, dockEdge: desiredEdge) {
        case .terminal(.alreadyOnTarget) where desiredEdge == .left || desiredEdge == .right:
            message = "observed on preferred display"
        case .terminal(let outcome):
            message = outcome.userMessage?.replacingOccurrences(of: "\n", with: " ")
                ?? "main-display decision only; placement not verified"
        case .reconfigure:
            message = "preferred display is not main; no changes made by diagnostics"
        }
        return ["Preferred:       \(preferredName)", "Observed host:   \(hostName)", "Placement:       \(message)"]
    }
}
