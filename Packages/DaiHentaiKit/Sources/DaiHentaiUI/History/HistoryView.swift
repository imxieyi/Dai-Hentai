import DaiHentaiCore
import SwiftData
import SwiftUI

struct HistoryTab: View {
    var body: some View {
        TabStack(tab: .history) {
            HistoryView()
        }
    }
}

/// 歷史: galleries opened but not downloaded, newest first, grouped by day.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<StoredGallery> { !$0.isDownloaded }, sort: \StoredGallery.lastViewedAt, order: .reverse)
    private var histories: [StoredGallery]
    @State private var searchText = ""
    @State private var isConfirmingClear = false
    @State private var clearProgress: (done: Int, total: Int)?

    var body: some View {
        let filtered = filteredHistories
        ScrollView {
            if histories.isEmpty {
                KaomojiState(kaomoji: "O3O", title: .historyEmpty)
                    .padding(.top, 80)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing, pinnedViews: []) {
                    if searchText.isEmpty, !shelf.isEmpty {
                        ContinueShelf(galleries: shelf)
                    }
                    ForEach(sections(filtered), id: \.day) { section in
                        Text(section.day.title)
                            .font(.title3.weight(.bold))
                            .fontDesign(.rounded)
                            .padding(.horizontal, Metrics.sideMargin)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Metrics.cardSpacing, alignment: .top)], spacing: Metrics.cardSpacing) {
                            ForEach(section.items) { stored in
                                LibraryCard(stored: stored)
                            }
                        }
                        .padding(.horizontal, Metrics.sideMargin)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .swipeActionsContainer()
        .background(Color.canvas)
        .navigationTitle(.tabHistory)
        .searchable(text: $searchText, prompt: Text(.historySearchPrompt))
        .toolbar {
            if !histories.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(.commonClearHistory, systemImage: "trash") { isConfirmingClear = true }
                        .accessibilityIdentifier("clearHistoryButton")
                }
            }
        }
        .alert(Text(verbatim: "O3O"), isPresented: $isConfirmingClear) {
            Button(.commonOkayHappy, role: .destructive) { clearAll() }
            Button(.commonNotNow, role: .cancel) {}
        } message: {
            Text(.commonConfirmClearHistory)
        }
        .overlay {
            if let clearProgress {
                GlassHUD(title: .commonDeletingProgress(clearProgress.done, clearProgress.total), progress: clearProgress.total == 0 ? 1 : Double(clearProgress.done) / Double(clearProgress.total))
            }
        }
    }

    private var filteredHistories: [StoredGallery] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return histories }
        return histories.filter { stored in
            stored.title.lowercased().contains(query) || stored.titleJpn.lowercased().contains(query)
                || stored.tags.contains { $0.lowercased().contains(query) }
        }
    }

    /// Half-read galleries for the 繼續看 shelf.
    private var shelf: [StoredGallery] {
        Array(histories.filter { $0.lastReadPage > 1 && ($0.fileCount == 0 || $0.lastReadPage < $0.fileCount) }.prefix(10))
    }

    private enum Day: CaseIterable {
        case today, yesterday, thisWeek, earlier

        var title: LocalizedStringResource {
            switch self {
            case .today: .historyToday
            case .yesterday: .historyYesterday
            case .thisWeek: .historyThisWeek
            case .earlier: .historyEarlier
            }
        }
    }

    private struct DaySection {
        let day: Day
        let items: [StoredGallery]
    }

    private func sections(_ galleries: [StoredGallery]) -> [DaySection] {
        let calendar = Calendar.current
        let now = Date.now
        var groups: [Day: [StoredGallery]] = [:]
        for gallery in galleries {
            let day: Day
            if calendar.isDateInToday(gallery.lastViewedAt) {
                day = .today
            } else if calendar.isDateInYesterday(gallery.lastViewedAt) {
                day = .yesterday
            } else if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(gallery.lastViewedAt) || now.timeIntervalSince(gallery.lastViewedAt) < 7 * 86_400 {
                day = .thisWeek
            } else {
                day = .earlier
            }
            groups[day, default: []].append(gallery)
        }
        return Day.allCases.compactMap { day in groups[day].map { DaySection(day: day, items: $0) } }
    }

    private func clearAll() {
        clearProgress = (0, histories.count)
        Task {
            await model.library.deleteAllHistory { done, total in
                clearProgress = (done, total)
            }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { clearProgress = nil }
            model.toasts.show(.commonHistoryCleared, kaomoji: "O3Ob")
        }
    }
}

/// A card for a gallery already in the library (歷史 / 下載): tap reads.
struct LibraryCard: View {
    let stored: StoredGallery
    var extraBadge: CardBadge?

    @Environment(AppModel.self) private var model
    @State private var isConfirmingDelete = false

    var body: some View {
        let gallery = stored.info
        Button {
            model.router.openReader(gallery)
        } label: {
            GalleryCard(gallery: gallery, badge: extraBadge ?? CardBadge(stored: stored, downloadProgress: model.downloads.progress(for: gallery.id)))
        }
        .buttonStyle(.plain)
        .contextMenu { GalleryContextMenu(gallery: gallery, showsDelete: true) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(stored.isDownloaded ? LocalizedStringResource.commonDelete : .swipeDeleteRecord, systemImage: "trash", role: .destructive) {
                if stored.isDownloaded {
                    isConfirmingDelete = true
                } else {
                    withAnimation { model.delete(gallery) }
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !stored.isDownloaded {
                Button(.commonDownload, systemImage: "arrow.down.circle") { model.download(gallery) }
                    .tint(.moeAccent)
            }
        }
        .alert(Text(verbatim: "O3O"), isPresented: $isConfirmingDelete) {
            Button(.commonOkayHappy, role: .destructive) { withAnimation { model.delete(gallery) } }
            Button(.commonNotNow, role: .cancel) {}
        } message: {
            Text(.commonConfirmDeleteGallery)
        }
    }
}

/// 繼續看: half-read galleries, one tap back to the saved page.
private struct ContinueShelf: View {
    let galleries: [StoredGallery]

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.accessoryResume)
                .font(.title3.weight(.bold))
                .fontDesign(.rounded)
                .padding(.horizontal, Metrics.sideMargin)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(galleries) { stored in
                        let gallery = stored.info
                        Button {
                            model.router.openReader(gallery, startPage: stored.lastReadPage)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(gallery: gallery)
                                    .frame(width: 110, height: 154)
                                    .overlay(alignment: .bottom) {
                                        ProgressView(value: Double(stored.lastReadPage), total: Double(max(stored.fileCount, stored.lastReadPage)))
                                            .tint(.moeAccent)
                                            .padding(8)
                                    }
                                Text(gallery.bestTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .frame(width: 110, alignment: .leading)
                                    .japaneseTypesetting(!gallery.titleJpn.isEmpty)
                                Text(.commonReadProgress(stored.lastReadPage, stored.fileCount))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(Text(.historyResumeHint(stored.lastReadPage)))
                    }
                }
                .padding(.horizontal, Metrics.sideMargin)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 4)
    }
}
