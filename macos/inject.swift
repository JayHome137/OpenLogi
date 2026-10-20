// OpenLogi Flow HW test - CGEvent mouse injection for macOS.
// Built and run by inject.sh. Requires Accessibility for the invoking process.
//
// LIMIT: OpenLogi's CGEventTap drops events whose EVENT_SOURCE_USER_DATA equals
// openlogi_inject::SYNTHETIC_EVENT_USER_DATA, but ONLY for click/scroll — mouse
// motion (MouseMoved) is NOT filtered that way (macos/translate.rs). Motion from
// a Private CGEventSource may still be treated as synthetic by the OS and may
// or may not reach the HID tap (TapLocation::HID). This probe documents the
// measured result; a real Bluetooth mouse move is the reliable trigger.
import Foundation
import CoreGraphics
import AppKit

func nowMs() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000)
}

func main() {
    let args = CommandLine.arguments
    var edge = "right"
    var approach: CGFloat = 300
    var steps = 20
    var stepMs = 8
    var dwellMs = 600
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--edge": edge = args[i+1]; i += 2
        case "--approach": approach = CGFloat(Double(args[i+1]) ?? 300); i += 2
        case "--steps": steps = Int(args[i+1]) ?? 20; i += 2
        case "--step-ms": stepMs = Int(args[i+1]) ?? 8; i += 2
        case "--dwell-ms": dwellMs = Int(args[i+1]) ?? 600; i += 2
        default: i += 1
        }
    }

    // Prefer HIDSystemState so the event looks more like real hardware to CGEventTap.
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        print("{\"ok\":false,\"error\":\"CGEventSource unavailable\"}")
        return
    }

    let screens = NSScreen.screens
    guard let screen = screens.first else {
        print("{\"ok\":false,\"error\":\"no screens\"}")
        return
    }
    // Pick the screen whose edge is outermost for the requested side.
    var frame = screen.frame
    for s in screens {
        switch edge {
        case "right": if s.frame.maxX > frame.maxX { frame = s.frame }
        case "left": if s.frame.minX < frame.minX { frame = s.frame }
        case "top": if s.frame.maxY > frame.maxY { frame = s.frame } // Cocoa Y grows up; CGEvent uses top-left origin
        case "bottom": if s.frame.minY < frame.minY { frame = s.frame }
        default: break
        }
    }
    // Convert Cocoa bottom-left coords to CG top-left (global).
    let cgHeight = screens.map { $0.frame.maxY }.max() ?? frame.maxY
    func cocoaToCG(_ p: CGPoint) -> CGPoint {
        return CGPoint(x: p.x, y: cgHeight - p.y)
    }
    let cx = frame.midX
    let cyCocoa = frame.midY
    var start = CGPoint(x: cx, y: cyCocoa)
    var target = CGPoint(x: cx, y: cyCocoa)
    switch edge {
    case "right":
        target.x = frame.maxX - 1
        start.x = target.x - approach
    case "left":
        target.x = frame.minX
        start.x = target.x + approach
    case "top":
        // Cocoa: maxY is the visual top of the screen
        target.y = frame.maxY - 1
        start.y = target.y - approach
    case "bottom":
        target.y = frame.minY
        start.y = target.y + approach
    default: break
    }

    let before = NSEvent.mouseLocation
    let tStart = nowMs()
    var tEdge: Int64 = 0
    var sent = 0
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(max(steps, 1))
        let cocoa = CGPoint(x: start.x + (target.x - start.x) * t,
                            y: start.y + (target.y - start.y) * t)
        let cg = cocoaToCG(cocoa)
        if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: cg, mouseButton: .left) {
            // Do NOT set EVENT_SOURCE_USER_DATA to OpenLogi's synthetic marker.
            ev.post(tap: .cghidEventTap)
            sent += 1
        }
        if step == steps { tEdge = nowMs() }
        Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0)
    }
    let dwellEnd = nowMs() + Int64(dwellMs)
    while nowMs() < dwellEnd {
        let cg = cocoaToCG(target)
        if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: cg, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
            sent += 1
        }
        Thread.sleep(forTimeInterval: 0.016)
    }
    let tEnd = nowMs()
    let after = NSEvent.mouseLocation
    let json = """
    {"ok":true,"method":"CGEvent.hidSystemState","edge":"\(edge)","sent":\(sent),"t_start_ms":\(tStart),"t_edge_ms":\(tEdge),"t_end_ms":\(tEnd),"target_cocoa":[\(target.x),\(target.y)],"cursor_before":[\(before.x),\(before.y)],"cursor_after":[\(after.x),\(after.y)],"note":"OpenLogi motion path is not filtered by SYNTHETIC_EVENT_USER_DATA; whether HID-tap sees Private/HIDSystemState events is machine-dependent. Prefer a real mouse move."}
    """
    print(json.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "  ", with: ""))
}

main()
