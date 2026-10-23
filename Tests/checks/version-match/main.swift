import Foundation

// VersionMatch against Sources/StreamProtocol compiled into this binary:
//   swiftc -O Sources/StreamProtocol/*.swift Tests/checks/version-match/main.swift -o check
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
func judge(_ mac: String?, _ device: String?) -> VersionMatch.Verdict { VersionMatch.judge(mac: mac, device: device) }

// The verdict.
check(judge("0.1.0", "0.1.0") == .same, "the same")
check(judge("0.1", "0.1.0") == .same, "trailing zeros")
check(judge("v0.1.0", "0.1") == .same, "a tag's v")
check(judge("0.1.0-beta", "0.1.0") == .same, "a suffix ignored")
check(judge("0.2.0", "0.1.0") == .updateDevice, "the device older")
check(judge("0.1.0", "0.2.0") == .updateMac, "the Mac older")
check(judge("0.1.1", "0.1.0") == .updateDevice, "a patch apart, the device older")
check(judge("0.1.0", "0.1.1") == .updateMac, "a patch apart, the Mac older")
check(judge("0.10", "0.9") == .updateDevice, "numbers, not text")
check(judge("1.0", "0.9.9") == .updateDevice, "a major apart")
check(judge(nil, "0.1.0") == .unknown, "no Mac version (SillHost)")
check(judge("0.1.0", nil) == .unknown, "no device version")
check(judge(nil, nil) == .unknown, "neither")
check(judge("dev", "0.1.0") == .unknown, "an unbundled Mac app's dev")
check(judge("0.1.0", "") == .unknown, "empty")

// The device's notice.
func notice(_ mac: String?, _ device: String?, _ name: String = "Mac mini", _ word: String = "iPad") -> String? {
    VersionMatch.deviceNotice(mac: mac, device: device, macName: name, deviceWord: word)
}
check(notice("0.2.0", "0.1.0") == "Update Oriel on this iPad: Mac mini has 0.2.", "device older: \(notice("0.2.0", "0.1.0") ?? "nil")")
check(notice("0.1.0", "0.2.0") == "Update Oriel on Mac mini: this iPad has 0.2.", "Mac older: \(notice("0.1.0", "0.2.0") ?? "nil")")
check(notice("0.1.0", "1.2.3", "Mac mini", "iPhone") == "Update Oriel on Mac mini: this iPhone has 1.2.3.", "an iPhone, three parts")
check(notice("0.2", "0.1", "") == "Update Oriel on this iPad: the Mac has 0.2.", "no Mac name yet")
check(notice("0.1.0", "0.1") == nil, "the same: no notice")
check(notice(nil, "0.1") == nil, "unknown: no notice")

// The Mac's line.
check(VersionMatch.macLine(mac: "0.2.0", device: "0.1.0") == "Update Oriel on it to 0.2", "device older on the Mac")
check(VersionMatch.macLine(mac: "0.1.0", device: "0.2.0") == "Has Oriel 0.2: update this Mac", "Mac older on the Mac")
check(VersionMatch.macLine(mac: "0.1.0", device: "v0.1") == nil, "the same: no line")
check(VersionMatch.macLine(mac: "0.1.0", device: nil) == nil, "an old device's hello without a version: no line")

print(failures == 0 ? "version-match: all \(checks) checks passed" : "version-match: \(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
