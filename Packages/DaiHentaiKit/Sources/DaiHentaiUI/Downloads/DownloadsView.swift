import DaiHentaiCore
import SwiftData
import SwiftUI

struct DownloadsTab: View {
    var body: some View {
        TabStack(tab: .downloads) {
            DownloadsView()
        }
    }
}

/// 下載: running downloads, then everything downloaded (with a completeness check).
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<StoredGallery> { $0.isDownloaded }, sort: \StoredGallery.lastViewedAt, order: .reverse)
    private var downloads: [StoredGallery]
    @State private var pagesOnDisk: [String: Int] = [:]
    @State private var totalBytes: Int64?

    var body: some View {
        let active = downloads.filter { model.downloads.isDownloading($0.key) }
        let finished = downloads.filter { !model.downloads.isDownloading($0.key) }
        ScrollView {
            if downloads.isEmpty {
                KaomojiState(kaomoji: "O3O", title: .downloadsEmpty, message: .downloadsEmptyMessage)
                    .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    summary
                    if !active.isEmpty {
                        header(.commonDownloading)
                        grid(active)
                    }
                    if !finished.isEmpty {
                        header(.commonDownloaded)
                        grid(finished)
                    }
                    Text(.downloadsAwakeNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.sideMargin)
                        .padding(.top, 8)
                }
                .padding(.bottom, 16)
            }
        }
        .swipeActionsContainer()
        .background(Color.canvas)
        .navigationTitle(.tabDownloads)
        .task(id: downloads.map(\.key) + active.map(\.key)) {
            await measure()
        }
        .onChange(of: model.downloads.lastFinished) {
            Task { await measure() }
        }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Text(.downloadsCount(downloads.count))
            if let totalBytes {
                Text(verbatim: "·")
                Text(totalBytes.formatted(.byteCount(style: .file)))
                    .contentTransition(.numericText())
            } else {
                Text(.downloadsCalculatingSize)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, Metrics.sideMargin)
        .accessibilityElement(children: .combine)
    }

    private func header(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .fontDesign(.rounded)
            .padding(.horizontal, Metrics.sideMargin)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func grid(_ items: [StoredGallery]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Metrics.cardSpacing, alignment: .top)], spacing: Metrics.cardSpacing) {
            ForEach(items) { stored in
                VStack(spacing: 0) {
                    LibraryCard(stored: stored, extraBadge: badge(for: stored))
                    if let onDisk = pagesOnDisk[stored.key], stored.fileCount > 0, onDisk < stored.fileCount, !model.downloads.isDownloading(stored.key) {
                        IncompleteRow(onDisk: onDisk, total: stored.fileCount) {
                            model.downloads.resume(stored.info)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.sideMargin)
    }

    private func badge(for stored: StoredGallery) -> CardBadge {
        if let progress = model.downloads.progress(for: stored.key) { return .downloading(progress) }
        if let onDisk = pagesOnDisk[stored.key], stored.fileCount > 0, onDisk < stored.fileCount {
            // 「未完成」 is shown in the row under the card.
            return .none
        }
        return .downloaded
    }

    /// Counts pages on disk per gallery and the total size, off the main actor.
    private func measure() async {
        let items = downloads.map { (key: $0.key, folder: $0.info.folderName, gid: $0.gid) }
        let files = model.library.files
        let result = await Task.detached(priority: .utility) { () -> ([String: Int], Int64) in
            var counts: [String: Int] = [:]
            var bytes: Int64 = 0
            for item in items {
                let folder = files.folderURL(item.folder)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
                counts[item.key] = names.filter { $0.hasPrefix("\(item.gid)-") }.count
                bytes += files.size(ofFolder: item.folder)
            }
            return (counts, bytes)
        }.value
        pagesOnDisk = result.0
        withAnimation { totalBytes = result.1 }
    }
}

/// 「未完成 7/18 · 繼續下載」 under a download that stopped.
private struct IncompleteRow: View {
    let onDisk: Int
    let total: Int
    let resume: () -> Void

    var body: some View {
        HStack {
            Label(.downloadsIncomplete(onDisk, total), systemImage: "exclamationmark.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .monospacedDigit()
            Spacer()
            Button(.commonResumeDownload, systemImage: "arrow.down.circle", action: resume)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("resumeDownloadButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
