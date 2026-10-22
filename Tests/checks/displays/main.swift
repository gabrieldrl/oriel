import Foundation
import CoreGraphics

// The extended displays (docs/displays-plan.md), against Sources/StreamProtocol and the host's
// DisplayPolicy.swift compiled into this binary (build.sh). Kinds 49 to 51, StreamSource.display and
// how a window list says it, DisplayControl and DisplayList, the serial numbers, slots, sizes, the
// endings, which windows go back and where, and the memory.
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }

// MARK: - The kinds

func header(_ kind: UInt8) -> StreamHeader? {
    StreamMessage.parseHeader(Data([kind]) + Data(count: 9) + Data([0, 0, 0, 2]))
}
check(StreamMessageKind.displays.rawValue == 49 && StreamMessageKind(rawValue: 49) == .displays, "kind 49 is the list")
check(StreamMessageKind.displayControl.rawValue == 50 && StreamMessageKind(rawValue: 50) == .displayControl, "kind 50 is the control")
check(StreamMessageKind.displayThumbnail.rawValue == 51 && StreamMessageKind(rawValue: 51) == .displayThumbnail, "kind 51 is a picture")
check([49, 50, 51].allSatisfy { header($0) != nil && header($0)?.kind != .unknown }, "their headers parse")
check(StreamMessageKind(rawValue: 47) == .sound && StreamMessageKind(rawValue: 48) == .soundControl, "47 and 48 are still the sound's")
check([29, 30, 31].allSatisfy { StreamMessageKind(rawValue: $0) == nil }, "29 to 31 stay free")
check(DisplayControl.generation == 1, "this generation is 1")

// MARK: - The source and the window list

