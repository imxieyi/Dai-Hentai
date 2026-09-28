import DaiHentaiCore
import SwiftUI

// MARK: - Images

/// Cover thumbnail loaded through the cookie-aware pipeline (ExHentai covers need cookies).
/// A downloaded gallery's saved cover is used first, so it also shows offline.
struct CoverImage: View {
    let gallery: GalleryInfo
    var cornerRadius: CGFloat = Metrics.coverRadius

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            let maxPixel = max(proxy.size.width, proxy.size.height) * displayScale
            ZStack {
                Color.placeholderFill
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                        .transition(.opacity)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                } else {
                    Kaomoji(text: "O3O", style: .footnote.weight(.semibold))
                        .foregroundStyle(.quaternary)
                }
            }
            .task(id: gallery.thumb) {
                guard let url = gallery.thumbURL, maxPixel > 0 else { return }
                failed = false
                let localFile = model.library.files.coverURL(folder: gallery.folderName)
                let loaded = await ImagePipeline.shared.thumbnail(for: url, localFile: localFile, maxPixelSize: maxPixel)
                withAnimation(.easeOut(duration: 0.2)) {
                    image = loaded
                    failed = loaded == nil
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A downloaded page, decoded from disk at the size it is displayed.
struct PageImage: View {
    let fileURL: URL
    let targetSize: CGSize
    /// Bumped by 「重新載入這頁」 to decode the new file.
    var version = 0

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.placeholderFill.opacity(0.4)
                ProgressView()
            }
        }
        .task(id: "\(fileURL.path(percentEncoded: false))|\(version)|\(Int(targetSize.width))") {
            let maxPixel = max(targetSize.width, targetSize.height) * displayScale
            guard maxPixel > 0 else { return }
            let key = ImagePipeline.pageKey(fileURL, maxPixelSize: maxPixel)
            if let cached = ImagePipeline.shared.cachedImage(for: key) {
                image = cached
                return
            }
            image = await ImagePipeline.shared.page(at: fileURL, maxPixelSize: maxPixel)
        }
    }
}

// MARK: - Chips

struct CategoryChip: View {
    let categoryName: String

    var body: some View {
        let category = GalleryCategory(apiName: categoryName)
        HStack(spacing: 5) {
            Circle()
                .fill(category?.swatch ?? .gray)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
            Text(category?.rawValue ?? categoryName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(category?.ink ?? .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((category?.swatch ?? .gray).opacity(0.16), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category?.spokenName ?? categoryName)
    }
}

/// 中文 / 日文 / 英文… plus 翻譯, from `language:` tags, named in the app's language.
struct LanguagePill: View {
    let tags: [String]

    var body: some View {
        if let text = Self.label(for: tags) {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: .capsule)
                .lineLimit(1)
        }
    }

    static func label(for tags: [String]) -> String? {
        let languages = tags.compactMap { tag -> String? in
            guard tag.hasPrefix("language:") else { return nil }
            return String(tag.dropFirst("language:".count))
        }
        let codes: [String: String] = [
            "chinese": "zh", "japanese": "ja", "english": "en", "korean": "ko", "spanish": "es",
            "french": "fr", "russian": "ru", "thai": "th", "german": "de", "italian": "it",
            "portuguese": "pt", "vietnamese": "vi", "indonesian": "id", "polish": "pl",
        ]
        let locale = AppLanguage.locale
        let primary = languages.lazy.compactMap { codes[$0].flatMap { locale.localizedString(forLanguageCode: $0) } }.first
        let translated = languages.contains("translated") ? String(localized: .languageTranslated) : nil
        let parts = [primary, translated].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct RatingView: View {
    enum Style { case compact, stars }

    let rating: Double
    var style: Style = .compact

    var body: some View {
        HStack(spacing: 3) {
            switch style {
            case .compact:
                Image(systemName: "star.fill")
                    .foregroundStyle(Color.star)
                    .imageScale(.small)
            case .stars:
                ForEach(0..<5) { index in
                    Image(systemName: symbol(for: index))
                        .foregroundStyle(Color.star)
                        .imageScale(.small)
                }
            }
            Text(rating, format: .number.precision(.fractionLength(2)))
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(.ratingAccessibility(rating.formatted(.number.precision(.fractionLength(1)))))
    }

    private func symbol(for index: Int) -> String {
        let value = rating - Double(index)
        if value >= 0.75 { return "star.fill" }
        if value >= 0.25 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Selectable chip used by 搜尋 and 相關字詞.
struct ToggleChip: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(isOn ? Color.moeAccent.opacity(0.8) : .secondary)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? Color.moeAccent : .primary)
            .background(isOn ? Color.moeAccent.opacity(0.14) : Color(uiColor: .tertiarySystemFill), in: .capsule)
            .overlay(Capsule().strokeBorder(isOn ? Color.moeAccent.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
        .animation(.snappy, value: isOn)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .init(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + itemWidth > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - States

/// Big kaomoji empty / error state.
struct KaomojiState<Actions: View>: View {
    let kaomoji: String
    let title: LocalizedStringResource
    var message: LocalizedStringResource?
    @ViewBuilder var actions: () -> Actions

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 56

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                Kaomoji(text: kaomoji, style: .system(size: heroSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.moeAccent)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .accessibilityLabel(String(localized: title).spoken)
            }
        } description: {
            if let message { Text(message) }
        } actions: {
            actions()
        }
    }
}

extension KaomojiState where Actions == EmptyView {
    init(kaomoji: String, title: LocalizedStringResource, message: LocalizedStringResource? = nil) {
        self.init(kaomoji: kaomoji, title: title, message: message) { EmptyView() }
    }
}

/// Footer row for paging lists ("列表載入中...", "沒有更多作品囉 O3O", ...).
struct FooterRow: View {
    let text: LocalizedStringResource
    var showsSpinner = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var label: some View {
        HStack(spacing: 8) {
            if showsSpinner { ProgressView() }
            Text(text)
                .font(.subheadline)
                .fontDesign(.rounded)
                .foregroundStyle(action == nil ? Color.secondary : Color.moeAccent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: text).spoken)
    }
}

/// Blocking progress HUD ("作品刪除中 ( i / n )").
struct GlassHUD: View {
    let title: LocalizedStringResource
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title)
                    .font(.headline)
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                ProgressView(value: progress)
                    .frame(width: 200)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Diagnostic status with symbol + word (colour is never the only signal).
struct StatusBadge: View {
    let status: ProbeStatus
    var parseFailureText: LocalizedStringResource?

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
            case .parseFailed:
                Image(systemName: "exclamationmark.triangle.fill")
            case .networkFailed:
                Image(systemName: "wifi.exclamationmark")
            case .notLoggedIn:
                Image(systemName: "person.crop.circle.badge.xmark")
            }
            Text(status == .parseFailed ? (parseFailureText ?? status.title) : status.title)
        }
        .font(.subheadline)
        .foregroundStyle(status == .success ? Color.green : status == .testing ? Color.secondary : Color.red)
        .contentTransition(.symbolEffect(.replace))
        .animation(.default, value: status)
    }
}
