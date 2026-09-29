import DaiHentaiCore
import SwiftUI

/// 搜尋: the old search screen's sections, in the old order. Edits the list's filter, or 歷史's or 下載's.
struct SearchSheet: View {
    @Binding var filter: SearchFilter
    /// Galleries whose titles and tags are offered as hints: recently viewed ones for the list,
    /// the ones being filtered for 歷史 and 下載.
    let hintGalleries: [GalleryInfo]

    @Environment(\.dismiss) private var dismiss
    @State private var draft = SearchFilter.default
    @State private var selectedHints: [String] = []
    @State private var titleHints: [String] = []
    @State private var tagHints: [String] = []
    @State private var didLoad = false

    /// Picked hints replace the typed keyword, like 3.x.
    private var effectiveKeyword: String {
        selectedHints.isEmpty ? draft.keyword.trimmingCharacters(in: .whitespaces) : SearchHints.keyword(from: selectedHints)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(.searchKeywordSection) {
                    TextField(.searchKeywordPlaceholder, text: $draft.keyword)
                        .submitLabel(.search)
                        .onSubmit(apply)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(selectedHints.isEmpty ? .primary : .secondary)
                        .accessibilityIdentifier("keywordField")
                }

                Section(.searchLanguageSection) {
                    Picker(.searchLanguageSection, selection: $draft.language) {
                        ForEach(LanguageFilter.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                hintSection(.searchTitleHints, hints: titleHints)
                hintSection(.searchTagHints, hints: tagHints, explainsReplacement: true)

                Section(.searchRatingSection) {
                    Picker(.searchRatingSection, selection: $draft.minimumRating) {
                        ForEach(MinimumRating.allCases) { rating in
                            Text(rating.title).tag(rating)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(GalleryCategory.allCases) { category in
                            CategoryTile(category: category, isOn: draft.categories.contains(category)) {
                                if draft.categories.contains(category) {
                                    draft.categories.remove(category)
                                } else {
                                    draft.categories.insert(category)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text(.searchCategories)
                        Spacer()
                        Button(.searchSelectAll) { draft.categories = Set(GalleryCategory.allCases) }
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Button(.searchInvert) { draft.categories = Set(GalleryCategory.allCases).subtracting(draft.categories) }
                    }
                    .textCase(nil)
                } footer: {
                    if draft.categories.isEmpty {
                        Text(.searchNeedCategory)
                            .foregroundStyle(Color.moeAccent)
                    }
                }

                Section {
                    Button(.searchResetAll, role: .destructive) {
                        withAnimation {
                            draft = .default
                            selectedHints = []
                        }
                    }
                    .disabled(draft.isDefault && selectedHints.isEmpty)
                }
            }
            .navigationTitle(.commonSearch)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel, systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.commonOkay, action: apply)
                        .disabled(draft.categories.isEmpty)
                        .accessibilityIdentifier("searchConfirmButton")
                }
            }
            .safeAreaBar(edge: .bottom) {
                preview
            }
        }
        .onAppear(perform: load)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(.commonWillSearch)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(previewText)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .contentTransition(.opacity)
                .accessibilityIdentifier("searchPreview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var previewText: String {
        var parts: [String] = []
        parts.append(effectiveKeyword.isEmpty ? String(localized: .searchAllGalleries) : effectiveKeyword)
        if draft.language != .any { parts.append(String(localized: draft.language.title)) }
        if draft.minimumRating != .any { parts.append(String(localized: draft.minimumRating.title)) }
        if draft.categories.count != GalleryCategory.allCases.count {
            parts.append(String(localized: draft.categories.isEmpty ? .searchNoCategory : .filterCategoryCount(draft.categories.count)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func hintSection(_ title: LocalizedStringResource, hints: [String], explainsReplacement: Bool = false) -> some View {
        Section {
            if hints.isEmpty {
                Text(.searchHintsEmpty)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(hints, id: \.self) { hint in
                        ToggleChip(title: hint, subtitle: translation(for: hint), isOn: selectedHints.contains(hint)) {
                            if let index = selectedHints.firstIndex(of: hint) {
                                selectedHints.remove(at: index)
                            } else {
                                selectedHints.append(hint)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(title)
        } footer: {
            if explainsReplacement, !hints.isEmpty, !selectedHints.isEmpty {
                Text(.searchHintsReplace)
            }
        }
    }

    private func translation(for word: String) -> String? {
        guard let translated = TagTranslator.shared.translate(word), translated.lowercased() != word.lowercased() else { return nil }
        return translated
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        draft = filter
        titleHints = SearchHints.recentTitleWords(from: hintGalleries, limit: 8)
        tagHints = SearchHints.recentTags(from: hintGalleries, limit: 8)
    }

    private func apply() {
        guard !draft.categories.isEmpty else { return }
        var applied = draft
        applied.keyword = effectiveKeyword
        filter = applied
        dismiss()
    }
}

/// A category toggle in its legacy colour.
struct CategoryTile: View {
    let category: GalleryCategory
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? textColor : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(category.rawValue)
                        .font(.subheadline.weight(.semibold))
                    if let name = category.localizedName {
                        Text(name)
                            .font(.caption2)
                            .opacity(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? textColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(isOn ? category.swatch : Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                if !isOn {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(category.swatch.opacity(0.6), lineWidth: 1.5)
                }
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.spokenName)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }

    /// Dark text on the light legacy colours (Western, Artist CG, Misc, Asian Porn, Manga).
    private var textColor: Color {
        let (red, green, blue) = category.rgb
        let luminance = (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255
        return luminance > 0.6 ? .black : .white
    }
}
