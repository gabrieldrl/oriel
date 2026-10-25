import Foundation

// The Mac's desktops (docs/desktops-plan.md), against Sources/StreamProtocol and the host's
// DesktopPolicy.swift compiled into this binary (build.sh). Kinds 53 to 55, how a window list says it,
// DesktopControl, DesktopList and a desktop's picture, and the policy: the window server's list read,
// the names, which set is which display, a switch's steps, whose a picture is, and a device's list.
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }
typealias Space = DesktopPolicy.Space
typealias Spaces = DesktopPolicy.DisplaySpaces

// MARK: - The kinds

func header(_ kind: UInt8) -> StreamHeader? {
    StreamMessage.parseHeader(Data([kind]) + Data(count: 9) + Data([0, 0, 0, 2]))
}
check(StreamMessageKind.desktops.rawValue == 53 && StreamMessageKind(rawValue: 53) == .desktops, "kind 53 is the list")
check(StreamMessageKind.desktopControl.rawValue == 54 && StreamMessageKind(rawValue: 54) == .desktopControl, "kind 54 is the control")
check(StreamMessageKind.desktopThumbnail.rawValue == 55 && StreamMessageKind(rawValue: 55) == .desktopThumbnail, "kind 55 is a picture")
check([53, 54, 55].allSatisfy { header($0) != nil && header($0)?.kind != .unknown }, "their headers parse")
check(StreamMessageKind(rawValue: 49) == .displays && StreamMessageKind(rawValue: 52) == .curtain, "49 and 52 are still the displays' and the curtain's")
check([29, 30, 31].allSatisfy { StreamMessageKind(rawValue: $0) == nil }, "29 to 31 stay free")
check(DesktopControl.generation == 1, "this generation is 1")
check(DesktopControl.macDisplay == 0, "the Mac's own display is 0")

// MARK: - The window list

