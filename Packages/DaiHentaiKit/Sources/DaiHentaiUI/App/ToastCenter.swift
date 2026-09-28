import SwiftUI

/// Short-lived messages, the successor of the old auto-dismissing "O3O" alerts.
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var kaomoji: String?
        var message: String
        var symbol: String?
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: LocalizedStringResource, kaomoji: String? = "O3O", symbol: String? = nil, duration: Duration = .seconds(1.6)) {
        let message = String(localized: message)
        let toast = Toast(kaomoji: kaomoji, message: message, symbol: symbol)
        withAnimation(.snappy) { current = toast }
        AccessibilityNotification.Announcement(message.spoken).post()
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, current?.id == toast.id else { return }
            withAnimation(.smooth) { current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.smooth) { current = nil }
    }
}

struct ToastOverlay: View {
    let center: ToastCenter
    /// In the reader the bars cover the top, so toasts appear in the middle, like 3.x's alerts.
    var isCentered = false

    var body: some View {
        VStack {
            if isCentered { Spacer() }
            if let toast = center.current {
                HStack(spacing: 8) {
                    if let symbol = toast.symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(Color.moeAccent)
                    }
                    if let kaomoji = toast.kaomoji {
                        Kaomoji(text: kaomoji, style: .subheadline.weight(.bold))
                            .foregroundStyle(Color.moeAccent)
                    }
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .accessibilityLabel(toast.message.spoken)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, isCentered ? 0 : 8)
                .padding(.horizontal, Metrics.sideMargin)
                .transition(isCentered ? .scale(scale: 0.9).combined(with: .opacity) : .move(edge: .top).combined(with: .opacity))
                .onTapGesture { center.dismiss() }
                .accessibilityIdentifier("toast")
            }
            Spacer()
        }
    }
}
