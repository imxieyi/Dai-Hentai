import DaiHentaiCore
import SwiftUI

/// The tab bar accessory: 「下載中」 while downloads run, otherwise 「繼續看」 for the last unfinished gallery.
/// It never shows covers, since it is visible on every tab.
struct BottomAccessory: View {
    enum Content: Equatable {
        case downloading(count: Int, progress: Double, title: String)
        case resume(GalleryInfo, page: Int)
    }

    let content: Content

    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button(action: activate) {
            switch content {
            case let .downloading(count, progress, title):
                downloading(count: count, progress: progress, title: title)
            case let .resume(gallery, page):
                resume(gallery, page: page)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("bottomAccessory")
    }

    private var isInline: Bool { placement == .inline }

    private func downloading(count: Int, progress: Double, title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.moeAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.moeAccent)
            }
            .frame(width: 22, height: 22)
            .animation(.smooth, value: progress)

            VStack(alignment: .leading, spacing: 1) {
                Text(count > 1 ? "下載中 \(count) 部" : "下載中")
                    .font(.subheadline.weight(.semibold))
                if !isInline {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Color.moeAccent)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("下載中 \(count) 部, \(progress.formatted(.percent.precision(.fractionLength(0))))")
        .accessibilityHint("打開下載")
    }

    private func resume(_ gallery: GalleryInfo, page: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "book.pages")
                .foregroundStyle(Color.moeAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(isInline ? "繼續看 第 \(page) 頁" : "繼續看")
                    .font(.subheadline.weight(.semibold))
                if !isInline {
                    Text(gallery.bestTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .japaneseTypesetting(!gallery.titleJpn.isEmpty)
                }
            }
            Spacer(minLength: 4)
            if !isInline {
                Text(gallery.fileCount > 0 ? "\(page) / \(gallery.fileCount)" : "第 \(page) 頁")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "play.fill")
                .font(.footnote)
                .foregroundStyle(Color.moeAccent)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("繼續看 \(gallery.bestTitle), 第 \(page) 頁")
    }

    private func activate() {
        switch content {
        case .downloading:
            model.router.tab = .downloads
        case let .resume(gallery, page):
            if model.router.tab == .settings { model.router.tab = .history }
            model.router.openReader(gallery, startPage: page)
        }
    }
}
