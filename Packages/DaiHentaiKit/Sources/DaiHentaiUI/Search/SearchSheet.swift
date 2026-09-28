import DaiHentaiCore
import SwiftUI

/// 搜尋: the old search screen's sections, in the old order.
struct SearchSheet: View {
    @Environment(AppModel.self) private var model
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
                Section("手動輸入關鍵字") {
                    TextField("輸入要搜尋的字串", text: $draft.keyword)
                        .submitLabel(.search)
                        .onSubmit(apply)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(selectedHints.isEmpty ? .primary : .secondary)
                        .accessibilityIdentifier("keywordField")
                }

                Section("只搜尋固定語言") {
                    Picker("只搜尋固定語言", selection: $draft.language) {
                        ForEach(LanguageFilter.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                hintSection("從近期標題選取", hints: titleHints)
                hintSection("從近期 Tag 選取", hints: tagHints)

                Section("評分要求") {
                    Picker("評分要求", selection: $draft.minimumRating) {
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
                        Text("作品類別")
                        Spacer()
                        Button("全選") { draft.categories = Set(GalleryCategory.allCases) }
                        Text("·").foregroundStyle(.tertiary)
                        Button("反選") { draft.categories = Set(GalleryCategory.allCases).subtracting(draft.categories) }
                    }
                    .textCase(nil)
                } footer: {
                    if draft.categories.isEmpty {
                        Text("至少要選一種類別呦 O3O")
                            .foregroundStyle(Color.moeAccent)
                    }
                }

                Section {
                    Button("全部重設", role: .destructive) {
                        withAnimation {
                            draft = .default
                            selectedHints = []
                        }
                    }
                    .disabled(draft.isDefault && selectedHints.isEmpty)
                }
            }
            .navigationTitle("搜尋")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好", action: apply)
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
            Text("將搜尋：")
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
        parts.append(effectiveKeyword.isEmpty ? "所有作品" : effectiveKeyword)
        if draft.language != .any { parts.append(draft.language.title) }
        if draft.minimumRating != .any { parts.append(draft.minimumRating.title) }
        if draft.categories.count != GalleryCategory.allCases.count {
            parts.append(draft.categories.isEmpty ? "沒有類別" : "\(draft.categories.count) 種類別")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func hintSection(_ title: String, hints: [String]) -> some View {
        Section {
            if hints.isEmpty {
                Text("看過的作品多一點, 這裡就會出現提示字呦")
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
            if hints.isEmpty == false, !selectedHints.isEmpty, title == "從近期 Tag 選取" {
                Text("有選提示字的時候, 會用提示字取代上面輸入的關鍵字")
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
        draft = model.library.searchFilter
        let recent = model.library.recentGalleries(limit: 30)
        titleHints = SearchHints.recentTitleWords(from: recent, limit: 8)
        tagHints = SearchHints.recentTags(from: recent, limit: 8)
    }

    private func apply() {
        guard !draft.categories.isEmpty else { return }
        var filter = draft
        filter.keyword = effectiveKeyword
        model.library.searchFilter = filter
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
                    Text(category.chineseName)
                        .font(.caption2)
                        .opacity(0.8)
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
        .accessibilityLabel("\(category.rawValue) \(category.chineseName)")
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
