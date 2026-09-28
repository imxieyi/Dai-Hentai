import Foundation

/// English → Chinese dictionary for tags and title words (from EhTagTranslator), bundled as `translator.json`.
public final class TagTranslator: Sendable {
    public static let shared = TagTranslator()

    private let dictionary: [String: String]

    public init(dictionary: [String: String]) {
        self.dictionary = dictionary
    }

    private convenience init() {
        let url = Bundle.module.url(forResource: "translator", withExtension: "json")
        let data = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let dictionary = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        self.init(dictionary: dictionary)
    }

    /// Chinese for a word or tag. Namespaced tags (`female:glasses`) are looked up without the namespace.
    public func translate(_ word: String) -> String? {
        let key = word.lowercased()
        if let direct = dictionary[key] { return direct }
        guard let colon = key.firstIndex(of: ":") else { return nil }
        return dictionary[String(key[key.index(after: colon)...])]
    }

    /// `word (中文)` when a translation exists, otherwise `word`.
    public func annotated(_ word: String) -> String {
        guard let translation = translate(word), translation.lowercased() != word.lowercased() else { return word }
        return "\(word) (\(translation))"
    }

    /// Chinese names for tag namespaces.
    public static func namespaceTitle(_ namespace: String) -> String {
        switch namespace {
        case "language": "語言"
        case "parody": "原作"
        case "character": "角色"
        case "group": "社團"
        case "artist": "作者"
        case "cosplayer": "Coser"
        case "male": "男性"
        case "female": "女性"
        case "mixed": "混合"
        case "reclass": "重新分類"
        case "location": "場景"
        case "other": "其他"
        case "temp": "臨時"
        default: namespace
        }
    }
}
