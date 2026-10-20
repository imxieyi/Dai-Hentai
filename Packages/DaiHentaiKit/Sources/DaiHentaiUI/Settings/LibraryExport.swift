import CoreTransferable
import DaiHentaiCore
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「匯出資料庫」: the library file handed to the share sheet, written once a destination is picked so the
/// sheet opens instantly.
nonisolated struct ExportedLibrary: Transferable {
    let container: ModelContainer

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { library in
            let folder = URL.temporaryDirectory.appending(path: "LibraryExport", directoryHint: .isDirectory)
            // Only the latest export is kept.
            try? FileManager.default.removeItem(at: folder)
            return SentTransferredFile(try await LibraryExporter(modelContainer: library.container).export(to: folder))
        }
    }
}

@MainActor extension ExportedLibrary {
    /// The share sheet's header. A symbol `Image` comes out blank there, so it gets a bitmap of one.
    static var preview: SharePreview<Image, Never> {
        SharePreview(String(localized: .settingsLibraryFile), image: icon)
    }

    private static let icon: Image = {
        let name = "books.vertical.fill"
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 96))?
            .withTintColor(UIColor(Color.moeAccent), renderingMode: .alwaysOriginal)
        else { return Image(systemName: name) }
        return Image(uiImage: UIGraphicsImageRenderer(size: symbol.size).image { _ in symbol.draw(at: .zero) })
    }()
}
