import Foundation

// Extended Use (docs/extended-use-plan.md), against Sources/StreamProtocol and the host's
// KeepAwakePolicy.swift compiled into this binary (build.sh).
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }

// MARK: - The wire

check(StreamMessageKind.keepAwake.rawValue == 56 && StreamMessageKind(rawValue: 56) == .keepAwake, "kind 56 is Extended Use")
check(StreamMessage.parseHeader(Data([56]) + Data(count: 9) + Data([0, 0, 0, 2]))?.kind == .keepAwake, "its header parses")
check(StreamMessageKind(rawValue: 55) == .desktopThumbnail && StreamMessageKind(rawValue: 57) == nil, "55 is still a desktop's picture, 57 free")
check(json(KeepAwake(mode: "always")) == #"{"mode":"always"}"#, "a device's choice: \(json(KeepAwake(mode: "always")))")
let full = KeepAwake(mode: "plugged", awake: false, battery: true, onPower: false, problem: nil)
check(json(full) == #"{"awake":false,"battery":true,"mode":"plugged","onPower":false}"#, "the host's state: \(json(full))")
check(json(KeepAwake(mode: "always", awake: false, problem: KeepAwake.approval)) == #"{"awake":false,"mode":"always","problem":"approval"}"#,
      "waiting for Login Items, and why")
check(KeepAwake.approval == "approval" && KeepAwake.unavailable == "unavailable", "the problems' words")
check(Wire.decode(KeepAwake.self, from: Data(#"{"mode":"off","later":1}"#.utf8)) == KeepAwake(mode: "off"), "a later field is skipped")
check(Wire.decode(KeepAwake.self, from: Data(#"{"mode":"weekdays"}"#.utf8)) == KeepAwake(mode: "weekdays"), "a later mode still decodes")
check(Wire.decode(KeepAwake.self, from: Data("{}".utf8)) == nil, "no `mode`: nothing to act on")
check(KeepAwake.generation == 1, "this generation is 1")
let list = WindowList(macName: "Mac", windows: [], active: .desktop, keepAwake: 1)
check(Wire.decode(WindowList.self, from: Wire.encode(list))?.keepAwake == 1, "the window list says keepAwake 1")
check(json(list).contains(#""keepAwake":1"#), "under its own key")
check(!json(WindowList(macName: "Mac", windows: [], active: .desktop)).contains("keepAwake"), "a host without it says nothing")

// MARK: - The modes

check(KeepAwakeMode.allCases.map(\.rawValue) == ["off", "always", "plugged"], "three modes: \(KeepAwakeMode.allCases.map(\.rawValue))")
check(KeepAwakePolicy.mode("always") == .always && KeepAwakePolicy.mode("plugged") == .plugged && KeepAwakePolicy.mode("off") == .off,
      "each mode reads")
check(KeepAwakePolicy.mode("weekdays") == nil && KeepAwakePolicy.mode("") == nil && KeepAwakePolicy.mode("Always") == nil,
      "a mode this generation does not know is ignored")

// MARK: - When the Mac is held

for power in [true, false] {
    check(!KeepAwakePolicy.wants(.off, onPower: power), "Off never holds (power \(power))")
    check(KeepAwakePolicy.wants(.always, onPower: power), "Always holds (power \(power))")
}
check(KeepAwakePolicy.wants(.plugged, onPower: true) && !KeepAwakePolicy.wants(.plugged, onPower: false), "When Plugged In: only on the adapter")
let helpers: [KeepAwakePolicy.Helper] = [.enabled, .requiresApproval, .notRegistered, .notFound, .unavailable]
for h in helpers {
    check(KeepAwakePolicy.hold(.always, onPower: false, helper: h) == (h == .enabled), "Always holds only with the helper enabled (\(h))")
    check(!KeepAwakePolicy.hold(.off, onPower: true, helper: h), "Off asks for nothing (\(h))")
}
check(KeepAwakePolicy.hold(.plugged, onPower: true, helper: .enabled) && !KeepAwakePolicy.hold(.plugged, onPower: false, helper: .enabled),
      "When Plugged In follows the adapter")

// MARK: - The helper's registration

check(KeepAwakePolicy.register(.always, helper: .notRegistered) && KeepAwakePolicy.register(.plugged, helper: .notFound),
      "a mode other than Off registers a helper not yet registered")
check(KeepAwakePolicy.register(.plugged, helper: .notRegistered), "When Plugged In registers it too, on battery or not")
check(!KeepAwakePolicy.register(.off, helper: .notRegistered) && !KeepAwakePolicy.register(.off, helper: .notFound), "Off registers nothing")
for h in [KeepAwakePolicy.Helper.enabled, .requiresApproval, .unavailable] {
    check(!KeepAwakePolicy.register(.always, helper: h), "registered once, never again (\(h))")
}

// MARK: - What the state says

check(KeepAwakePolicy.problem(.always, onPower: true, helper: .enabled) == nil, "held: no problem")
for h in [KeepAwakePolicy.Helper.requiresApproval, .notRegistered, .notFound] {
    check(KeepAwakePolicy.problem(.always, onPower: true, helper: h) == KeepAwake.approval, "waiting for approval (\(h))")
}
check(KeepAwakePolicy.problem(.always, onPower: true, helper: .unavailable) == KeepAwake.unavailable, "this build cannot")
check(KeepAwakePolicy.problem(.off, onPower: true, helper: .requiresApproval) == nil, "Off wants nothing, so nothing is missing")
check(KeepAwakePolicy.problem(.plugged, onPower: false, helper: .unavailable) == nil, "off the adapter, When Plugged In wants nothing yet")
let held = KeepAwakePolicy.state(.always, held: true, battery: true, onPower: false, helper: .enabled)
check(held == KeepAwake(mode: "always", awake: true, battery: true, onPower: false, problem: nil), "Always, held: \(json(held))")
let waiting = KeepAwakePolicy.state(.plugged, held: false, battery: true, onPower: false, helper: .enabled)
check(waiting == KeepAwake(mode: "plugged", awake: false, battery: true, onPower: false, problem: nil), "waiting for power: \(json(waiting))")
let stale = KeepAwakePolicy.state(.off, held: true, battery: false, onPower: true, helper: .enabled)
check(stale.awake == false && stale.mode == "off", "Off never says awake, whatever the helper last answered")
let asked = KeepAwakePolicy.state(.always, held: false, battery: true, onPower: true, helper: .requiresApproval)
check(asked.awake == false && asked.problem == KeepAwake.approval, "Always, waiting for approval: \(json(asked))")

// MARK: - What the pane and the page offer

check(KeepAwakePolicy.offered(battery: true) == [.off, .always, .plugged], "a laptop: Off, Always, When Plugged In")
check(KeepAwakePolicy.offered(battery: false) == [.off, .always], "a desktop Mac: Off and Always")
check(KeepAwakePolicy.warns(.always, battery: true), "Always on a laptop: the heat and battery line")
check(!KeepAwakePolicy.warns(.always, battery: false), "…not on a Mac without a battery")
check(!KeepAwakePolicy.warns(.plugged, battery: true) && !KeepAwakePolicy.warns(.off, battery: true), "only Always")

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
