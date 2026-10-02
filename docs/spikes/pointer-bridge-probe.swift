// Pointer-bridge prototype (spike, not production). Default mode is read-only.
//
// Idea: keep the built-in display *virtually* below-left of the external main
// (a diagonal arrangement in which a Left Dock was confirmed on the external,
// see side-dock-display.md, E1), and recreate the old side-by-side crossing in
// software: pushing against the external's left edge lands on the built-in's
// right edge at the height the original arrangement implied, and back.
//
// --run[=seconds]  apply the diagonal arrangement (.forAppOnly), set the Dock to
//                  Left, bridge for the given time (default 120, max 600), restore.
// --x=<x>          built-in x in the diagonal arrangement (default -1400).
// --warp           reposition with CGWarpMouseCursorPosition, not by editing
//                  the event location (the clamp method the bottom guard uses).
// --post           reposition by posting a synthesized mouse event (suppression 0)
//                  instead of warping; run 4 measured a ~250 ms freeze after warps.
// --allow-shared   leave the native diagonal crossing open (blocked by default,
//                  so the bridge is the only path between displays).
// --keep-edge      do not change the Dock orientation.
// --pressure=<pt>  push needed against an edge before crossing (default 24; 0 = immediate).
//
// Requires: DockKeeper quit, exactly two displays, external main, built-in
// originally on its left, and Accessibility granted to the process running the
// probe (event taps that modify events need it). Ctrl-C restores everything;
// the .forAppOnly arrangement also reverts automatically if the process dies.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

setbuf(stdout, nil)
let _ = NSApplication.shared
let args = CommandLine.arguments
func option(_ name: String) -> String? {
    args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}
func fmt(_ p: CGPoint) -> String { "(\(Int(p.x.rounded())), \(Int(p.y.rounded())))" }

// MARK: - CoreDock orientation (private API approved by ADR-003)

let coreDock = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)!
typealias ReadEdge = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
typealias WriteEdge = @convention(c) (Int32, Int32) -> Void
let readEdge = unsafeBitCast(dlsym(coreDock, "CoreDockGetOrientationAndPinning")!, to: ReadEdge.self)
let writeEdge = unsafeBitCast(dlsym(coreDock, "CoreDockSetOrientationAndPinning")!, to: WriteEdge.self)

/// Display whose full rect matches a Dock-level canvas (same rule as DockHostDetector).
func dockHost(_ ids: [CGDirectDisplayID]) -> String {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let canvases = windows.compactMap { w -> CGRect? in
        guard w[kCGWindowOwnerName as String] as? String == "Dock",
              (w[kCGWindowLayer as String] as? NSNumber)?.int32Value == CGWindowLevelForKey(.dockWindow),
              let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }
    let hosts = ids.filter { id in canvases.contains { $0.integral == CGDisplayBounds(id).integral } }
    guard hosts.count == 1 else { return "unknown" }
    return CGDisplayIsBuiltin(hosts[0]) != 0 ? "built-in" : "external"
}

// MARK: - Displays

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

let ids = activeDisplays()
let mainID = CGMainDisplayID()
guard ids.count == 2, let builtinID = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }), builtinID != mainID else {
    print("Requires exactly two displays: an external main and the built-in secondary."); exit(2)
}
// Read once; the bridge maps against the arrangement in place at launch.
let mainFrame = CGDisplayBounds(mainID)
let builtinOriginal = CGDisplayBounds(builtinID)
guard abs(builtinOriginal.maxX - mainFrame.minX) < 1 else {
    print("Requires the built-in directly left of the main display (found \(builtinOriginal))."); exit(2)
}
let diagonalX = option("x").flatMap(Double.init) ?? -1400
let diagonalOrigin = CGPoint(x: diagonalX, y: mainFrame.maxY)

print("main (external): \(mainFrame)")
print("built-in now:    \(builtinOriginal)")
print("diagonal target: origin \(fmt(diagonalOrigin))")
print("accessibility:   \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
print("dock host:       \(dockHost(ids))")
guard args.contains(where: { $0 == "--run" || $0.hasPrefix("--run=") }) else {
    print("Read-only. Pass --run to start the experiment."); exit(0)
}
guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockkeeper.app").isEmpty else {
    fputs("Quit DockKeeper before running the experiment.\n", stderr); exit(2)
}
guard AXIsProcessTrusted() else {
    // Explained, never prompted: the tap rewrites pointer events, which macOS
    // only allows for processes the user has trusted under Accessibility.
    fputs("""
    Accessibility is required: the bridge moves the pointer between displays by
    rewriting mouse events, and macOS only allows that for trusted processes.
    Grant it to the app running this probe in System Settings › Privacy & Security
    › Accessibility, then run again. Remove the grant after the experiment.

    """, stderr)
    exit(3)
}

