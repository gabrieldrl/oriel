import Foundation

// Each display's settings on the device (docs/displays-plan.md, "Settings per display"), against
// iOSClient/DisplaySettingsMemory.swift and Sources/StreamProtocol compiled into this binary (build.sh).
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}

let displays = [ExtendedDisplay(id: 0x1234_5601, name: "Display 2", width: 1180, height: 760),
                ExtendedDisplay(id: 0x1234_5600, name: "Display 1", width: 1366, height: 1024)]
func settings(scale: Double = 1, fps: Int = 60, bitrate: Int = QualityPreset.balanced.rawValue) -> StreamSettings {
    StreamSettings(maxFPS: fps, bitrate: bitrate, captureScale: scale, prioritizeSpeed: false, virtualDisplay: false,
                   directWireless: nil)
}

// MARK: - Which memory a source uses (rules 1 and 2)

typealias M = DisplaySettingsMemory
check(M.key(.desktop, displays: displays, away: false) == "Primary", "the Mac's own display is Primary")
check(M.key(.display(0x1234_5601), displays: displays, away: false) == "display 305419777", "a display by its id")
check(M.key(.display(0x1234_5600), displays: displays, away: false) == "display 305419776", "the other by its own")
check(M.key(.display(0x1234_5601), displays: displays, away: true) == "display 305419777 · away", "away apart")
let renamed = displays.map { ExtendedDisplay(id: $0.id, name: "Display 9", width: $0.width, height: $0.height) }
check(M.key(.display(0x1234_5601), displays: renamed, away: false) == M.key(.display(0x1234_5601), displays: displays, away: false),
      "a display renumbered keeps its memory")
check(M.displayKey(0x1234_5601) == "display 305419777", "the key of an id")
check(M.key(.desktop, displays: [], away: true) == "Primary · away", "Primary away apart")
check(M.key(.display(7), displays: displays, away: false) == nil, "a display not listed yet: none")
check(M.key(.window(7), displays: displays, away: false) == nil, "a window: none")
check(M.key(.none, displays: displays, away: false) == nil, "nothing: none")
check(M.key(.desktop, displays: [], away: false) != M.key(.desktop, displays: [], away: true), "home and away differ")

// MARK: - A display shown (rules 3 and 4)

do {
    let shown = settings(scale: 2, fps: 120, bitrate: QualityPreset.pro.rawValue)
    let (send, keep) = M.arriving(nil, shown: shown)
    check(send == nil, "a display shown first sends nothing")
    check(keep == DisplaySettings(captureScale: 2, maxFPS: 120, bitrate: QualityPreset.pro.rawValue), "and keeps what the Mac shows: \(keep)")
}
do {
    let saved = DisplaySettings(captureScale: 2, maxFPS: 120, bitrate: QualityPreset.high.rawValue)
    let (send, keep) = M.arriving(saved, shown: settings())
    check(send == HostSettingsChange(maxFPS: 120, bitrate: QualityPreset.high.rawValue, captureScale: 2), "all three back: \(String(describing: send))")
    check(keep == saved, "its memory stays")
    check(send?.token == nil && send?.prioritizeSpeed == nil && send?.virtualDisplay == nil && send?.directWireless == nil,
          "nothing else in the change")
}
do {
    let saved = DisplaySettings(captureScale: 2, maxFPS: 60, bitrate: QualityPreset.balanced.rawValue)
    let (send, _) = M.arriving(saved, shown: settings())
    check(send == HostSettingsChange(captureScale: 2), "only what differs: the scale (\(String(describing: send)))")
    let (fps, _) = M.arriving(DisplaySettings(captureScale: 1, maxFPS: 120, bitrate: QualityPreset.balanced.rawValue), shown: settings())
    check(fps == HostSettingsChange(maxFPS: 120), "only the rate (\(String(describing: fps)))")
    let (rate, _) = M.arriving(DisplaySettings(captureScale: 1, maxFPS: 60, bitrate: QualityPreset.low.rawValue), shown: settings())
    check(rate == HostSettingsChange(bitrate: QualityPreset.low.rawValue), "only the quality (\(String(describing: rate)))")
    let (same, keep) = M.arriving(DisplaySettings(settings()), shown: settings())
    check(same == nil && keep == DisplaySettings(settings()), "the same as shown: nothing sent")
}
do {
    let custom = DisplaySettings(captureScale: 1.5, maxFPS: 90, bitrate: 12_000_000)
    let (send, keep) = M.arriving(custom, shown: settings())
    check(send == nil, "values the Mac does not offer are never asked for (\(String(describing: send)))")
    check(keep == custom, "and stay remembered")
    let (mixed, _) = M.arriving(DisplaySettings(captureScale: 2, maxFPS: 90, bitrate: 12_000_000), shown: settings())
    check(mixed == HostSettingsChange(captureScale: 2), "an offered one still goes (\(String(describing: mixed)))")
}

