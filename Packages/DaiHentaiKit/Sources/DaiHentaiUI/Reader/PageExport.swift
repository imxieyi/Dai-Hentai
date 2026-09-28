import CoreTransferable
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Pages are stored as `{gid}-{page}` without an extension; sharing, QuickLook and Photos need a
/// properly named copy.
nonisolated enum PageExport {
    /// A temporary copy named `{title} - {page}.{ext}`.
    @concurrent
    static func exportedCopy(of fileURL: URL, title: String, page: Int) async -> URL? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier) else { return nil }
        let folder = URL.temporaryDirectory.appending(path: "Share", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeTitle = String(title.replacingOccurrences(of: "/", with: "-").prefix(60))
        let destination = folder.appending(path: "\(safeTitle) - \(page)").appendingPathExtension(for: type)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    enum SaveResult {
        case saved, denied, failed
    }

    /// 「儲存到照片」 (add-only access).
    static func saveToPhotos(_ fileURL: URL) async -> SaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }
}

/// A page handed to the share sheet, copied out lazily so the menu opens instantly.
nonisolated struct SharedPage: Transferable {
    let fileURL: URL
    let title: String
    let page: Int

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { shared in
            guard let copy = await PageExport.exportedCopy(of: shared.fileURL, title: shared.title, page: shared.page) else {
                throw CocoaError(.fileReadUnknown)
            }
            return SentTransferredFile(copy)
        }
    }
}
