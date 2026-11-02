import Foundation

/// What Oriel.app asks SillAwake, its launch daemon for Extended Use (docs/extended-use-plan.md),
/// over XPC: whether to hold the Mac awake for this connection. The daemon disables sleep while any
/// connection holds, and lets go of a connection's hold when the connection goes.
@objc public protocol SillAwakeXPC {
    /// `reply`: whether sleep is disabled now, and the error when the daemon could not do as asked.
    func hold(_ on: Bool, reply: @escaping (Bool, String?) -> Void)
}

/// The daemon's names, and who may talk to whom.
public enum SillAwakeService {
    /// Its launchd label and Mach service.
    public static let name = "com.gabrieldrl.sill.mac.awake"
    /// Its property list, in Oriel.app's Contents/Library/LaunchDaemons (SMAppService.daemon).
    public static let plist = "com.gabrieldrl.sill.mac.awake.plist"
    /// The team that signs both (CLAUDE.md, the fork's identifiers).
    public static let team = "JF8R4AVC2H"
    /// Only Oriel.app, signed by the team, may ask the daemon.
    public static let appRequirement =
        "anchor apple generic and identifier \"com.gabrieldrl.sill.mac\" and certificate leaf[subject.OU] = \"\(team)\""
    /// …and Oriel.app talks only to the daemon the team signed.
    public static let helperRequirement =
        "anchor apple generic and identifier \"\(name)\" and certificate leaf[subject.OU] = \"\(team)\""
}
