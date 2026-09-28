import DaiHentaiCore
import SwiftUI

/// Glass bar at the bottom of the reader: direction toggle, scrubber with a buffer track, 「12 / 40」.
struct ReaderBottomBar: View {
    let reader: ReaderModel
    @State private var dragPage: Int?

    var body: some View {
        let shownPage = (dragPage ?? reader.currentPage) + 1
        GlassEffectContainer {
            HStack(spacing: 14) {
                Button {
                    reader.setDirection(reader.direction.toggled)
                } label: {
                    Image(systemName: reader.direction == .vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("滑動方向切換")
                .accessibilityValue(reader.direction.title)
                .accessibilityIdentifier("directionToggle")

                PageScrubber(
                    pageCount: reader.pageCount,
                    current: reader.currentPage,
                    isReady: reader.isReady,
                    dragPage: $dragPage
                ) { page in
                    reader.jump(to: page)
                }

                Text("\(shownPage) / \(reader.pageCount)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
    }
}

/// A scrubber whose track shows which pages are already downloaded.
struct PageScrubber: View {
    let pageCount: Int
    let current: Int
    let isReady: (Int) -> Bool
    @Binding var dragPage: Int?
    let commit: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shown = dragPage ?? current
            let x = position(of: shown, width: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 5)
                Canvas { context, size in
                    guard pageCount > 0 else { return }
                    let step = size.width / CGFloat(pageCount)
                    var start: Int?
                    for page in 0...pageCount {
                        let ready = page < pageCount && isReady(page)
                        if ready, start == nil { start = page }
                        if !ready, let first = start {
                            context.fill(Path(CGRect(x: CGFloat(first) * step, y: 0, width: CGFloat(page - first) * step, height: size.height)), with: .color(.secondary.opacity(0.45)))
                            start = nil
                        }
                    }
                }
                .frame(height: 5)
                .clipShape(.capsule)
                Capsule()
                    .fill(Color.moeAccent)
                    .frame(width: max(5, x), height: 5)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: dragPage == nil ? 18 : 24, height: dragPage == nil ? 18 : 24)
                    .offset(x: x - (dragPage == nil ? 9 : 12))
                    .animation(.snappy(duration: 0.15), value: dragPage == nil)
                if let dragPage {
                    Text("第 \(dragPage + 1) 頁")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .offset(x: min(max(x - 30, 0), width - 60), y: -30)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragPage = page(at: value.location.x, width: width)
                    }
                    .onEnded { value in
                        let page = page(at: value.location.x, width: width)
                        dragPage = nil
                        commit(page)
                    }
            )
            .sensoryFeedback(.selection, trigger: dragPage)
        }
        .frame(height: 30)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { Double(current + 1) }, set: { commit(Int($0) - 1) }),
                in: 1...Double(max(pageCount, 2)),
                step: 1
            ) {
                Text("頁數")
            }
            .accessibilityValue("第 \(current + 1) 頁, 共 \(pageCount) 頁")
        }
        .accessibilityIdentifier("pageScrubber")
    }

    private func position(of page: Int, width: CGFloat) -> CGFloat {
        guard pageCount > 1 else { return width }
        return width * CGFloat(page) / CGFloat(pageCount - 1)
    }

    private func page(at x: CGFloat, width: CGFloat) -> Int {
        guard pageCount > 1, width > 0 else { return 0 }
        return min(max(Int((x / width * CGFloat(pageCount - 1)).rounded()), 0), pageCount - 1)
    }
}

/// 「您曾經閱讀過此作品」 as a banner instead of a blocking alert.
struct ResumeBanner: View {
    let page: Int
    let resume: () -> Void
    let fromStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Kaomoji(text: "O3O", style: .headline.weight(.bold))
                    .foregroundStyle(Color.moeAccent)
                Text("您曾經閱讀過此作品")
                    .font(.headline)
            }
            HStack(spacing: 10) {
                Button(action: resume) {
                    Text("繼續從 \(page) 頁看起").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("bannerResumeButton")
                Button(action: fromStart) {
                    Text("我要從頭看").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }
}

/// The page number while the chrome is hidden.
struct PagePill: View {
    let page: Int
    let count: Int

    var body: some View {
        Text("\(page) / \(count)")
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .accessibilityHidden(true)
    }
}
