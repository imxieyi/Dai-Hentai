import DaiHentaiCore
import SwiftUI
import UIKit

extension Color {
    /// 萌粉, from the app icon's pink. 4.85:1 on white, 8.6:1 on black.
    static let moeAccent = Color(light: 0xD12F6A, dark: 0xFF7AA8)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let cardSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let placeholderFill = Color(uiColor: .tertiarySystemFill)
    static let star = Color.orange

    /// The provider runs wherever SwiftUI resolves colours (including its render thread), so it must not be main-actor isolated.
    nonisolated init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { @Sendable traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension GalleryCategory {
    /// The legacy colour users recognise, used for the dot and the tint.
    var swatch: Color {
        let (red, green, blue) = rgb
        return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// Readable text colour for the category name (≥ 4.5:1), keeping the category's hue.
    var ink: Color {
        switch self {
        case .doujinshi: Color(light: 0xD70015, dark: 0xFF3B3B)
        case .manga: Color(light: 0x9A5B00, dark: 0xFFBA3B)
        case .artistCG: Color(light: 0x7A6E00, dark: 0xEADC3B)
        case .gameCG: Color(light: 0x2A7A2A, dark: 0x3B9D3B)
        case .western: Color(light: 0x3F7A0E, dark: 0xA4FF4C)
        case .nonH: Color(light: 0x0870BD, dark: 0x4CB4FF)
        case .imageSet: Color(light: 0x3B3BFF, dark: 0x8C8CFF)
        case .cosplay: Color(light: 0x753B9F, dark: 0xC18AE6)
        case .asianPorn: Color(light: 0xA8329F, dark: 0xF3B0F3)
        case .misc: Color(light: 0x6E6E73, dark: 0xD4D4D4)
        }
    }

    var chineseName: String {
        switch self {
        case .doujinshi: "同人誌"
        case .manga: "漫畫"
        case .artistCG: "畫師 CG"
        case .gameCG: "遊戲 CG"
        case .western: "西方"
        case .nonH: "非 H"
        case .imageSet: "圖集"
        case .cosplay: "Cosplay"
        case .asianPorn: "亞洲"
        case .misc: "雜項"
        }
    }
}

enum Metrics {
    static let cardRadius: CGFloat = 22
    static let coverRadius: CGFloat = 12
    static let cardPadding: CGFloat = 10
    static let cardSpacing: CGFloat = 12
    static let sideMargin: CGFloat = 16
}

/// Kaomoji are decoration: shown in rounded type, never read out by VoiceOver.
struct Kaomoji: View {
    let text: String
    var style: Font = .body

    var body: some View {
        Text(text)
            .font(style)
            .fontDesign(.rounded)
            .accessibilityHidden(true)
    }
}

extension String {
    /// The string without kaomoji, for VoiceOver labels ("好 O3Ob" → "好").
    var spoken: String {
        var result = self
        for kaomoji in ["O3Ob", "O3O", "OwO\"", "OwO", "O口O", "o.o", "=w=", ">w<"] {
            result = result.replacingOccurrences(of: kaomoji, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "!?"))))
    }
}

extension View {
    /// Card surface: opaque content, never glass.
    func cardSurface() -> some View {
        modifier(CardSurfaceModifier())
    }

    /// Japanese titles use Japanese glyph forms for kanji.
    @ViewBuilder
    func japaneseTypesetting(_ isJapanese: Bool) -> some View {
        if isJapanese {
            typesettingLanguage(.init(languageCode: .japanese))
        } else {
            self
        }
    }
}

private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Color.cardSurface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                }
            }
            .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.08), radius: 8, y: 2)
    }
}
