import Foundation
import ImageIO

/// Downloaded images live in `Documents/<folderName>/<gid-page>`, exactly where 3.x put them.
public struct GalleryFileStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let documents = GalleryFileStore(root: .documentsDirectory)

    public func folderURL(_ folderName: String) -> URL {
        root.appending(path: folderName, directoryHint: .isDirectory)
    }

    public func fileURL(folder folderName: String, fileName: String) -> URL {
        folderURL(folderName).appending(path: fileName, directoryHint: .notDirectory)
    }

    public func fileExists(folder folderName: String, fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(folder: folderName, fileName: fileName).path(percentEncoded: false))
    }

    public func write(_ data: Data, folder folderName: String, fileName: String) throws {
        let folder = folderURL(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: fileName, directoryHint: .notDirectory), options: .atomic)
    }

    public func removeFolder(_ folderName: String) {
        guard !folderName.isEmpty else { return }
        try? FileManager.default.removeItem(at: folderURL(folderName))
    }

    /// Bytes used by one gallery folder.
    public func size(ofFolder folderName: String) -> Int64 {
        let folder = folderURL(folderName)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Pixel size read from the image header, without decoding the image.
    public static func pixelSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)
    }

    public static func pixelSize(ofImageData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // EXIF orientations 5...8 are rotated by 90°.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
