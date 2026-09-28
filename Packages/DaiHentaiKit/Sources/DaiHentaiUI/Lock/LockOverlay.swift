import DaiHentaiCore
import SwiftUI

/// Content of the lock window: the lock screen, or a plain privacy shield.
struct LockOverlay: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            if lock.isLocked {
                LockScreen(lock: lock)
                    .transition(.opacity)
            } else if lock.isShielded {
                PrivacyShield()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: lock.isLocked)
        .sensoryFeedback(.success, trigger: lock.isLocked) { wasLocked, isLocked in wasLocked && !isLocked }
        .tint(.moeAccent)
    }
}

private struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            Kaomoji(text: "O3O", style: .system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(Color.moeAccent.opacity(0.8))
        }
        .accessibilityHidden(true)
    }
}

struct LockScreen: View {
    let lock: AppLock

    @ScaledMetric(relativeTo: .largeTitle) private var badgeSize: CGFloat = 132

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.moeAccent.opacity(0.28), Color.canvas, Color.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(Color.canvas)
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.moeAccent.opacity(0.15))
                        .frame(width: badgeSize, height: badgeSize)
                        .overlay {
                            Kaomoji(text: "O3O", style: .system(size: badgeSize * 0.34, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.moeAccent)
                        }
                    Image(systemName: "lock.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.moeAccent, in: .circle)
                        .offset(x: 4, y: 4)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("萌萌噠")
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                    Text("使用這個 App 需要先解鎖呦")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if let message = lock.message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Color.moeAccent)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .transition(.opacity)
                            .accessibilityIdentifier("lockMessage")
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("解鎖", systemImage: lock.biometricKind.symbolName)
                        .font(.headline)
                        .frame(minWidth: 180)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
                .accessibilityIdentifier("unlockButton")
                .padding(.bottom, 48)
            }
        }
        .sensoryFeedback(.error, trigger: lock.message) { _, new in new != nil }
        .animation(.smooth, value: lock.message)
    }
}
