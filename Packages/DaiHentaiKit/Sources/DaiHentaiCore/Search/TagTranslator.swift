import Foundation
import Synchronization

/// English → Chinese dictionary for tags and title words (from EhTagTranslator), bundled as `translator.json`.
///
/// The dictionary is Simplified Chinese. The app shows it as is in Simplified Chinese, converts it
/// in Traditional Chinese, and hides it in other languages, where Chinese hints don't help.
public final class TagTranslator: Sendable {
    public enum Display: Sendable {
        case simplified
        case traditional
        case hidden

        /// What fits the language the app runs in.
        public static var forAppLanguage: Display {
            switch AppLanguage.current {
            case "zh-Hans": .simplified
            case "zh-Hant": .traditional
            default: .hidden
            }
        }
    }

    public static let shared = TagTranslator(display: .forAppLanguage)

    private let dictionary: [String: String]
    private let display: Display
    private let converted = Mutex<[String: String]>([:])

    public init(dictionary: [String: String], display: Display = .simplified) {
        self.dictionary = dictionary
        self.display = display
    }

    /// The bundled dictionary.
    public convenience init(display: Display) {
        let url = Bundle.module.url(forResource: "translator", withExtension: "json")
        let data = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let dictionary = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        self.init(dictionary: dictionary, display: display)
    }

    /// Chinese for a word or tag. Namespaced tags (`female:glasses`) are looked up without the namespace.
    public func translate(_ word: String) -> String? {
        guard display != .hidden, let simplified = lookUp(word) else { return nil }
        guard display == .traditional else { return simplified }
        if let cached = converted.withLock({ $0[simplified] }) { return cached }
        let traditional = simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
        converted.withLock { $0[simplified] = traditional }
        return traditional
    }

    private func lookUp(_ word: String) -> String? {
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

    /// Localized names for tag namespaces.
    public static func namespaceTitle(_ namespace: String) -> String {
        let title: LocalizedStringResource? = switch namespace {
        case "language": .namespaceLanguage
        case "parody": .namespaceParody
        case "character": .namespaceCharacter
        case "group": .namespaceGroup
        case "artist": .namespaceArtist
        case "cosplayer": .namespaceCosplayer
        case "male": .namespaceMale
        case "female": .namespaceFemale
        case "mixed": .namespaceMixed
        case "reclass": .namespaceReclass
        case "location": .namespaceLocation
        case "other": .namespaceOther
        case "temp": .namespaceTemp
        default: nil
        }
        return title.map { String(localized: $0) } ?? namespace
    }
}