let list = WindowList(macName: "Mac", windows: [], active: .desktop, desktops: 1)
check(json(list).contains(#""desktops":1"#), "a window list says desktops 1: \(json(list))")
check(!json(WindowList(macName: "Mac", windows: [], active: .desktop)).contains("desktops"), "a host without them leaves the key out")
let older = Wire.decode(WindowList.self, from: Data(#"{"macName":"Mac","windows":[],"active":{"desktop":{}}}"#.utf8))
check(older != nil && older?.desktops == nil, "an older host's list reads, without desktops")
check(Wire.decode(WindowList.self, from: Wire.encode(list))?.desktops == 1, "desktops reads back")

// MARK: - The control

check(json(DesktopControl()) == "{}", "the subscription is {}: \(json(DesktopControl()))")
check(json(DesktopControl(display: 0, id: 5)) == #"{"display":0,"id":5}"#, "a switch: \(json(DesktopControl(display: 0, id: 5)))")
check(Wire.decode(DesktopControl.self, from: Data("{}".utf8)) == DesktopControl(), "{} reads")
check(Wire.decode(DesktopControl.self, from: Data(#"{"display":7,"id":18446744073709551615,"later":true}"#.utf8))
      == DesktopControl(display: 7, id: .max), "the largest id and a later field read")

// MARK: - The list

let sample = DesktopList(displays: [
    DesktopSet(display: 0, current: 2, desktops: [MacDesktop(id: 1, name: "Desktop 1"), MacDesktop(id: 2, name: "Safari", app: "Safari")]),
    DesktopSet(display: 9, current: nil, desktops: [MacDesktop(id: 3, name: "Desktop 1")]),
])
check(json(sample) == #"{"displays":[{"current":2,"desktops":[{"id":1,"name":"Desktop 1"},{"app":"Safari","id":2,"name":"Safari"}],"display":0},{"desktops":[{"id":3,"name":"Desktop 1"}],"display":9}]}"#,
      "the list's JSON: \(json(sample))")
check(Wire.decode(DesktopList.self, from: Wire.encode(sample)) == sample, "the list reads back")
check(sample.set(9)?.desktops.first?.id == 3 && sample.set(0)?.current == 2 && sample.set(4) == nil, "a display's set by its id")

// MARK: - A desktop's picture

let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
let blob = ImageBlob.encodeDesktopThumbnail(spaceID: 0x0102_0304_0506_0708, jpeg: jpeg)
check(blob.prefix(8) == Data([1, 2, 3, 4, 5, 6, 7, 8]), "the space id first, big-endian: \([UInt8](blob.prefix(8)))")
check(ImageBlob.decodeDesktopThumbnail(blob).map { $0.spaceID == 0x0102_0304_0506_0708 && $0.jpeg == jpeg } == true, "it reads back")
check(ImageBlob.decodeDesktopThumbnail(Data(count: 8)) == nil, "an id without a picture is nothing")
check(ImageBlob.decodeDesktopThumbnail(blob.dropFirst(3)).map { $0.jpeg == Data(blob.suffix(from: 11)) && $0.spaceID == 0x0405_0607_08FF_D8FF } == true,
      "a slice reads from its own start")

// MARK: - The window server's list

let raw: [[String: Any]] = [
    ["Display Identifier": "AAA",
     "Current Space": ["ManagedSpaceID": NSNumber(value: 813)],
     "Spaces": [
        ["ManagedSpaceID": NSNumber(value: 8), "type": NSNumber(value: 0)],
        ["ManagedSpaceID": NSNumber(value: 813), "type": NSNumber(value: 4), "pid": NSNumber(value: 4429)],
        ["ManagedSpaceID": NSNumber(value: 6), "type": NSNumber(value: 0), "pid": NSNumber(value: 12)],
        ["ManagedSpaceID": NSNumber(value: 77), "type": NSNumber(value: 6)],
        ["type": NSNumber(value: 0)],
        ["ManagedSpaceID": NSNumber(value: 9)],
     ]],
    ["Current Space": ["ManagedSpaceID": NSNumber(value: 1)], "Spaces": []],
    ["Display Identifier": "BBB", "Spaces": [["ManagedSpaceID": NSNumber(value: 40), "type": NSNumber(value: 0)]]],
]
let parsed = DesktopPolicy.parse(raw)
check(parsed.count == 2, "a set without a display is left out: \(parsed.count)")
check(parsed.first?.uuid == "AAA" && parsed.first?.current == 813, "the display and its current space")
check(parsed.first?.spaces == [Space(id: 8), Space(id: 813, fullScreen: true, pid: 4429), Space(id: 6)],
      "desktops and full-screen apps in order, no other type, nothing without an id or a type; a desktop's pid ignored: \(parsed.first?.spaces ?? [])")
check(parsed.last?.uuid == "BBB" && parsed.last?.current == nil && parsed.last?.spaces == [Space(id: 40)], "no current space: nil")
check(DesktopPolicy.desktopType == 0 && DesktopPolicy.fullScreenType == 4, "the types")

// MARK: - The names

let apps: [Int32: String] = [4429: "Safari", 50: "Keynote"]
let names = DesktopPolicy.named([Space(id: 8), Space(id: 813, fullScreen: true, pid: 4429), Space(id: 6), Space(id: 9),
                                 Space(id: 10, fullScreen: true, pid: 51), Space(id: 11, fullScreen: true)],
                                appName: { apps[$0] })
check(names.map(\.name) == ["Desktop 1", "Safari", "Desktop 2", "Desktop 3", "Full Screen", "Full Screen"],
      "desktops numbered among desktops only, an app by its name: \(names.map(\.name))")
check(names.map(\.app) == [nil, "Safari", nil, nil, "Full Screen", "Full Screen"], "a full-screen app says so: \(names.map(\.app))")
check(names.map(\.id) == [8, 813, 6, 9, 10, 11], "the ids kept, in order")
check(DesktopPolicy.named([], appName: { _ in nil }).isEmpty, "none: none")

// MARK: - Which set is which display

let a = Spaces(uuid: "AAA", current: 8, spaces: [Space(id: 8)])
let b = Spaces(uuid: "BBB", current: 40, spaces: [Space(id: 40)])
let c = Spaces(uuid: "CCC", current: 50, spaces: [Space(id: 50)])
let shared = Spaces(uuid: "Main", current: 1, spaces: [Space(id: 1), Space(id: 2)])
var assigned = DesktopPolicy.assign([a, b, c], mainUUID: "BBB", displays: [(id: 7, uuid: "CCC"), (id: 9, uuid: "DDD")])
check(assigned[0] == b, "the Mac's own by its UUID")
check(assigned[7] == c, "an extended display by its own")
check(assigned[9] == nil && assigned.count == 2, "a display without a set gets none: \(assigned.keys.sorted())")
assigned = DesktopPolicy.assign([shared], mainUUID: "BBB", displays: [(id: 7, uuid: "CCC")])
check(assigned[0] == shared && assigned[7] == nil, "spaces shared: the one set is the Mac's own")
assigned = DesktopPolicy.assign([a, shared], mainUUID: "AAA", displays: [])
check(assigned[0] == shared, "the shared set wins")
check(DesktopPolicy.assign([a], mainUUID: nil, displays: [])[0] == nil, "no main UUID, no shared set: nothing")
check(DesktopPolicy.sharedUUID == "Main", "the shared set's name")

// MARK: - A switch's steps

let row = [Space(id: 8), Space(id: 813, fullScreen: true), Space(id: 6), Space(id: 1), Space(id: 4)]
func steps(_ from: UInt64?, _ to: UInt64, _ spaces: [Space] = row) -> String {
    DesktopPolicy.steps(from: from, to: to, in: spaces).map { "\($0.0 == .right ? "right" : "left") \($0.1)" } ?? "nil"
}
check(steps(8, 6) == "right 2", "right, through a full-screen app: \(steps(8, 6))")
check(steps(4, 8) == "left 4", "left: \(steps(4, 8))")
check(steps(813, 6) == "right 1", "one: \(steps(813, 6))")
check(steps(6, 813) == "left 1", "one left: \(steps(6, 813))")
check(steps(6, 6) == "nil", "already there: nothing")
check(steps(nil, 6) == "nil", "no current: nothing to go by")
check(steps(99, 6) == "nil" && steps(6, 99) == "nil", "a space not in the list: nothing")
let long = (1...20).map { Space(id: UInt64($0)) }
check(steps(1, 17, long) == "right 16", "as far as maxSteps: \(steps(1, 17, long))")
check(steps(1, 18, long) == "nil", "further: nothing")
check(steps(18, 2, long) == "left 16" && steps(19, 2, long) == "nil", "the limit both ways")
check(DesktopPolicy.maxSteps == 16 && DesktopPolicy.stepTimeout == 1.5, "the limits")

// MARK: - Whose a picture is

check(DesktopPolicy.tagged(before: 6, after: 6) == 6, "the same before and after: its")
check(DesktopPolicy.tagged(before: 6, after: 8) == nil, "across a switch: nobody's")
check(DesktopPolicy.tagged(before: nil, after: 8) == nil && DesktopPolicy.tagged(before: 8, after: nil) == nil, "unknown: nobody's")
check(DesktopPolicy.tagged(before: nil, after: nil) == nil, "both unknown: nobody's")

// MARK: - A device's list

let forDevice = DesktopPolicy.list([0: Spaces(uuid: "AAA", current: 813, spaces: [Space(id: 8), Space(id: 813, fullScreen: true, pid: 4429)]),
                                    7: c, 9: b, 3: a],
                                   owned: [9, 7, 5], appName: { apps[$0] })
check(forDevice.displays.map(\.display) == [0, 9, 7], "the Mac's own first, then its own in their order; another's and a missing one left out: \(forDevice.displays.map(\.display))")
check(forDevice.set(0)?.desktops == [MacDesktop(id: 8, name: "Desktop 1"), MacDesktop(id: 813, name: "Safari", app: "Safari")]
      && forDevice.set(0)?.current == 813, "named, with its current space")
check(forDevice.set(9)?.desktops == [MacDesktop(id: 40, name: "Desktop 1")], "an extended display numbered from 1")
check(DesktopPolicy.list([7: c], owned: [7], appName: { _ in nil }).displays.map(\.display) == [7], "no set for the Mac's own: its own alone")

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
