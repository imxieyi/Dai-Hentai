import DaiHentaiCore
import SwiftUI
import UIKit

/// 作品卡: the old 「O3O 這部作品有 N 頁呦」 alert grown into a sheet. All four actions fit at the
/// medium detent; the large detent adds the uploader and tags.
struct GallerySheet: View {
    let route: GalleryCardRoute

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [RelatedRoute] = []
    @State private var detent: PresentationDetent = .medium

    private var gallery: GalleryInfo { route.gallery }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GalleryHeader(gallery: gallery)
                    if route.showsReadActions {
                        actions
                    }
                    details
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationTitle(.cardTitle)
            .navigationDestination(for: RelatedRoute.self) { related in
                RelatedWordsView(gallery: gallery, preselected: related.word)
            }
        }
        .presentationDetents(route.showsReadActions ? [.medium, .large] : [.large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationSizing(.form)
        .onAppear {
            if !route.showsReadActions { detent = .large }
            if let word = route.relatedWord {
                path = [RelatedRoute(word: word.isEmpty ? nil : word)]
                detent = .large
            }
        }
        .onChange(of: path) { _, newPath in
            if !newPath.isEmpty { detent = .large }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        let stored = model.library.gallery(forKey: gallery.id)
        let lastPage = stored?.lastReadPage ?? 0
        let isDownloaded = stored?.isDownloaded ?? false
        let progress = model.downloads.progress(for: gallery.id)

        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                Kaomoji(text: "O3O", style: .headline.weight(.bold))
                    .foregroundStyle(Color.moeAccent)
                Text(gallery.fileCount > 0 ? LocalizedStringResource.cardPageCount(gallery.fileCount) : .cardPageCountUnknown)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if lastPage > 1 {
                HStack(spacing: 10) {
                    Button {
                        model.router.openReader(gallery, startPage: lastPage)
                    } label: {
                        Text(.commonResumeFromPage(lastPage)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("resumeButton")
                    Button {
                        model.router.openReader(gallery, startPage: 1)
                    } label: {
                        Text(.commonReadFromStart).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    model.router.openReader(gallery, startPage: 1)
                } label: {
                    Text(.commonReadNow).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("readNowButton")
            }

            Group {
                if let progress {
                    Button {} label: {
                        HStack {
                            Text(.commonDownloading)
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .allowsHitTesting(false)
                } else if isDownloaded {
                    Button {} label: {
                        Label(.commonDownloaded, systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                } else {
                    Button {
                        model.download(gallery)
                    } label: {
                        Text(.commonWantDownload).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("downloadButton")
                }
            }
            .animation(.smooth, value: progress == nil)

            Button {
                path.append(RelatedRoute(word: nil))
            } label: {
                Text(.commonSearchRelated).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("relatedButton")

            Button {
                dismiss()
            } label: {
                Text(.cardDismiss)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(.cardDismissAccessibility)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("dismissCardButton")
        }
        .controlSize(.large)
    }

    // MARK: - Details (large detent)

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            if !gallery.uploader.isEmpty || !gallery.posted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !gallery.uploader.isEmpty {
                        LabeledContent(.cardUploader, value: gallery.uploader)
                    }
                    if !gallery.posted.isEmpty {
                        LabeledContent(.cardPosted, value: gallery.posted)
                    }
                    if !gallery.fileSize.isEmpty {
                        LabeledContent(.cardSize, value: gallery.fileSize)
                    }
                }
                .font(.subheadline)
            }

            ForEach(gallery.groupedTags, id: \.namespace) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(TagTranslator.namespaceTitle(group.namespace))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(group.tags, id: \.self) { tag in
                            TagMenu(namespace: group.namespace, value: tag) { word in
                                path.append(RelatedRoute(word: word))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RelatedRoute: Hashable {
    /// A word to pick up front (from a tag chip's 「挑更多相關字詞…」).
    var word: String?
}

/// Cover, both titles, category, language and stars.
struct GalleryHeader: View {
    let gallery: GalleryInfo

    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 84

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: gallery.thumbURL)
                .frame(width: coverWidth, height: coverWidth * 1.4)
            VStack(alignment: .leading, spacing: 6) {
                Text(gallery.bestTitle)
                    .font(.headline)
                    .lineLimit(3)
                    .japaneseTypesetting(!gallery.titleJpn.isEmpty)
                    .textSelection(.enabled)
                if !gallery.titleJpn.isEmpty, !gallery.title.isEmpty {
                    Text(gallery.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    CategoryChip(categoryName: gallery.categoryName)
                    LanguagePill(tags: gallery.tags)
                }
                HStack(spacing: 8) {
                    RatingView(rating: gallery.rating, style: .stars)
                    Text(statLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statLine: String {
        [gallery.fileCount > 0 ? String(localized: .commonPageCount(gallery.fileCount)) : nil, gallery.posted.isEmpty ? nil : String(gallery.posted.prefix(10))]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// A tag chip that opens 用這個 Tag 搜尋 / 挑更多相關字詞… / 拷貝.
struct TagMenu: View {
    let namespace: String
    let value: String
    let pickMore: (String) -> Void

    @Environment(AppModel.self) private var model

    private var fullTag: String { namespace == "misc" ? value : "\(namespace):\(value)" }

    var body: some View {
        Menu {
            Button(.cardSearchTag, systemImage: "magnifyingglass") {
                model.search(keyword: SearchHints.searchToken(fullTag))
            }
            Button(.cardPickRelated, systemImage: "checklist") {
                pickMore(fullTag)
            }
            Button(.cardCopy, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = value
                model.toasts.show(.toastCopied, kaomoji: "O3Ob")
            }
        } label: {
            HStack(spacing: 4) {
                Text(value)
                if let translation = TagTranslator.shared.translate(fullTag), translation.lowercased() != value.lowercased() {
                    Text(translation)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
