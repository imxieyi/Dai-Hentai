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

/// 下載: the two jobs for the downloads shown (「下載缺少的圖片」, 「升級成原圖」), running downloads,
/// then everything downloaded, each with what it still lacks. The list's filters narrow all of it.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<StoredGallery> { $0.isDownloaded }, sort: \StoredGallery.lastViewedAt, order: .reverse)
    private var downloads: [StoredGallery]
    @State private var gaps: [String: DownloadGaps] = [:]
    @State private var totalBytes: Int64?
    @State private var isSearchPresented = false

    var body: some View {
        @Bindable var app = model
        let shown = shownDownloads
        let active = shown.filter { model.downloads.isDownloading($0.key) }
        let finished = shown.filter { !model.downloads.isDownloading($0.key) }
        let lackingImages = finished.filter { gaps[$0.key]?.isMissingImages == true }
        let lackingOriginals = finished.filter { gaps[$0.key]?.hasReducedPages == true }
        ScrollView {
            if downloads.isEmpty {
                KaomojiState(kaomoji: "O3O", title: .downloadsEmpty, message: .downloadsEmptyMessage)
                    .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    FilterSummaryRow(site: nil, filter: $app.downloadsFilter) { isSearchPresented = true }
                    summary
                    if model.downloads.batch != nil || !lackingImages.isEmpty || !lackingOriginals.isEmpty {
                        BatchPanel(
                            missing: BatchPanel.Job(galleries: lackingImages.map(\.info), pages: lackingImages.reduce(0) { $0 + (gaps[$1.key]?.missingPageCount ?? 0) }),
                            originals: BatchPanel.Job(galleries: lackingOriginals.map(\.info), pages: lackingOriginals.reduce(0) { $0 + (gaps[$1.key]?.reducedPageCount ?? 0) })
                        )
                    }
                    if !active.isEmpty {
                        header(.commonDownloading)
                        grid(active)
                    }
                    if !finished.isEmpty {
                        header(.commonDownloaded)
                        grid(finished)
                    }
                    if shown.isEmpty {
                        NoMatchesState(filter: $app.downloadsFilter) { isSearchPresented = true }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
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
        .filterSearch($app.downloadsFilter, isPresented: $isSearchPresented, isAvailable: !downloads.isEmpty, buttonIdentifier: "downloadsSearchButton") {
            downloads.prefix(30).map(\.info)
        }
        .task(id: downloads.map(\.key) + downloads.filter { model.downloads.isDownloading($0.key) }.map(\.key)) {
            await measure()
        }
        .onChange(of: model.downloads.lastFinished) {
            Task { await measure() }
        }
    }

    private var shownDownloads: [StoredGallery] {
        let filter = model.downloadsFilter
        guard !filter.isDefault else { return downloads }
        return downloads.filter { filter.matches($0.info) }
    }

    /// Every download's count and size, whatever the filters.
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
                    if let gaps = gaps[stored.key], !gaps.isEmpty, !model.downloads.isDownloading(stored.key) {
                        GapsRow(gaps: gaps)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.sideMargin)
    }

    private func badge(for stored: StoredGallery) -> CardBadge {
        if let progress = model.downloads.progress(for: stored.key) { return .downloading(progress) }
        if gaps[stored.key]?.isMissingPages == true {
            // 「未完成」 is shown in the row under the card.
            return .none
        }
        return .downloaded
    }

    /// Checks each download's folder (pages, originals, cover) and adds up the size, off the main actor.
    private func measure() async {
        let items = downloads.map { (key: $0.key, info: $0.info) }
        let files = model.library.files
        let result = await Task.detached(priority: .utility) { () -> ([String: DownloadGaps], Int64) in
            var gaps: [String: DownloadGaps] = [:]
            var bytes: Int64 = 0
            for item in items {
                let folder = item.info.folderName
                gaps[item.key] = DownloadGaps(info: item.info, contents: files.contents(ofFolder: folder, gid: item.info.gid))
                bytes += files.size(ofFolder: folder)
            }
            return (gaps, bytes)
        }.value
        gaps = result.0
        withAnimation { totalBytes = result.1 }
    }
}

/// 「下載缺少的圖片」 and 「升級成原圖」 for every download at once, at the top so a long list doesn't
/// bury them. They run one gallery at a time; while one runs, it shows its progress and 停止 instead.
private struct BatchPanel: View {
    struct Job {
        var galleries: [GalleryInfo]
        var pages: Int
    }

    let missing: Job
    let originals: Job

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let batch = model.downloads.batch {
                running(batch)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Metrics.cardSpacing) { buttons }
                    VStack(spacing: 8) { buttons }
                }
            }
        }
        .padding(.horizontal, Metrics.sideMargin)
    }

    @ViewBuilder
    private var buttons: some View {
        if !missing.galleries.isEmpty {
            button(.commonDownloadMissingImages, systemImage: "arrow.down.circle", job: missing, identifier: "downloadMissingButton") {
                model.downloads.startBatch(.missing, galleries: missing.galleries)
            }
        }
        if !originals.galleries.isEmpty {
            button(.commonUpgradeToOriginals, systemImage: "photo.badge.arrow.down", job: originals, identifier: "upgradeOriginalsButton") {
                model.downloads.startBatch(.originals, galleries: originals.galleries)
            }
        }
    }

    private func button(_ title: LocalizedStringResource, systemImage: String, job: Job, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(count(job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: systemImage)
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(.moeAccent)
        .accessibilityIdentifier(identifier)
    }

    /// 「3 部 · 25 頁」, or just the galleries when only covers are missing.
    private func count(_ job: Job) -> String {
        let galleries = String(localized: .downloadsGalleryCount(job.galleries.count))
        return job.pages > 0 ? "\(galleries) · \(String(localized: .downloadsPageCount(job.pages)))" : galleries
    }

    private func running(_ batch: DownloadCenter.Batch) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(batch.work == .originals ? .downloadsUpgradingToOriginals(min(batch.done + 1, batch.total), batch.total) : .downloadsDownloadingMissingImages(min(batch.done + 1, batch.total), batch.total))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let current = batch.current {
                    Text(current.bestTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: model.downloads.batchProgress)
                    .tint(.moeAccent)
            }
            Button(.commonStop, systemImage: "stop.fill") {
                model.downloads.stopBatch()
            }
            .labelStyle(.titleAndIcon)
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("stopBatchButton")
        }
        .padding(14)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("batchProgress")
    }
}

/// What a download still lacks, under its card: 「未完成 7/18」, 「缺少封面」 (3.x didn't save covers),
/// 「原圖 3/18」 (pages that aren't the originals: online reading, 3.x, or originals the site refused).
private struct GapsRow: View {
    let gaps: DownloadGaps

    private var text: String {
        var parts: [LocalizedStringResource] = []
        if gaps.isMissingPages { parts.append(.downloadsIncomplete(gaps.pagesOnDisk, gaps.pageCount)) }
        if gaps.isMissingCover { parts.append(.downloadsMissingCover) }
        if gaps.hasReducedPages { parts.append(.downloadsOriginals(gaps.originalPages, gaps.pagesOnDisk)) }
        return parts.map { String(localized: $0) }.joined(separator: " · ")
    }

    private var symbol: String {
        if gaps.isMissingPages { "exclamationmark.circle" } else if gaps.isMissingCover { "photo.badge.exclamationmark" } else { "square.resize.up" }
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(gaps.isMissingImages ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .accessibilityIdentifier("downloadGaps")
    }
}
