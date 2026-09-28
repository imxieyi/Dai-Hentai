import DaiHentaiCore
import SwiftUI
import WebKit

/// 「Eh/Ex 列表測試 (點擊開啟網頁)」: the site itself, with our cookies.
struct SiteWebView: View {
    let title: String
    let url: URL

    @Environment(AppModel.self) private var model
    @State private var page = WebPage()

    var body: some View {
        Group {
            if model.isDemo {
                KaomojiState(kaomoji: "O3O", title: "展示模式不會開網頁", message: url.absoluteString)
            } else {
                WebView(page)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            if page.isLoading {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            } else if !model.isDemo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重新整理", systemImage: "arrow.clockwise") { page.reload() }
                }
            }
        }
        .task {
            guard !model.isDemo, page.url == nil else { return }
            await ExSession.exportCookiesToWebKit()
            page.load(URLRequest(url: url))
        }
    }
}

/// 「用網頁登入 Ex」: the forum login page. Watches for the member cookies and closes by itself.
struct ExWebLoginView: View {
    static let loginURL = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = WebPage()
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isDemo {
                    KaomojiState(kaomoji: "O3O", title: "展示模式", message: "這裡平常會打開 E-Hentai 論壇的登入頁") {
                        Button("假裝登入成功") {
                            model.demoWebLogin()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("demoLoginButton")
                    }
                } else {
                    WebView(page)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .top) {
                            if page.isLoading {
                                ProgressView(value: page.estimatedProgress)
                                    .progressViewStyle(.linear)
                            }
                        }
                }
            }
            .navigationTitle("登入 Ex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                if !model.isDemo {
                    ToolbarItem(placement: .primaryAction) {
                        Button("重新整理", systemImage: "arrow.clockwise") { page.reload() }
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if !model.isDemo {
                    Text(isFinishing ? "登入成功, 設定中..." : "用 E-Hentai 論壇帳號登入, 成功後會自動關掉這頁")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        .task {
            guard !model.isDemo else { return }
            page.load(URLRequest(url: Self.loginURL))
            // Wait for the forum to hand out the member cookies, like 3.x's timer.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                let names = Set(cookies.filter { $0.domain.contains("e-hentai.org") }.map(\.name))
                if names.contains("ipb_member_id"), names.contains("ipb_pass_hash") {
                    isFinishing = true
                    await model.didFinishWebLogin()
                    dismiss()
                    return
                }
            }
        }
    }
}
