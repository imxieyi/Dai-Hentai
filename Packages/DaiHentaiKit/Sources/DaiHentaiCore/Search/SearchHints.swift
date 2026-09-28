import Foundation

/// "從近期標題選取 / 從近期 Tag 選取": the most frequent words and tags among recently viewed galleries.
public enum SearchHints {
    static let ignoredWords: Set<String> = ["chinese", "translated", "中国翻訳", "language:chinese", "language:translated"]

    /// Title words, preferring the Japanese title when a gallery has one (as 3.x did).
    public static func recentTitleWords(from galleries: [GalleryInfo], limit: Int = 5) -> [String] {
        topWords(galleries.map { gallery in
            let japanese = gallery.jpnTitleWords
            return japanese.isEmpty ? gallery.engTitleWords : japanese
        }, limit: limit)
    }

    public static func recentTags(from galleries: [GalleryInfo], limit: Int = 5) -> [String] {
        topWords(galleries.map(\.tags), limit: limit)
    }

    /// Counts each word once per gallery, then ranks by frequency (ties keep first-seen order).
    static func topWords(_ wordLists: [[String]], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for words in wordLists {
            for word in Set(words.map { $0.lowercased() }) where !ignoredWords.contains(word) {
                counts[word, default: 0] += 1
                if firstSeen[word] == nil { firstSeen[word] = firstSeen.count }
            }
        }
        return counts.keys
            .sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]! }
            .prefix(limit)
            .map { $0 }
    }

    /// Keyword built from selected hints, skipping ones already contained (as 3.x did).
    public static func keyword(from hints: [String]) -> String {
        var keyword = ""
        for hint in hints.map(searchToken) where !keyword.lowercased().contains(hint.lowercased()) {
            keyword += keyword.isEmpty ? hint : " \(hint)"
        }
        return keyword
    }

    /// Site search syntax for a word or tag: `female:"big breasts$"` for namespaced tags,
    /// quotes for multi-word phrases, the word itself otherwise.
    public static func searchToken(_ word: String) -> String {
        let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[0].contains(" ") {
            return "\(parts[0]):\"\(parts[1])$\""
        }
        return word.contains(" ") ? "\"\(word)\"" : word
    }
}