// MARK: - A pick (rule 5)

do {
    let shown = settings(scale: 1, fps: 60, bitrate: QualityPreset.balanced.rawValue)
    let first = M.recording(HostSettingsChange(captureScale: 2), into: nil, shown: shown)
    check(first == DisplaySettings(captureScale: 2, maxFPS: 60, bitrate: QualityPreset.balanced.rawValue), "a first pick starts from what is shown: \(first)")
    let second = M.recording(HostSettingsChange(maxFPS: 120), into: first, shown: settings(scale: 2, fps: 60, bitrate: QualityPreset.ultra.rawValue))
    check(second == DisplaySettings(captureScale: 2, maxFPS: 120, bitrate: QualityPreset.balanced.rawValue), "a pick changes only its field: \(second)")
    let third = M.recording(HostSettingsChange(bitrate: QualityPreset.pro.rawValue), into: second, shown: shown)
    check(third == DisplaySettings(captureScale: 2, maxFPS: 120, bitrate: QualityPreset.pro.rawValue), "the quality: \(third)")
    let other = M.recording(HostSettingsChange(prioritizeSpeed: true), into: third, shown: shown)
    check(other == third, "another setting changes nothing kept")
}

// MARK: - Two displays, one Mac: a round trip

do {
    var memory: [String: DisplaySettings] = [:]
    var mac = settings(scale: 1, fps: 60, bitrate: QualityPreset.balanced.rawValue)
    func show(_ source: StreamSource) {
        guard let key = M.key(source, displays: displays, away: false) else { return }
        let (send, keep) = M.arriving(memory[key], shown: mac)
        memory[key] = keep
        if let send { mac = send.applied(to: mac) }
    }
    func pick(_ change: HostSettingsChange, on source: StreamSource) {
        guard let key = M.key(source, displays: displays, away: false) else { return }
        memory[key] = M.recording(change, into: memory[key], shown: mac)
        mac = change.applied(to: mac)
    }
    show(.desktop)
    show(.display(0x1234_5600))
    pick(HostSettingsChange(captureScale: 2), on: .display(0x1234_5600))
    pick(HostSettingsChange(bitrate: QualityPreset.ultra.rawValue), on: .display(0x1234_5600))
    show(.desktop)
    check(mac == settings(), "Primary comes back as it was: \(mac)")
    show(.display(0x1234_5600))
    check(mac == settings(scale: 2, bitrate: QualityPreset.ultra.rawValue), "Display 1 comes back as it was left: \(mac)")
    show(.window(9))
    check(mac == settings(scale: 2, bitrate: QualityPreset.ultra.rawValue), "a window changes nothing")
    show(.display(0x1234_5601))
    check(mac == settings(scale: 2, bitrate: QualityPreset.ultra.rawValue), "a display shown first keeps what is on")
    show(.desktop)
    show(.display(0x1234_5601))
    check(mac == settings(scale: 2, bitrate: QualityPreset.ultra.rawValue), "and has it from then on")
}

// MARK: - The memory's JSON

do {
    let all = ["Primary": DisplaySettings(captureScale: 1, maxFPS: 60, bitrate: 15_000_000),
               "Display 1 · away": DisplaySettings(captureScale: 2, maxFPS: 120, bitrate: 4_000_000)]
    let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
    let data = try! sorted.encode(all)
    check(String(decoding: data, as: UTF8.self)
          == #"{"Display 1 · away":{"bitrate":4000000,"captureScale":2,"maxFPS":120},"Primary":{"bitrate":15000000,"captureScale":1,"maxFPS":60}}"#,
          "the JSON: \(String(decoding: data, as: UTF8.self))")
    check((try? JSONDecoder().decode([String: DisplaySettings].self, from: data)) == all, "read back")
}

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
