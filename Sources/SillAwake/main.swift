import Foundation
import SillAwakeXPC

// SillAwake: Oriel.app's launch daemon for Extended Use (docs/extended-use-plan.md). It runs as root,
// registered by the app with SMAppService.daemon and allowed by the user once in Login Items, because
// only root can stop the lid's sleep: `pmset -a disablesleep 1` (SleepDisabled), which also stops idle
// sleep. The displays still sleep as they would.
//
// While any connection holds, SleepDisabled is 1; when none does, 0. A connection's hold goes with the
// connection: Oriel quitting, crashing or killed lets the Mac sleep again. While it holds, a marker
// file says so; at the daemon's own start (every boot: RunAtLoad) a marker left behind, from a daemon
// that died holding, puts SleepDisabled back to 0. A SleepDisabled set by hand, with no marker, is
// never touched. Only Oriel.app signed by the team may connect (SillAwakeService.appRequirement).
//
// Everything runs on `queue`.

let queue = DispatchQueue(label: "SillAwake")
let marker = URL(fileURLWithPath: "/Library/Application Support/Sill/awake-held")
/// The connections holding now.
var holders = Set<ObjectIdentifier>()
/// What this daemon last set SleepDisabled to.
var disabled = false

/// `pmset -a disablesleep 1` or `0`; the error's words when it failed.
func setSleepDisabled(_ on: Bool) -> String? {
    let pmset = Process()
    pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmset.arguments = ["-a", "disablesleep", on ? "1" : "0"]
    let errors = Pipe()
    pmset.standardError = errors
    pmset.standardOutput = FileHandle.nullDevice
    do { try pmset.run() } catch { return "pmset did not run: \(error.localizedDescription)" }
    pmset.waitUntilExit()
    guard pmset.terminationStatus == 0 else {
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return "pmset failed (\(pmset.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    return nil
}

/// SleepDisabled as the holders want it, the marker with it. The error's words when pmset failed.
@discardableResult
func settle() -> String? {
    let want = !holders.isEmpty
    guard want != disabled else { return nil }
    if want {
        // The marker first: a daemon that dies between the two still puts it back at its next start.
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
    if let error = setSleepDisabled(want) {
        if want { try? FileManager.default.removeItem(at: marker) }
        print("SillAwake: \(error)")
        return error
    }
    disabled = want
    if !want { try? FileManager.default.removeItem(at: marker) }
    print(want ? "SillAwake: sleep disabled for Oriel." : "SillAwake: sleep enabled again.")
    return nil
}

/// One connection's side: its hold, by its id.
final class Holder: NSObject, SillAwakeXPC {
    let id: ObjectIdentifier
    init(_ id: ObjectIdentifier) { self.id = id }

    func hold(_ on: Bool, reply: @escaping (Bool, String?) -> Void) {
        queue.async { [id] in
            if on { holders.insert(id) } else { holders.remove(id) }
            let error = settle()
            reply(disabled, error)
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: SillAwakeXPC.self)
        connection.exportedObject = Holder(id)
        // Gone (Oriel quit, crashed or was killed): its hold with it.
        connection.invalidationHandler = {
            queue.async {
                holders.remove(id)
                settle()
            }
        }
        connection.resume()
        return true
    }
}

// A marker left behind: a daemon died holding. Sleep comes back before anything else.
queue.sync {
    if FileManager.default.fileExists(atPath: marker.path) {
        if let error = setSleepDisabled(false) { print("SillAwake: \(error)") } else { print("SillAwake: sleep enabled again after a hold left behind.") }
        try? FileManager.default.removeItem(at: marker)
    }
}

// Stopped by launchd (unregistered, the system shutting down): every hold goes first.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
term.setEventHandler {
    holders.removeAll()
    settle()
    exit(0)
}
term.resume()

let delegate = Listener()
let listener = NSXPCListener(machServiceName: SillAwakeService.name)
listener.setConnectionCodeSigningRequirement(SillAwakeService.appRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
