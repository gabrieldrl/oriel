import UIKit
import CoreImage
import CoreVideo

/// The last look at each saved Mac's Desktop, for its card on the home screen (HomeScreen): the
/// picture on screen as a session on the whole Desktop ended (`StreamClient.keepDesktopPicture`),
/// never a window's: a session that ends on a window leaves the one before. One JPEG a Mac in Caches, by Mac ID
/// (16 Crockford characters, safe as a file name): the system may purge it, and the next session
/// takes it again. Main thread, but for the scaling and the file, which run on a queue of their own.
final class MacDesktops: ObservableObject {
    static let shared = MacDesktops()

    @Published private(set) var pictures: [String: UIImage] = [:]

    /// A card is at most a third of an iPad's width: more pixels than this only fill the disk.
    private static let maxWidth: CGFloat = 1400
    private static let context = CIContext()
    private let folder: URL
    private let io = DispatchQueue(label: "sill.mac-desktops", qos: .utility)

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDesktops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" {
            // Decoded when first drawn.
            if let picture = UIImage(contentsOfFile: file.path) { pictures[file.deletingPathExtension().lastPathComponent] = picture }
        }
    }

    /// The decoder's frame, scaled down and kept as `macID`'s.
    func keep(_ frame: CVPixelBuffer, for macID: String) {
        let url = file(macID)
        io.async {
            var image = CIImage(cvPixelBuffer: frame)
            let scale = min(1, Self.maxWidth / image.extent.width)
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            guard let cg = Self.context.createCGImage(image, from: image.extent) else { return }
            let picture = UIImage(cgImage: cg)
            guard let data = picture.jpegData(compressionQuality: 0.8) else { return }
            try? data.write(to: url, options: .atomic)
            DispatchQueue.main.async { self.pictures[macID] = picture }
        }
    }

    /// Forget: its picture goes with it.
    func forget(_ macID: String) {
        pictures[macID] = nil
        let url = file(macID)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    private func file(_ macID: String) -> URL { folder.appendingPathComponent("\(macID).jpg") }
}
