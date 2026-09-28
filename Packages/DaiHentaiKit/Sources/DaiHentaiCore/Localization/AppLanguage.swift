import Foundation

/// The language the app runs in, one of the bundle's localizations
/// (`zh-Hant`, the development language, `zh-Hans`, `en` or `ja`).
public enum AppLanguage {
    public static var current: String {
        Bundle.main.preferredLocalizations.first ?? "zh-Hant"
    }

    /// A locale for formatting names (languages, lists) in the app's language.
    public static var locale: Locale {
        Locale(identifier: current)
    }
}
