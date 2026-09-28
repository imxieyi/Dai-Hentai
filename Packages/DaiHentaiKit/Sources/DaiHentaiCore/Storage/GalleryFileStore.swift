import CryptoKit
import Foundation
import ImageIO

/// Downloaded images live in `Documents/<folderName>/<gid-page>`, exactly where 3.x put them.
/// 4.0 also keeps the cover of a downloaded gallery there, as `cover`.
///
/// A page that is the site's original file (not the resampled copy online reading shows) carries an
/// extended attribute saying so. Pages are always written atomically, as a new file, so a page that is
/// written again loses the mark until it is checked again.
public struct GalleryFileStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let documents = GalleryFileStore(root: .documentsDirectory)

    /// File name of a downloaded gallery's cover. Pages are `{gid}-{page}`, so it can't collide.
    public static let coverFileName = "cover"

    public func folderURL(_ folderName: String) -> URL {
        root.appending(path: folderName, directoryHint: .isDirectory)
    }

    public func fileURL(folder folderName: String, fileName: String) -> URL {
        folderURL(folderName).appending(path: fileName, directoryHint: .notDirectory)
    }

    public func coverURL(folder folderName: String) -> URL {
        fileURL(folder: folderName, fileName: Self.coverFileName)
    }

    public func fileExists(folder folderName: String, fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(folder: folderName, fileName: fileName).path(percentEncoded: false))
    }

    /// Writes a file, marking it as the original when `isOriginal` (see `isOriginal(_:imageKey:)`).
    public func write(_ data: Data, folder folderName: String, fileName: String, isOriginal: Bool = false) throws {
        let folder = folderURL(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: fileName, directoryHint: .notDirectory), options: .atomic)
        if isOriginal { markOriginal(folder: folderName, fileName: fileName) }
    }

    /// What a gallery folder holds, from one directory listing.
    public struct FolderContents: Equatable, Sendable {
        /// Pages (`{gid}-{page}`) on disk.
        public var pages = 0
        /// Pages on disk that are marked as the original.
        public var originals = 0
        public var hasCover = false
    }

    public func contents(ofFolder folderName: String, gid: String) -> FolderContents {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL(folderName).path(percentEncoded: false))) ?? []
        let pages = names.filter { $0.hasPrefix("\(gid)-") }
        return FolderContents(
            pages: pages.count,
            originals: pages.count { isMarkedOriginal(folder: folderName, fileName: $0) },
            hasCover: names.contains(Self.coverFileName)
        )
    }

    // MARK: - Originals

    /// Name of the extended attribute on page files that are the original. Only its presence matters.
    static let originalAttribute = "tw.daidouji.original"

    /// Whether image bytes are the original file of an image page: its key is the start of the file's SHA-1.
    public static func isOriginal(_ data: Data, imageKey: String) -> Bool {
        !imageKey.isEmpty && sha1(data).hasPrefix(imageKey.lowercased())
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func isMarkedOriginal(folder folderName: String, fileName: String) -> Bool {
        getxattr(fileURL(folder: folderName, fileName: fileName).path(percentEncoded: false), Self.originalAttribute, nil, 0, 0, 0) >= 0
    }

    public func markOriginal(folder folderName: String, fileName: String) {
        let path = fileURL(folder: folderName, fileName: fileName).path(percentEncoded: false)
        let value: [UInt8] = [1]
        _ = setxattr(path, Self.originalAttribute, value, value.count, 0, 0)
    }

    /// Checks a page on disk against its image key and marks it when it is the original.
    public func verifyOriginal(folder folderName: String, fileName: String, imageKey: String) -> Bool {
        if isMarkedOriginal(folder: folderName, fileName: fileName) { return true }
        guard
            let data = try? Data(contentsOf: fileURL(folder: folderName, fileName: fileName), options: .mappedIfSafe),
            Self.isOriginal(data, imageKey: imageKey)
        else { return false }
        markOriginal(folder: folderName, fileName: fileName)
        return true
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
