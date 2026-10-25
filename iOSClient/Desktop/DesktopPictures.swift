import UIKit

/// The last picture of each of a Mac's desktops, for its tile in the Displays sheet (DisplaysTray,
/// docs/desktops-plan.md): the Mac's kind 55, taken while that desktop showed. One JPEG a desktop in
/// Caches, named by the Mac's ID (16 Crockford characters, safe in a file name) and the space's: the
/// system may purge them, and the next session takes them again. A session without a saved Mac (a
/// development host) keeps them in memory alone. Forgetting a Mac removes its. Main thread, but for
/// the files, which go on a queue of their own.
final class DesktopPictures: ObservableObject {
    static let shared = DesktopPictures()

    @Published private(set) var pictures: [String: UIImage] = [:]

    private let folder: URL
    private let io = DispatchQueue(label: "sill.desktop-pictures", qos: .utility)

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopPictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" {
            if let picture = UIImage(contentsOfFile: file.path) { pictures[file.deletingPathExtension().lastPathComponent] = picture }
        }
    }

    /// Desktop `id`'s last picture on Mac `macID` (nil: a session without a saved Mac), if one was kept.
    func picture(_ id: UInt64, of macID: String?) -> UIImage? { pictures[Self.key(id, macID)] }

    /// The Mac's picture of desktop `id`, kept.
    func keep(_ jpeg: Data, desktop id: UInt64, of macID: String?) {
        guard let picture = UIImage(data: jpeg) else { return }
        let key = Self.key(id, macID)
        pictures[key] = picture
        guard macID != nil else { return }
        let url = folder.appendingPathComponent("\(key).jpg")
        io.async { try? jpeg.write(to: url, options: .atomic) }
    }

    /// Forget: a Mac's pictures go with it.
    func forget(_ macID: String) {
        let prefix = macID + "-"
        for key in pictures.keys where key.hasPrefix(prefix) { pictures[key] = nil }
        let folder = folder
        io.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func key(_ id: UInt64, _ macID: String?) -> String { "\(macID ?? "")-\(id)" }
}
