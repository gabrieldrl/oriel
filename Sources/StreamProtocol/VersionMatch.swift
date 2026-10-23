import Foundation

/// Whether a Mac and a device run the same Oriel, and which one to update when they do not
/// (docs/version-match-plan.md): the Mac's version from its window list (`WindowList.hostVersion`),
/// the device's from its hello (`Hello.appVersion`). Both sides judge with it, so each says the same thing: the Mac's status card
/// under that device, the device's stream screen over the picture. Only shown, never acted on: a Mac
/// and a device of different versions still connect, and the compatibility floor (CLAUDE.md) keeps
/// them working. Pure, so it is checked on its own (Tests/checks/version-match).
///
/// The marketing versions are compared as SillVersion reads them ("0.1" is "0.1.0", a suffix such as
/// "-beta" ignored); builds are not. A side with no version, or one that does not read (SillHost and
/// Macs before 2026-09-25 send no `hostVersion`, an unbundled Mac app says "dev"), says nothing.
public enum VersionMatch {
    public enum Verdict: Equatable, Sendable {
        case same
        /// The Mac runs the older Oriel.
        case updateMac
        /// The device runs the older Oriel.
        case updateDevice
        /// A side's version is missing or does not read.
        case unknown
    }

    public static func judge(mac: String?, device: String?) -> Verdict {
        guard let mac = mac.flatMap({ SillVersion($0) }), let device = device.flatMap({ SillVersion($0) }) else {
            return .unknown
        }
        if mac == device { return .same }
        return mac < device ? .updateMac : .updateDevice
    }

    /// Over the device's picture: "Update Oriel on this iPad: Mac mini has 0.2." or "Update Oriel on
    /// Mac mini: this iPad has 0.2." Nil unless one side is older. `macName` empty reads "the Mac";
    /// `deviceWord` is "iPad" or "iPhone".
    public static func deviceNotice(mac: String?, device: String?, macName: String, deviceWord: String) -> String? {
        let name = macName.isEmpty ? "the Mac" : macName
        switch judge(mac: mac, device: device) {
        case .updateDevice: return "Update Oriel on this \(deviceWord): \(name) has \(shown(mac))."
        case .updateMac: return "Update Oriel on \(name): this \(deviceWord) has \(shown(device))."
        case .same, .unknown: return nil
        }
    }

    /// On the Mac's status card, under that device: "Update Oriel on it to 0.2" or "Has Oriel 0.2:
    /// update this Mac". Nil unless one side is older.
    public static func macLine(mac: String?, device: String?) -> String? {
        switch judge(mac: mac, device: device) {
        case .updateDevice: return "Update Oriel on it to \(shown(mac))"
        case .updateMac: return "Has Oriel \(shown(device)): update this Mac"
        case .same, .unknown: return nil
        }
    }

    /// A version as SillVersion writes it ("0.2", "1.2.3"); only called once `judge` has read it.
    private static func shown(_ text: String?) -> String {
        text.flatMap { SillVersion($0) }?.description ?? ""
    }
}
