// Standalone experiment. Build with swiftc; default mode is read-only.
// --anchors changes only the Dock edge/anchor, then restores both.
// --stacked temporarily centers the built-in display below the external main.
// --hysteresis also observes the return to the original layout before restoring edge.
// --partial leaves 200 points of shared edge with the built-in display on the left.
// --diagonal=<x> puts the built-in below the external main at x (top edge on its bottom edge).
// --at=<x>,<y> puts the built-in at an arbitrary origin (e.g. left of the main, outside the Dock band).
// --measure sets Left briefly and reports the Dock rect, then restores the edge (--hold=<s> extends it).
import AppKit
import CoreGraphics
import Darwin

let _ = NSApplication.shared
setbuf(stdout, nil)
let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)!
typealias Read = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
typealias Write = @convention(c) (Int32, Int32) -> Void
let read = unsafeBitCast(dlsym(handle, "CoreDockGetOrientationAndPinning")!, to: Read.self)
let write = unsafeBitCast(dlsym(handle, "CoreDockSetOrientationAndPinning")!, to: Write.self)
typealias GetRect = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
let getRect = unsafeBitCast(dlsym(handle, "CoreDockGetRect")!, to: GetRect.self)
func observe(_ label: String) {
    var edge: Int32 = 0, anchor: Int32 = 0
    read(&edge, &anchor)
    var rect = CGRect.zero
    getRect(&rect)
    print("\(label): edge=\(edge) anchor=\(anchor) coreDockRect=\(rect)")
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
func measure() {
    var edge: Int32 = 0, anchor: Int32 = 0
    read(&edge, &anchor)
    defer {
        write(edge, anchor)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        observe("restored")
    }
    write(3, 2)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
    observe("left at 2s")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 4))
    observe("left at 6s")
    let hold = CommandLine.arguments.first { $0.hasPrefix("--hold=") }.flatMap { Double($0.dropFirst("--hold=".count)) } ?? 0
    if hold > 6 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: hold - 6))
        observe("left at \(Int(hold))s")
    }
}
func layoutProbe(stacked: Bool = false, hysteresis: Bool = false, partial: Bool = false, diagonalX: CGFloat? = nil, at: CGPoint? = nil) {
    let screens = NSScreen.screens
    guard screens.count == 2 else { print("Requires exactly two displays"); return }
    let ids = screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
    guard let builtin = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }), builtin != CGMainDisplayID() else {
        print("Requires external main and built-in secondary"); return
    }
    let original = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGDisplayBounds($0)) })
    let mainFrame = original[CGMainDisplayID()]!
    var edge: Int32 = 0, anchor: Int32 = 0
    read(&edge, &anchor)
    func configure(_ delta: CGFloat) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in ids {
            let frame = original[id]!
            let moveBelow = stacked && delta != 0 && id == builtin
            let movePartial = partial && delta != 0 && id == builtin
            let moveDiagonal = diagonalX != nil && delta != 0 && id == builtin
            var x = movePartial ? mainFrame.minX - frame.width : (moveBelow ? mainFrame.midX - frame.width / 2 : frame.minX)
            var y = movePartial ? mainFrame.maxY - 200 : (moveBelow ? mainFrame.maxY : frame.minY + (id == builtin && !stacked && !partial && diagonalX == nil && at == nil ? delta : 0))
            if moveDiagonal, let diagonalX { x = diagonalX; y = mainFrame.maxY }
            if let at, delta != 0, id == builtin { x = at.x; y = at.y }
            guard CGConfigureDisplayOrigin(config, id, Int32(x), Int32(y)) == .success else {
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
        print("restored-bounds-match:", ids.allSatisfy { CGDisplayBounds($0) == original[$0]! })
    }
    write(3, 2)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
    observe("left before layout change")
    let staged = stacked || partial || diagonalX != nil || at != nil
    let layoutLabel = at.map { "at (\(Int($0.x)), \(Int($0.y)))" } ?? diagonalX.map { "diagonal x=\(Int($0))" } ?? (partial ? "partial overlap 200pt" : "stacked")
    for delta: CGFloat in (staged ? [1] : [-100, -51, 51, 100, 200]) {
        guard configure(delta) else { print("Configuration failed"); return }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
        if !hysteresis && !partial && diagonalX == nil && at == nil { write(3, 2) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        observe(staged ? "\(layoutLabel) at 2s" : "builtin vertical delta \(delta)")
        if staged {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
            observe("\(layoutLabel) at 5s")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
            observe("\(layoutLabel) at 10s")
            if partial || diagonalX != nil || at != nil {
                write(3, 2)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
                observe("\(layoutLabel) after reapplying Left at 2s")
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
                observe("\(layoutLabel) after reapplying Left at 5s")
            }
            if hysteresis {
                guard configure(0) else { print("Return configuration failed"); return }
                var elapsed = 0
                for interval in [2, 3, 5, 20] {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: Double(interval)))
                    elapsed += interval
                    observe("original layout, no orientation write, at \(elapsed)s")
                }
            }
        }
    }
}
observe("baseline")
let diagonalX = CommandLine.arguments.first { $0.hasPrefix("--diagonal=") }
    .flatMap { Double($0.dropFirst("--diagonal=".count)) }.map { CGFloat($0) }
let atOrigin = CommandLine.arguments.first { $0.hasPrefix("--at=") }.flatMap { arg -> CGPoint? in
    let parts = arg.dropFirst("--at=".count).split(separator: ",").compactMap { Double($0) }
    return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
}
if CommandLine.arguments.contains("--measure") {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockkeeper.app").isEmpty else {
        fputs("Quit DockKeeper before running the mutating probe.\n", stderr)
        exit(2)
    }
    measure()
}
if diagonalX != nil || atOrigin != nil || CommandLine.arguments.contains("--layout") || CommandLine.arguments.contains("--stacked") || CommandLine.arguments.contains("--hysteresis") || CommandLine.arguments.contains("--partial") {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockkeeper.app").isEmpty else {
        fputs("Quit DockKeeper before running the mutating probe.\n", stderr)
        exit(2)
    }
    let hysteresis = CommandLine.arguments.contains("--hysteresis")
    layoutProbe(stacked: hysteresis || CommandLine.arguments.contains("--stacked"), hysteresis: hysteresis,
                partial: CommandLine.arguments.contains("--partial"), diagonalX: diagonalX, at: atOrigin)
}
if CommandLine.arguments.contains("--anchors") {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockkeeper.app").isEmpty else {
        fputs("Quit DockKeeper before running the mutating probe.\n", stderr)
        exit(2)
    }
    anchors()
}
