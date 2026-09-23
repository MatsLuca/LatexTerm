// input — human-looking mouse and keyboard for demo takes (CGEvent, global points, top-left origin).
//   input move X Y [MS]                 eased move from the current position
//   input click X Y [MODS]              move there (250 ms), click; MODS like opt or cmd+shift
//   input drag MS X1,Y1 X2,Y2 ...       press, follow the polyline in MS, release (sketching)
//   input key COMBO                     e.g. cmd+shift+return, opt+cmd+r, escape, a
//   input type TEXT [CPS]               type into the focused app, ~CPS chars/s with jitter
//   input scroll X Y DY [MS]            smooth pixel scroll (DY > 0 = read further down)
import AppKit
import CoreGraphics
import Foundation

_ = NSApplication.shared
let a = Array(CommandLine.arguments.dropFirst())
let src = CGEventSource(stateID: .hidSystemState)
func now() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func sleepMs(_ ms: Double) { usleep(useconds_t(max(0, ms) * 1000)) }

let keycodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, ",": 43, ".": 47, "/": 44, "+": 30, "-": 44,
]
func flags(_ mods: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in mods {
        switch m {
        case "cmd": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "opt", "alt": f.insert(.maskAlternate)
        case "ctrl": f.insert(.maskControl)
        default: break
        }
    }
    return f
}
func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func move(to p: CGPoint, ms: Double, button: Bool = false, f: CGEventFlags = []) {
    let s = now(); let steps = max(1, Int(ms / 8))
    for i in 1...steps {
        let t = ease(Double(i) / Double(steps))
        let q = CGPoint(x: s.x + (p.x - s.x) * t, y: s.y + (p.y - s.y) * t)
        let e = CGEvent(mouseEventSource: src, mouseType: button ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: q, mouseButton: .left)
        e?.flags = f; post(e); sleepMs(ms / Double(steps))
    }
}
func pt(_ s: String) -> CGPoint { let c = s.split(separator: ",").compactMap { Double($0) }; return CGPoint(x: c[0], y: c[1]) }

guard let cmd = a.first else { exit(2) }
switch cmd {
case "move":
    move(to: CGPoint(x: Double(a[1])!, y: Double(a[2])!), ms: a.count > 3 ? Double(a[3])! : 400)
case "click":
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
    let f = a.count > 3 ? flags(a[3].split(separator: "+").map(String.init)) : []
    move(to: p, ms: 250)
    let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left); d?.flags = f; post(d)
    sleepMs(60)
    let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left); u?.flags = f; post(u)
case "drag":
    let ms = Double(a[1])!; let pts = a.dropFirst(2).map(pt)
    guard let first = pts.first else { exit(2) }
    move(to: first, ms: 200)
    post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left))
    var total = 0.0
    for i in 1..<pts.count { total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
    for i in 1..<max(pts.count, 1) {
        let len = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        move(to: pts[i], ms: max(8, ms * len / max(total, 1)), button: true)
    }
    sleepMs(30)
    post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pts.last!, mouseButton: .left))
case "key":
    let parts = a[1].lowercased().split(separator: "+").map(String.init)
    guard let code = keycodes[parts.last!] else { FileHandle.standardError.write("unknown key \(parts.last!)\n".data(using: .utf8)!); exit(2) }
    let f = flags(Array(parts.dropLast()))
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d)
    sleepMs(30)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
case "type":
    let cps = a.count > 2 ? Double(a[2])! : 28
    for ch in a[1] {
        let s = Array(String(ch).utf16)
        // Terminals read the key code + modifiers, not only the unicode payload: map what we can.
        let lower = String(ch).lowercased()
        let code = keycodes[lower] ?? (ch == " " ? 49 : 0)
        let f: CGEventFlags = ch.isUppercase ? .maskShift : []
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        d?.flags = f; d?.keyboardSetUnicodeString(stringLength: s.count, unicodeString: s); post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        u?.flags = f; u?.keyboardSetUnicodeString(stringLength: s.count, unicodeString: s); post(u)
        sleepMs(1000 / cps * Double.random(in: 0.6...1.5) + (ch == " " ? 25 : 0))
    }
case "scroll":
    // scroll X Y DY [MS] — smooth wheel scroll at X,Y; DY > 0 moves the content up (reading down)
    move(to: CGPoint(x: Double(a[1])!, y: Double(a[2])!), ms: 250)
    let total = Double(a[3])!, ms = a.count > 4 ? Double(a[4])! : 700
    let steps = max(1, Int(ms / 16)); var done = 0.0
    for i in 1...steps {
        let target = total * ease(Double(i) / Double(steps)); let d = Int32((target - done).rounded())
        done += Double(d)
        post(CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: -d, wheel2: 0, wheel3: 0))
        sleepMs(16)
    }
default:
    exit(2)
}
