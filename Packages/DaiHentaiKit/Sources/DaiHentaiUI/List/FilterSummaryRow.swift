import DaiHentaiCore
import SwiftUI

/// The line above a list saying which filters are in effect (and for the site's list, which site).
/// Each filter chip has ✕.
struct FilterSummaryRow: View {
    /// `nil` for lists of the library on the device (歷史, 下載).
    let site: Site?
    @Binding var filter: SearchFilter
    let openSearch: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let site {
                    Label(String(site == .exHentai ? "ExHentai" : "E-Hentai"), systemImage: site == .exHentai ? "lock.shield" : "globe")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(site == .exHentai ? Color.moeAccent : .secondary)
                        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
                        .accessibilityLabel(site == .exHentai ? LocalizedStringResource.filterSiteEx : .filterSiteEh)
                }

                if filter.isDefault {
                    Button(action: openSearch) {
                        Label(.filterDefault, systemImage: "line.3.horizontal.decrease")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.moeAccent.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.moeAccent)
                    .accessibilityIdentifier("filterDefaultChip")
                } else {
                    if !filter.keyword.isEmpty {
                        chip(filter.keyword, symbol: "magnifyingglass") { filter.keyword = "" }
                    }
                    if filter.language != .any {
                        chip(String(localized: filter.language.title), symbol: "character.bubble") { filter.language = .any }
                    }
                    if filter.minimumRating != .any {
                        chip(String(localized: filter.minimumRating.title), symbol: "star") { filter.minimumRating = .any }
                    }
                    if filter.categories.count != GalleryCategory.allCases.count {
                        chip(categoriesTitle, symbol: "square.grid.2x2") { filter.categories = Set(GalleryCategory.allCases) }
                    }
                }
            }
            .padding(.horizontal, Metrics.sideMargin)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var categoriesTitle: String {
        let chosen = GalleryCategory.allCases.filter(filter.categories.contains)
        if chosen.count <= 2 { return chosen.map(\.rawValue).joined(separator: String(localized: .commonListSeparator)) }
        return String(localized: .filterCategoryCount(chosen.count))
    }

    private func chip(_ title: String, symbol: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: openSearch) {
                Label(title, systemImage: symbol)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Button(action: { withAnimation(.snappy) { clear() } }) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(.filterClear(title))
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.moeAccent)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.moeAccent.opacity(0.12), in: .capsule)
    }
}
