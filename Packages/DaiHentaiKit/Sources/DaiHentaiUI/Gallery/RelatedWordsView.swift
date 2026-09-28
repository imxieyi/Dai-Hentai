import DaiHentaiCore
import SwiftUI

/// 相關字詞: pick words from the titles and tags; 好 searches for them in 列表.
struct RelatedWordsView: View {
    let gallery: GalleryInfo
    var preselected: String?

    @Environment(AppModel.self) private var model
    @State private var selected: [String] = []

    private var keyword: String { SearchHints.keyword(from: selected) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !gallery.engTitleWords.isEmpty {
                    section("英文名稱切碎", words: gallery.engTitleWords)
                }
                if !gallery.jpnTitleWords.isEmpty {
                    section("日文名稱切碎", words: gallery.jpnTitleWords, japanese: true)
                }
                if !gallery.tags.isEmpty {
                    section("Tags", words: gallery.tags)
                }
            }
            .padding(20)
        }
        .navigationTitle("相關字詞")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("將搜尋：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(keyword.isEmpty ? "還沒有選字呦" : keyword)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(keyword.isEmpty ? .secondary : .primary)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button("好") {
                    model.search(keyword: keyword)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("relatedConfirmButton")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            if let preselected, selected.isEmpty { selected = [preselected] }
        }
    }

    private func section(_ title: String, words: [String], japanese: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Array(Set(words)).sorted { words.firstIndex(of: $0)! < words.firstIndex(of: $1)! }, id: \.self) { word in
                    ToggleChip(title: word, subtitle: TagTranslator.shared.translate(word).flatMap { $0.lowercased() == word.lowercased() ? nil : $0 }, isOn: selected.contains(word)) {
                        if let index = selected.firstIndex(of: word) {
                            selected.remove(at: index)
                        } else {
                            selected.append(word)
                        }
                    }
                    .japaneseTypesetting(japanese)
                }
            }
        }
    }
}