// MARK: - Arrangement (temporary)

func configure(builtinOrigin: CGPoint) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    guard CGConfigureDisplayOrigin(config, mainID, Int32(mainFrame.minX), Int32(mainFrame.minY)) == .success,
          CGConfigureDisplayOrigin(config, builtinID, Int32(builtinOrigin.x), Int32(builtinOrigin.y)) == .success else {
        CGCancelDisplayConfiguration(config); return false
    }
    // Reverts automatically when this process exits, even on a crash.
    return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
}

// MARK: - Bridge state (touched only from the main run loop)

let usePost = args.contains("--post")
let useWarp = args.contains("--warp") && !usePost
// Run 4: after each CGWarpMouseCursorPosition the pointer stayed frozen for
// 250–272 ms. A source with a zero suppression interval posts the move instead.
let postSource = CGEventSource(stateID: .combinedSessionState)
let originalSuppression = postSource?.localEventsSuppressionInterval
if usePost { postSource?.localEventsSuppressionInterval = 0 }
let blockShared = !args.contains("--allow-shared")
var builtinNow = builtinOriginal
var lastLocation: CGPoint?
var pendingLanding: CGPoint?
var bridgedCount = 0, blockedCount = 0, reenabledCount = 0
var tapPort: CFMachPort?
var lastBridgeAt: UInt64 = 0
// Run 2 ping-ponged: the event after a warp still read as a push against the
// edge it landed on. Land a few points inside and ignore pushes briefly.
let landingInset: CGFloat = 6
let bridgeCooldownNanos: UInt64 = 200_000_000
// Run 3 still bounced back: each landing was followed by a crossing back from
// the built-in's right edge. Require a sustained push (like a real edge's
// resistance) and trace the events after each crossing to find the cause.
let pressureThreshold = option("pressure").flatMap(Double.init) ?? 24
var pushAccum = 0.0
var pushEdge = 0              // -1 external left edge, +1 built-in right edge
var traceUntil: UInt64 = 0
var traceStart: UInt64 = 0

/// Where a push against a bridged edge should land, or nil.
func bridgeTarget(_ p: CGPoint, deltaX: Double) -> CGPoint? {
    let edge = (deltaX < 0 && mainFrame.contains(p) && p.x <= mainFrame.minX + 0.5) ? -1
        : (deltaX > 0 && builtinNow.contains(p) && p.x >= builtinNow.maxX - 1.5) ? 1 : 0
    if edge == 0 || edge != pushEdge { pushAccum = 0 }
    pushEdge = edge
    pushAccum += abs(deltaX)
    guard edge != 0, pushAccum >= pressureThreshold else { return nil }
    pushAccum = 0
    if edge < 0 {
        let offset = p.y - builtinOriginal.minY          // height inside the built-in, old arrangement
        guard offset >= 0, offset < builtinNow.height else { return nil }
        return CGPoint(x: builtinNow.maxX - 1 - landingInset, y: builtinNow.minY + offset)
    }
    let y = builtinOriginal.minY + (p.y - builtinNow.minY)
    guard y >= mainFrame.minY, y < mainFrame.maxY else { return nil }
    return CGPoint(x: mainFrame.minX + landingInset, y: y)
}

