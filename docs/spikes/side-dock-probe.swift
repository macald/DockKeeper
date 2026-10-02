// Standalone experiment. Build with swiftc; default mode is read-only.
// --anchors changes only the Dock edge/anchor, then restores both.
import AppKit
import CoreGraphics
import Darwin

let _ = NSApplication.shared
let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)!
typealias Read = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
typealias Write = @convention(c) (Int32, Int32) -> Void
let read = unsafeBitCast(dlsym(handle, "CoreDockGetOrientationAndPinning")!, to: Read.self)
let write = unsafeBitCast(dlsym(handle, "CoreDockSetOrientationAndPinning")!, to: Write.self)
func observe(_ label: String) {
    var edge: Int32 = 0, anchor: Int32 = 0
    read(&edge, &anchor)
    print("\(label): edge=\(edge) anchor=\(anchor)")
    for screen in NSScreen.screens {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        print("  display=\(screen.localizedName) main=\(id == CGMainDisplayID()) cg=\(CGDisplayBounds(id))")
    }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in windows where w[kCGWindowOwnerName as String] as? String == "Dock" {
        print("  Dock window layer=\(w[kCGWindowLayer as String] ?? "?") bounds=\(w[kCGWindowBounds as String] ?? "?")")
    }
}
func anchors() {
    var edge: Int32 = 0, anchor: Int32 = 0
    read(&edge, &anchor)
    defer {
        write(edge, anchor)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        observe("restored")
    }
    for side: Int32 in [3, 4] {
        for pin: Int32 in [1, 2, 3] {
            write(side, pin)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            observe("requested \(side)/\(pin)")
        }
    }
}
func layoutProbe() {
    let screens = NSScreen.screens
    guard screens.count == 2 else { print("Requires exactly two displays"); return }
    let ids = screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
    guard let builtin = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }), builtin != CGMainDisplayID() else {
        print("Requires external main and built-in secondary"); return
    }
    let original = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGDisplayBounds($0)) })
    var edge: Int32 = 0, anchor: Int32 = 0
    read(&edge, &anchor)
    func configure(_ delta: CGFloat) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in ids {
            let frame = original[id]!
            let y = frame.minY + (id == builtin ? delta : 0)
            guard CGConfigureDisplayOrigin(config, id, Int32(frame.minX), Int32(y)) == .success else {
                CGCancelDisplayConfiguration(config); return false
            }
        }
        // Automatically reverts when this process exits, even on a crash.
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
    defer {
        print("restore-layout:", configure(0))
        write(edge, anchor)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        observe("restored-layout")
    }
    write(3, 2)
    for delta: CGFloat in [-100, -51, 51, 100, 200] {
        guard configure(delta) else { print("Configuration failed"); return }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
        write(3, 2)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        observe("builtin vertical delta \(delta)")
    }
}
observe("baseline")
if CommandLine.arguments.contains("--layout") {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockkeeper.app").isEmpty else {
        fputs("Quit DockKeeper before running the mutating probe.\n", stderr)
        exit(2)
    }
    layoutProbe()
}
if CommandLine.arguments.contains("--anchors") {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockkeeper.app").isEmpty else {
        fputs("Quit DockKeeper before running the mutating probe.\n", stderr)
        exit(2)
    }
    anchors()
}
