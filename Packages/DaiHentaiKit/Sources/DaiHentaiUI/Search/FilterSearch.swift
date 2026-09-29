import DaiHentaiCore
import SwiftUI

extension View {
    /// The list's search, for any filter: a 搜尋 button (badged with the refinements in effect) that opens
    /// the search sheet. `hints` gives the galleries whose titles and tags the sheet offers.
    func filterSearch(_ filter: Binding<SearchFilter>, isPresented: Binding<Bool>, isAvailable: Bool = true, buttonIdentifier: String, hints: @escaping () -> [GalleryInfo]) -> some View {
        modifier(FilterSearchModifier(filter: filter, isPresented: isPresented, isAvailable: isAvailable, buttonIdentifier: buttonIdentifier, hints: hints))
    }
}

private struct FilterSearchModifier: ViewModifier {
    @Binding var filter: SearchFilter
    @Binding var isPresented: Bool
    let isAvailable: Bool
    let buttonIdentifier: String
    let hints: () -> [GalleryInfo]

    @Namespace private var zoom

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isAvailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(.commonSearch, systemImage: "magnifyingglass") { isPresented = true }
                            .badge(filter.activeRefinementCount)
                            .accessibilityIdentifier(buttonIdentifier)
                    }
                    .matchedTransitionSource(id: "search", in: zoom)
                }
            }
            .sheet(isPresented: $isPresented) {
                SearchSheet(filter: $filter, hintGalleries: hints())
                    .navigationTransition(.zoom(sourceID: "search", in: zoom))
            }
    }
}

/// 「找不到相關作品呦」 with the ways out, when the filters leave nothing to show.
struct NoMatchesState: View {
    @Binding var filter: SearchFilter
    let changeFilters: () -> Void

    var body: some View {
        KaomojiState(kaomoji: "O3O", title: .listNoResults, message: filter.isDefault ? nil : .listNoResultsHint) {
            if !filter.isDefault {
                Button(.listChangeFilters, action: changeFilters)
                    .buttonStyle(.borderedProminent)
                Button(.listClearFilters) { withAnimation { filter = .default } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clearFiltersButton")
            }
        }
    }
}