let three: [StreamSource] = [.none, .desktop, .window(7)]
let oldJSON = three.map(json)
check(oldJSON == [#"{"none":{}}"#, #"{"desktop":{}}"#, #"{"window":{"_0":7}}"#], "the first three cases read as before: \(oldJSON)")
check(json(StreamSource.display(258)) == #"{"display":{"_0":258}}"#, "a display pick: \(json(StreamSource.display(258)))")
check(Wire.decode(StreamSource.self, from: Wire.encode(StreamSource.display(258))) == .display(258), "a display pick reads back")

check(StreamSource.display(3).listed.active == .desktop && StreamSource.display(3).listed.showing == 3,
      "a display is listed as the Desktop showing it")
for s in three {
    check(s.listed.active == s && s.listed.showing == nil, "\(s) is listed as itself")
}
check(StreamSource.desktop.isDesktop && StreamSource.display(1).isDesktop, "the Desktop and a display take the Desktop's menus")
check(!StreamSource.none.isDesktop && !StreamSource.window(1).isDesktop, "nothing and a window do not")

let shown = StreamSource.display(513).listed
let list = WindowList(macName: "Mac", windows: [], active: shown.active, displays: DisplayControl.generation, showing: shown.showing)
let listJSON = json(list)
check(listJSON.contains(#""displays":1"#) && listJSON.contains(#""showing":513"#), "the list says displays 1 and what shows: \(listJSON)")
check(listJSON.contains(#""active":{"desktop":{}}"#), "and the Desktop as active, which an older device reads: \(listJSON)")
check(!listJSON.contains(#""display""#), "never the new case: \(listJSON)")
let back = Wire.decode(WindowList.self, from: Data(listJSON.utf8))
check(back?.source == .display(513), "a device reads the display back: \(String(describing: back?.source))")
check(WindowList(macName: "Mac", windows: [], active: .window(9), showing: 5).source == .window(9), "showing counts only on the Desktop")
check(WindowList(macName: "Mac", windows: [], active: .desktop).source == .desktop, "no showing: the Desktop")
let plain = json(WindowList(macName: "Mac", windows: [], active: .desktop))
check(!plain.contains("displays") && !plain.contains("showing"), "a host without displays leaves both out: \(plain)")
// What a device before displays decodes the list into: the same struct without the two fields.
struct OldList: Decodable { var macName: String; var active: StreamSource; var sound: Int? }
check((try? JSONDecoder().decode(OldList.self, from: Data(listJSON.utf8)))?.active == .desktop, "an older device decodes it, on the Desktop")

// MARK: - DisplayControl and DisplayList

check(json(DisplayControl()) == "{}", "the subscription is {}: \(json(DisplayControl()))")
check(json(DisplayControl(action: DisplayControl.add, width: 1180, height: 760)) == #"{"action":"add","height":760,"width":1180}"#,
      "an add: \(json(DisplayControl(action: DisplayControl.add, width: 1180, height: 760)))")
check(json(DisplayControl(action: DisplayControl.remove, id: 9)) == #"{"action":"remove","id":9}"#, "a remove")
check(json(DisplayControl(action: DisplayControl.end)) == #"{"action":"end"}"#, "Disconnect")
check([DisplayControl.add, DisplayControl.remove, DisplayControl.resize, DisplayControl.end] == ["add", "remove", "resize", "end"],
      "the actions' words")
check(json(DisplayControl(action: DisplayControl.resize, id: 9, match: DisplayControl.primary)) == #"{"action":"resize","id":9,"match":"primary"}"#,
      "a resize to the Mac's own")
check(json(DisplayControl(action: DisplayControl.resize, id: 9, width: 1180, height: 760)) == #"{"action":"resize","height":760,"id":9,"width":1180}"#,
      "a resize to a size")
check(json(ExtendedDisplay(id: 9, name: "Display 2", width: 3024, height: 1964, matchesPrimary: true))
      == #"{"height":1964,"id":9,"matchesPrimary":true,"name":"Display 2","width":3024}"#, "a display matching the Mac's own says so")
check(json(ExtendedDisplay(id: 9, name: "Display 2", width: 1180, height: 760)) == #"{"height":760,"id":9,"name":"Display 2","width":1180}"#,
      "one at its own size leaves it out")
check(Wire.decode(DisplayControl.self, from: Data(#"{"action":"later","more":1}"#.utf8))?.action == "later", "a later action decodes, to be ignored")
let dl = DisplayList(displays: [ExtendedDisplay(id: 258, name: "Display 2", width: 1180, height: 760)], max: 4, problem: "limit")
check(Wire.decode(DisplayList.self, from: Wire.encode(dl)) == dl, "a list reads back whole")
check(json(DisplayList(displays: [], max: 4)) == #"{"displays":[],"max":4}"#, "no problem leaves it out")
check(DisplayList.grace == 30, "a lost connection's displays wait 30 s")

// MARK: - Serial numbers and slots

let a = "aabbccdd", b = "aabbccde"
check(DisplayPolicy.serial(owner: a, slot: 1) == DisplayPolicy.serial(owner: a, slot: 1), "the same device and slot: the same number")
check(DisplayPolicy.serial(owner: a, slot: 1) != DisplayPolicy.serial(owner: a, slot: 2), "another slot, another number")
check(DisplayPolicy.serial(owner: a, slot: 1) != DisplayPolicy.serial(owner: b, slot: 1), "another device, another number")
check(DisplayPolicy.serial(owner: a, slot: 3) >> 8 == DisplayPolicy.serial(owner: a, slot: 1) >> 8, "a device's slots share their top 24 bits")
for slot in 1...DisplayPolicy.maxPerDevice {
    check(DisplayPolicy.slot(of: DisplayPolicy.serial(owner: a, slot: slot)) == slot, "slot \(slot) reads back from its id")
}
// FNV-1a 32 of "a" is 0xE40C292C: its top 24 bits, then the slot.
check(DisplayPolicy.serial(owner: "a", slot: 2) == 0xE40C_2902, "FNV-1a's top 24 bits: \(String(DisplayPolicy.serial(owner: "a", slot: 2), radix: 16))")
var zeros = 0
for i in 0..<20_000 where DisplayPolicy.serial(owner: "device-\(i)", slot: 1) >> 8 == 0 { zeros += 1 }
check(zeros == 0, "never a device part of 0")
check(DisplayPolicy.serial(owner: "", slot: 1) != 0, "never 0")
// FNV-1a 32 of "k7375117" is 0x0000004F: its top 24 bits are 0, which becomes 1.
check(DisplayPolicy.serial(owner: "k7375117", slot: 2) == 0x102, "a device part of 0 becomes 1: \(String(DisplayPolicy.serial(owner: "k7375117", slot: 2), radix: 16))")
var seen = Set<UInt32>(), clashes = 0
for i in 0..<2000 { if !seen.insert(DisplayPolicy.serial(owner: "key-\(i)", slot: 1)).inserted { clashes += 1 } }
check(clashes <= 1, "2000 devices rarely share a number: \(clashes)")

check(DisplayPolicy.vendorID == 0x5111, "Sill's vendor, which keeps the app's windows off them")
check(DisplayPolicy.productID == 2, "a product of their own, not the window stage's 1")
check(DisplayPolicy.maxPerDevice == 4, "four displays a device")
check(DisplayPolicy.nextSlot(used: []) == 1, "the first slot is 1")
check(DisplayPolicy.nextSlot(used: [1, 2]) == 3, "then the next free")
check(DisplayPolicy.nextSlot(used: [2, 3]) == 1, "a slot freed is taken first")
check(DisplayPolicy.nextSlot(used: [1, 2, 3, 4]) == nil, "none past four")
check(DisplayPolicy.nextSlot(used: [1, 2, 3]) == 4, "the fourth")
check(DisplayPolicy.name(slot: 1, among: [1]) == "Display 2" && DisplayPolicy.name(slot: 4, among: [1, 2, 3, 4]) == "Display 5",
      "the Mac's own is the first")
check(DisplayPolicy.name(slot: 2, among: [2]) == "Display 2", "a gap below closes: slot 2 alone is Display 2")
check(DisplayPolicy.name(slot: 3, among: [1, 3]) == "Display 3" && DisplayPolicy.name(slot: 1, among: [1, 3]) == "Display 2",
      "two with a gap between: 2 and 3")
check(DisplayPolicy.name(slot: 4, among: [4, 2, 2]) == "Display 3", "the order given and a repeat do not count")
check(DisplayPolicy.name(slot: 1, among: [2, 3]) == "Display 2", "one not yet among them: by its place")

check(DisplayPolicy.owner(fingerprint: Data([0x0a, 0xff]), name: "iPad") == "0aff", "a key's owner is its hex")
check(DisplayPolicy.owner(fingerprint: nil, name: "iPad") == "name:iPad", "no key: its name")
check(DisplayPolicy.owner(fingerprint: Data(), name: "iPad") == "name:iPad", "an empty key: its name")

// MARK: - Sizes

check(DisplayPolicy.size(width: 1180, height: 760) == (1180, 760), "the room asked")
check(DisplayPolicy.size(width: 1181, height: 761) == (1180, 760), "even sides")
check(DisplayPolicy.size(width: nil, height: 760) == DisplayPolicy.defaultSize, "nothing asked: the default")
check(DisplayPolicy.size(width: 0, height: 760) == DisplayPolicy.defaultSize, "nothing usable: the default")
check(DisplayPolicy.size(width: -5, height: -5) == DisplayPolicy.defaultSize, "a negative size: the default")
check(DisplayPolicy.defaultSize == (1366, 1024), "an iPad Pro 13-inch's points")
check(DisplayPolicy.size(width: 100, height: 50) == (640, 640), "at least 640 a side")
check(DisplayPolicy.size(width: 9000, height: 5000) == (3840, 3840), "at most 3840 a side")
check(DisplayPolicy.size(width: 640, height: 3840) == (640, 3840), "the limits themselves")
check(DisplayPolicy.size(width: 760, height: 1180) == (760, 1180), "upright stays upright")

// A resize, and a display matching the Mac's own.
typealias Slot = DisplayPolicy.Memory.Slot
let retina = DisplayPolicy.Primary(width: 1512, height: 982, pixelWidth: 3024)
let full = DisplayPolicy.Primary(width: 3024, height: 1964, pixelWidth: 3024)
check(retina.scale == 2 && full.scale == 1, "a Retina display is 2×, one at its full resolution 1×")
check(DisplayPolicy.Primary(width: 1800, height: 1169, pixelWidth: 3600).scale == 2, "a scaled mode is drawn at 2× (its backing)")
check(DisplayPolicy.Primary(width: 0, height: 0, pixelWidth: 0).scale == 1, "no size: 1×")
let toPrimary = DisplayControl(action: DisplayControl.resize, id: 9, match: DisplayControl.primary)
check(DisplayPolicy.resized(toPrimary, slot: 2, primary: retina) == Slot(slot: 2, width: 1512, height: 982, matchesPrimary: true),
      "as a Retina Mac's: its points at 2×: \(DisplayPolicy.resized(toPrimary, slot: 2, primary: retina))")
check(DisplayPolicy.resized(toPrimary, slot: 2, primary: full) == Slot(slot: 2, width: 3024, height: 1964, matchesPrimary: true, scale: 1),
      "as a Mac at its full resolution: its points at 1×: \(DisplayPolicy.resized(toPrimary, slot: 2, primary: full))")
check(DisplayPolicy.resized(DisplayControl(action: DisplayControl.resize, id: 9, width: 1181, height: 760), slot: 3, primary: full)
      == Slot(slot: 3, width: 1180, height: 760), "to a size: clamped as an add, at 2×, not matching")
check(DisplayPolicy.resized(DisplayControl(action: DisplayControl.resize, id: 9, match: "other"), slot: 1, primary: full)
      == Slot(slot: 1, width: DisplayPolicy.defaultSize.width, height: DisplayPolicy.defaultSize.height),
      "another match and no size: the default")
let matched = Slot(slot: 2, width: 1512, height: 982, matchesPrimary: true)
check(DisplayPolicy.bringingBack(matched, primary: full) == Slot(slot: 2, width: 3024, height: 1964, matchesPrimary: true, scale: 1),
      "a matching display comes back as the Mac's own is now")
check(DisplayPolicy.bringingBack(Slot(slot: 2, width: 1180, height: 760), primary: full) == Slot(slot: 2, width: 1180, height: 760),
      "one at its own size comes back at it")
check(DisplayPolicy.bringingBack(Slot(slot: 2, width: 1180, height: 760, matchesPrimary: false), primary: full).width == 1180,
      "matchesPrimary false is not matching")

// MARK: - Endings

check(DisplayPolicy.keepFor(.disconnect) == 0, "Disconnect: now")
check(DisplayPolicy.keepFor(.removed) == 0, "a remove: now")
check(DisplayPolicy.keepFor(.lost) == 30, "lost: the grace")
check(DisplayPolicy.keepsWindows(.disconnect) && DisplayPolicy.keepsWindows(.lost), "both keep their windows to come back")
check(!DisplayPolicy.keepsWindows(.removed), "a display removed for good keeps none")

// MARK: - Windows

let display = CGRect(x: 1512, y: 0, width: 1180, height: 760)
check(DisplayPolicy.isOn(CGRect(x: 1600, y: 100, width: 400, height: 300), display: display), "a window inside is on it")
check(DisplayPolicy.isOn(CGRect(x: 1300, y: 100, width: 600, height: 300), display: display), "its centre on it: on it")
check(!DisplayPolicy.isOn(CGRect(x: 1000, y: 100, width: 600, height: 300), display: display), "its centre off it: not")
check(!DisplayPolicy.isOn(CGRect(x: 100, y: 100, width: 400, height: 300), display: display), "the Mac's own display: not")

var k = DisplayPolicy.Kept(slot: 1, windowID: 42, pid: 7, app: "Notes", title: "x", offset: CGPoint(x: 88, y: 40),
                           size: CGSize(width: 400, height: 300), fellTo: CGRect(x: 88, y: 40, width: 400, height: 300))
check(DisplayPolicy.returns(k, now: CGRect(x: 88, y: 40, width: 400, height: 300)), "where macOS put it: it goes back")
check(DisplayPolicy.returns(k, now: CGRect(x: 90, y: 38, width: 401, height: 299)), "within 2 points: still there")
check(!DisplayPolicy.returns(k, now: CGRect(x: 91, y: 40, width: 400, height: 300)), "moved 3 points: it stays")
check(!DisplayPolicy.returns(k, now: CGRect(x: 88, y: 43, width: 400, height: 300)), "moved down: it stays")
check(!DisplayPolicy.returns(k, now: CGRect(x: 88, y: 40, width: 403, height: 300)), "resized: it stays")
check(!DisplayPolicy.returns(k, now: CGRect(x: 88, y: 40, width: 400, height: 303)), "taller: it stays")
check(!DisplayPolicy.returns(k, now: nil), "closed: nothing goes back")
k.fellTo = nil
check(DisplayPolicy.returns(k, now: CGRect(x: 500, y: 500, width: 10, height: 10)), "not seen falling (Sill quit): it goes back")
check(!DisplayPolicy.returns(k, now: nil), "unless it closed")

let p = DisplayPolicy.placed(k, on: display)
check(p == CGPoint(x: 1600, y: 40), "the same place from the display's corner: \(p)")
let elsewhere = CGRect(x: -1180, y: 200, width: 1180, height: 760)
check(DisplayPolicy.placed(k, on: elsewhere) == CGPoint(x: -1092, y: 240), "wherever the display went: \(DisplayPolicy.placed(k, on: elsewhere))")
var far = k; far.offset = CGPoint(x: 1100, y: 700)
let small = CGRect(x: 0, y: 0, width: 800, height: 600)
check(DisplayPolicy.placed(far, on: small) == CGPoint(x: 700, y: 500), "a smaller display: 100 points stay on it: \(DisplayPolicy.placed(far, on: small))")
var left = k; left.offset = CGPoint(x: -380, y: -50)
check(DisplayPolicy.placed(left, on: small) == CGPoint(x: -300, y: 0), "off its left: 100 points stay; never above its top: \(DisplayPolicy.placed(left, on: small))")
var tiny = k; tiny.size = CGSize(width: 60, height: 50); tiny.offset = CGPoint(x: 5000, y: 5000)
check(DisplayPolicy.placed(tiny, on: small) == CGPoint(x: 740, y: 550), "a window smaller than 100 points stays whole: \(DisplayPolicy.placed(tiny, on: small))")

// MARK: - Memory

var m = DisplayPolicy.Memory()
m.owners["0aff"] = .init(slots: [.init(slot: 1, width: 1180, height: 760), .init(slot: 2, width: 3024, height: 1964, matchesPrimary: true, scale: 1)],
                        windows: [k])
let mjson = Wire.encode(m)
check(Wire.decode(DisplayPolicy.Memory.self, from: mjson) == m, "the memory reads back whole")
check(Wire.decode(DisplayPolicy.Memory.self, from: Data(#"{"owners":{}}"#.utf8)) == DisplayPolicy.Memory(), "an empty one reads")
check(Wire.decode(Slot.self, from: Data(#"{"slot":1,"width":1180,"height":760}"#.utf8)) == Slot(slot: 1, width: 1180, height: 760),
      "a slot saved before resizing reads")

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
