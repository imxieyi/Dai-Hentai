import DaiHentaiCore
import SwiftUI

/// What the bottom-left corner of a card says.
enum CardBadge: Equatable {
    case none
    case downloading(Double)
    case downloaded
    case read(page: Int, total: Int)

    init(stored: StoredGallery?, downloadProgress: Double?) {
        if let downloadProgress {
            self = .downloading(downloadProgress)
        } else if stored?.isDownloaded == true {
            self = .downloaded
        } else if let stored, stored.lastReadPage > 0 {
            self = .read(page: stored.lastReadPage, total: stored.fileCount)
        } else {
            self = .none
        }
    }
}

/// A gallery row: cover on the left, then title, category, size, state and rating, in reading order.
struct GalleryCard: View {
    let gallery: GalleryInfo
    var badge: CardBadge = .none

    @Environment(\.zoomNamespace) private var zoomNamespace
    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: gallery.thumbURL)
                .frame(width: coverWidth, height: coverWidth * 1.4)
                .zoomSource(id: gallery.id, namespace: zoomNamespace)

            VStack(alignment: .leading, spacing: 6) {
                Text(gallery.bestTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .japaneseTypesetting(!gallery.titleJpn.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    CategoryChip(categoryName: gallery.categoryName)
                    LanguagePill(tags: gallery.tags)
                }

                Text(sizeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline) {
                    badgeView
                    Spacer(minLength: 8)
                    RatingView(rating: gallery.rating)
                }
            }
            .padding(.vertical, 2)
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(.rect(cornerRadius: Metrics.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("galleryCard")
    }

    private var sizeLine: String {
        [gallery.fileCount > 0 ? String(localized: .commonPageCount(gallery.fileCount)) : nil, gallery.fileSize.isEmpty ? nil : gallery.fileSize]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .none:
            EmptyView()
        case .downloading(let progress):
            Label {
                Text(verbatim: "DL: \(progress.formatted(.percent.precision(.fractionLength(0))))")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.moeAccent)
        case .downloaded:
            Label(.commonDownloaded, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case let .read(page, total):
            Label(total > 0 ? LocalizedStringResource.commonReadProgress(page, total) : .commonReadToPage(page), systemImage: "book.pages")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
