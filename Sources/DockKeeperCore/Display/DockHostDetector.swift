import AppKit
import CoreGraphics

/// Read-only observation of the Dock's on-screen canvas. Does not use cached
/// NSScreen.visibleFrame / CoreDockGetRect, request permissions, or read titles.
/// Full-display Dock canvases at the Dock window level are confirmed on macOS
/// 27.0.1; other shapes/versions may return unknown. Never infer host from main.
public enum DockHostDetector {
    /// Pure matching seam. Multiple matching displays (including mirrors) are
    /// ambiguous. No arbitrary largest-window / nearest-display fallback.
    public static func hostDisplayID(canvasFrames: [CGRect], displays: [DisplayInfo]) -> CGDirectDisplayID? {
        let matches = Set(displays.filter { display in
            canvasFrames.contains { frame in
                frame.width > 0 && frame.height > 0 &&
                abs(frame.minX - display.frame.minX) < 1 &&
                abs(frame.minY - display.frame.minY) < 1 &&
                abs(frame.width - display.frame.width) < 1 &&
                abs(frame.height - display.frame.height) < 1
            }
        }.map(\.displayID))
        return matches.count == 1 ? matches.first : nil
    }

    @MainActor
    public static func live(displays: [DisplayInfo]) -> CGDirectDisplayID? {
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard docks.count == 1, let pid = docks.first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == CGWindowLevelForKey(.dockWindow),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
        return hostDisplayID(canvasFrames: frames, displays: displays)
    }
}
