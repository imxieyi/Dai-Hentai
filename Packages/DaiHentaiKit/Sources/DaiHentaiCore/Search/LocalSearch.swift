import Foundation

extension SearchFilter {
    /// Whether a gallery already in the library (歷史, 下載) passes this filter, the way the site's search
    /// would treat it: every keyword term, the minimum rating, the language and the categories.
    public func matches(_ gallery: GalleryInfo) -> Bool {
        if categories.count != GalleryCategory.allCases.count {
            guard let category = gallery.category, categories.contains(category) else { return false }
        }
        if let stars = minimumRating.siteValue, gallery.rating < Double(stars) { return false }
        let tags = gallery.tags.map { $0.lowercased() }
        switch language {
        case .any:
            break
        case .chineseOnly:
            if !tags.contains("language:chinese") { return false }
        case .originalOnly:
            if tags.contains("language:translated") || tags.contains("language:rewrite") { return false }
        }
        return KeywordQuery(keyword).matches(titles: [gallery.title.lowercased(), gallery.titleJpn.lowercased()], tags: tags)
    }
}

/// The parts of the site's search syntax that make sense for a local list. Words and "quoted phrases"
/// match a title or a tag, `namespace:value` (or a short form like `f:value`) matches a tag, a trailing
/// `$` asks for the whole tag, and a leading `-` excludes. Every term has to hold.
struct KeywordQuery {
    struct Term: Equatable {
        var text: String
        var namespace: String?
        var isExact = false
        var isExcluded = false
    }

    let terms: [Term]

    init(_ keyword: String) {
        terms = Self.tokens(in: keyword.lowercased()).compactMap(Self.term)
    }

    func matches(titles: [String], tags: [String]) -> Bool {
        terms.allSatisfy { term in
            Self.matches(term, titles: titles, tags: tags) != term.isExcluded
        }
    }

    private static func matches(_ term: Term, titles: [String], tags: [String]) -> Bool {
        if let namespace = term.namespace {
            let wanted = "\(namespace):\(term.text)"
            return tags.contains { tag in
                // Tags saved without a namespace (by old versions) compare by value.
                let candidate = tag.contains(":") ? wanted : term.text
                return term.isExact ? tag == candidate : tag.hasPrefix(candidate)
            }
        }
        if term.isExact {
            return tags.contains { value(of: $0) == term.text }
        }
        return titles.contains { $0.contains(term.text) } || tags.contains { $0.contains(term.text) }
    }

    private static func value(of tag: String) -> String {
        tag.split(separator: ":", maxSplits: 1).last.map(String.init) ?? tag
    }

    /// Splits on spaces outside quotes and drops the quotes: `female:"big breasts$"` is one token.
    static func tokens(in keyword: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        for character in keyword {
            if character == "\"" {
                isQuoted.toggle()
            } else if character.isWhitespace, !isQuoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func term(_ token: String) -> Term? {
        var text = Substring(token)
        let isExcluded = text.count > 1 && text.hasPrefix("-")
        if isExcluded { text = text.dropFirst() }
        let isExact = text.hasSuffix("$")
        if isExact { text = text.dropLast() }
        var namespace: String?
        if let colon = text.firstIndex(of: ":"), let known = namespaces[String(text[..<colon])] {
            namespace = known
            text = text[text.index(after: colon)...]
        }
        guard !text.isEmpty else { return nil }
        return Term(text: String(text), namespace: namespace, isExact: isExact, isExcluded: isExcluded)
    }

    /// The site's tag namespaces and the short forms its search accepts.
    static let namespaces: [String: String] = {
        let full = ["language", "parody", "character", "group", "artist", "cosplayer", "male", "female", "mixed", "other", "reclass", "temp"]
        let short = ["l": "language", "lang": "language", "p": "parody", "series": "parody", "c": "character", "char": "character",
                     "g": "group", "circle": "group", "a": "artist", "cos": "cosplayer", "m": "male", "f": "female", "x": "mixed", "o": "other", "r": "reclass"]
        return Dictionary(uniqueKeysWithValues: full.map { ($0, $0) }).merging(short) { first, _ in first }
    }()
}
