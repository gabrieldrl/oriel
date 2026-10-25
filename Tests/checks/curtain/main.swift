import Foundation
import CoreGraphics

// The Mac's screen off (docs/curtain-plan.md), against Sources/StreamProtocol and the host's
// CurtainPolicy.swift compiled into this binary (build.sh).
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }

// MARK: - The wire

check(StreamMessageKind.curtain.rawValue == 52 && StreamMessageKind(rawValue: 52) == .curtain, "kind 52 is the curtain")
check(StreamMessage.parseHeader(Data([52]) + Data(count: 9) + Data([0, 0, 0, 2]))?.kind == .curtain, "its header parses")
check(StreamMessageKind(rawValue: 51) == .displayThumbnail && StreamMessageKind(rawValue: 53) == .desktops
      && StreamMessageKind(rawValue: 56) == nil, "51 is still a picture, 53 the desktops' list, 56 free")
check(json(CurtainControl(on: true)) == #"{"on":true}"#, "on: \(json(CurtainControl(on: true)))")
check(json(CurtainControl(on: false)) == #"{"on":false}"#, "off")
check(json(CurtainControl(on: false, problem: CurtainControl.accessibility)) == #"{"on":false,"problem":"accessibility"}"#, "refused, and why")
check(Wire.decode(CurtainControl.self, from: Data(#"{"on":true,"later":1}"#.utf8)) == CurtainControl(on: true), "a later field is skipped")
check(Wire.decode(CurtainControl.self, from: Data("{}".utf8)) == nil, "no `on`: nothing to act on")
check(CurtainControl.generation == 1, "this generation is 1")
let list = WindowList(macName: "Mac", windows: [], active: .desktop, curtain: 1)
check(Wire.decode(WindowList.self, from: Wire.encode(list))?.curtain == 1, "the window list says curtain 1")
check(!json(WindowList(macName: "Mac", windows: [], active: .desktop)).contains("curtain"), "a host without it says nothing")

// MARK: - What it stops

let own: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 18, 19, 20, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32, 33, 34]
for t in own {
    check(CurtainPolicy.blocks(type: t, userData: 0), "the Mac's own \(t) is stopped")
    check(!CurtainPolicy.blocks(type: t, userData: CurtainPolicy.marker), "Oriel's own \(t) goes through")
    check(CurtainPolicy.blocks(type: t, userData: CurtainPolicy.marker + 1), "another app's mark is not Oriel's (\(t))")
}
check(CurtainPolicy.blocked == Set(own), "exactly these: \(CurtainPolicy.blocked.sorted())")
for t: UInt32 in [0, 8, 9, 13, 15, 16, 17, 21, 28, 35, 36, 0xFFFF_FFFE, 0xFFFF_FFFF] {
    check(!CurtainPolicy.blocks(type: t, userData: 0), "\(t) is left alone")
}
check(CGEventType.keyDown.rawValue == 10 && CGEventType.scrollWheel.rawValue == 22 && CGEventType.flagsChanged.rawValue == 12
      && CGEventType.otherMouseDragged.rawValue == 27 && CGEventType.mouseMoved.rawValue == 5, "CoreGraphics' numbers")
check(CurtainPolicy.marker == 0x5111_C0DE, "the mark")
var mask: CGEventMask = 0
for t in own { mask |= CGEventMask(1) << CGEventMask(t) }
check(CurtainPolicy.mask == mask, "the tap's mask is every stopped type: \(String(CurtainPolicy.mask, radix: 2))")
check(CurtainPolicy.mask & (CGEventMask(1) << 34) != 0 && CurtainPolicy.mask & (CGEventMask(1) << 28) == 0, "the mask's high bits")

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