func kind(_ type: CGEventType) -> String {
    switch type {
    case .mouseMoved: return "move"
    case .leftMouseDragged: return "left-drag"
    case .rightMouseDragged: return "right-drag"
    default: return "drag"
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
        reenabledCount += 1
        print("tap re-enabled (\(type.rawValue))")
        return Unmanaged.passUnretained(event)
    }
    let p = event.location
    let nowTrace = DispatchTime.now().uptimeNanoseconds
    if nowTrace < traceUntil {
        let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
        print("    t+\((nowTrace - traceStart) / 1_000_000)ms \(kind(type)) at \(fmt(p)) dx=\(Int(dx)) dy=\(Int(dy))")
    }
    if let expected = pendingLanding {
        // First event after a bridge: did the pointer stay where we put it?
        let ok = abs(p.x - expected.x) < 40 && abs(p.y - expected.y) < 40
        print("  next event at \(fmt(p)) \(ok ? "— landed" : "— DID NOT LAND (expected \(fmt(expected)))")")
        pendingLanding = nil
    }
    let now = DispatchTime.now().uptimeNanoseconds
    if now - lastBridgeAt > bridgeCooldownNanos,
       let target = bridgeTarget(p, deltaX: event.getDoubleValueField(.mouseEventDeltaX)) {
        lastBridgeAt = now
        traceStart = now
        traceUntil = now + 1_000_000_000
        bridgedCount += 1
        if usePost {
            // Replace the event: the synthesized one carries the new position and
            // passes back through this tap away from any bridged edge.
            let button: CGMouseButton = type == .rightMouseDragged ? .right : (type == .otherMouseDragged ? .center : .left)
            CGEvent(mouseEventSource: postSource, mouseType: type, mouseCursorPosition: target, mouseButton: button)?
                .post(tap: .cghidEventTap)
            lastLocation = target
            pendingLanding = target
            print("bridge #\(bridgedCount) \(kind(type)) \(fmt(p)) -> \(fmt(target)) [post]")
            return nil
        }
        if useWarp {
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        event.location = target
        lastLocation = target
        pendingLanding = target
        print("bridge #\(bridgedCount) \(kind(type)) \(fmt(p)) -> \(fmt(target))")
        return Unmanaged.passUnretained(event)
    }
    if blockShared, let last = lastLocation {
        // Natural crossing through the diagonal's shared strip: hold it back.
        // Run 1 showed that an edited location does not hold across displays, so
        // in --warp mode the hold is a warp as well.
        var held: CGPoint?
        if mainFrame.contains(last), builtinNow.contains(p) {
            held = CGPoint(x: p.x, y: mainFrame.maxY - 1)
        } else if builtinNow.contains(last), mainFrame.contains(p) {
            held = CGPoint(x: p.x, y: builtinNow.minY)
        }
        if let held {
            if useWarp || usePost { CGWarpMouseCursorPosition(held); CGAssociateMouseAndMouseCursorPosition(1) }
            event.location = held
            blockedCount += 1
        }
    }
    lastLocation = event.location
    return Unmanaged.passUnretained(event)
}

// MARK: - Run

var originalEdge: Int32 = 0, originalAnchor: Int32 = 0
readEdge(&originalEdge, &originalAnchor)
let changeEdge = !args.contains("--keep-edge")
var cleanedUp = false

func cleanup() {
    guard !cleanedUp else { return }
    cleanedUp = true
    if let tapPort {
        CGEvent.tapEnable(tap: tapPort, enable: false)
        CFMachPortInvalidate(tapPort)
    }
    if let originalSuppression { postSource?.localEventsSuppressionInterval = originalSuppression }
    print("restore-layout:", configure(builtinOrigin: builtinOriginal.origin))
    if changeEdge { writeEdge(originalEdge, originalAnchor) }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    print("restored-bounds-match:", CGDisplayBounds(mainID) == mainFrame && CGDisplayBounds(builtinID) == builtinOriginal)
    print("summary: bridged=\(bridgedCount) blocked=\(blockedCount) tap-reenabled=\(reenabledCount)")
}

guard configure(builtinOrigin: diagonalOrigin) else { print("Configuration failed"); exit(1) }
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
builtinNow = CGDisplayBounds(builtinID)
print("built-in applied: \(builtinNow)")
// The bridge only makes sense if the external's left edge is now fully free.
guard builtinNow.minY >= mainFrame.maxY else {
    print("Arrangement was adjusted so the left edge is not free; aborting.")
    cleanup(); exit(1)
}
if changeEdge { writeEdge(3, 2) }  // Left, anchor as read on this Mac
RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
print("dock host after Left: \(dockHost(ids))")

let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
    | (1 << CGEventType.leftMouseDragged.rawValue)
    | (1 << CGEventType.rightMouseDragged.rawValue)
    | (1 << CGEventType.otherMouseDragged.rawValue)
guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: mask, callback: callback, userInfo: nil) else {
    print("CGEventTapCreate returned nil"); cleanup(); exit(1)
}
tapPort = port
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
CGEvent.tapEnable(tap: port, enable: true)

signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { print("signal \(sig): restoring"); cleanup(); exit(0) }
    source.resume()
    return source
}
let seconds = min(600, max(10, option("run").flatMap(Double.init) ?? 120))
print("""
bridging for \(Int(seconds)) s (\(usePost ? "post" : useWarp ? "warp" : "event-location") mode, pressure \(Int(pressureThreshold)) pt, shared strip \(blockShared ? "blocked" : "open")). Ctrl-C to stop.
Checklist: cross both ways at several heights · drag a window across · drag a file across ·
click Dock icons near the left edge · cross while a window is fullscreen.
""")
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { cleanup(); exit(0) }
withExtendedLifetime(signalSources) { RunLoop.main.run() }
