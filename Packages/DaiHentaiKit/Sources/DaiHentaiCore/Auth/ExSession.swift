import Foundation
import WebKit

/// ExHentai access is cookie based: logging in on forums.e-hentai.org yields `ipb_member_id` /
/// `ipb_pass_hash`, which we copy to `.exhentai.org` (and `igneous` when the user pastes an ExKey).
public enum ExSession {
    static let eHentaiURL = URL(string: "https://e-hentai.org")!
    static let fiveYears: TimeInterval = 157_784_760

    /// Whether a non-expired login cookie exists. Also mirrors e-hentai cookies to exhentai, like 3.x.
    public static func isLoggedIn(storage: HTTPCookieStorage = .shared) -> Bool {
        let cookies = storage.cookies(for: eHentaiURL) ?? []
        let valid = cookies.contains { $0.name == "ipb_pass_hash" && ($0.expiresDate.map { $0 > .now } ?? true) }
        if valid { mirrorToExHentai(storage: storage) }
        return valid
    }

    public static var currentSite: Site { isLoggedIn() ? .exHentai : .eHentai }

    /// Removes every cookie ("Ex 登入整個失敗 還是只有熊貓 點我登出").
    @MainActor
    public static func logOut(storage: HTTPCookieStorage = .shared) async {
        for cookie in storage.cookies ?? [] {
            storage.deleteCookie(cookie)
        }
        await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }

    /// Logs in with an ExKey: `<32-char pass hash><member id>x<igneous>`. Returns `false` when malformed.
    @discardableResult
    public static func logIn(exKey rawKey: String, storage: HTTPCookieStorage = .shared) -> Bool {
        guard let parts = parse(exKey: rawKey) else { return false }
        for cookie in storage.cookies ?? [] {
            storage.deleteCookie(cookie)
        }
        for (name, value) in [("ipb_member_id", parts.memberID), ("ipb_pass_hash", parts.passHash), ("igneous", parts.igneous)] {
            for domain in [".exhentai.org", ".e-hentai.org"] {
                if let cookie = makeCookie(name: name, value: value, domain: domain) {
                    storage.setCookie(cookie)
                }
            }
        }
        return true
    }

    public struct ExKey: Equatable, Sendable {
        public let passHash: String
        public let memberID: String
        public let igneous: String
    }

    public static func parse(exKey rawKey: String) -> ExKey? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = key.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].count > 32, !parts[1].isEmpty else { return nil }
        let member = parts[0]
        let memberID = String(member.dropFirst(32))
        guard memberID.allSatisfy(\.isNumber) else { return nil }
        return ExKey(passHash: String(member.prefix(32)), memberID: memberID, igneous: parts[1])
    }

    /// Copies cookies from the web view's store (login page) into `HTTPCookieStorage`.
    @MainActor
    public static func importWebKitCookies(storage: HTTPCookieStorage = .shared) async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.contains("e-hentai.org") || cookie.domain.contains("exhentai.org") {
            storage.setCookie(cookie)
        }
    }

    /// Pushes our cookies into the web view's store so web pages see the same login.
    @MainActor
    public static func exportCookiesToWebKit(storage: HTTPCookieStorage = .shared) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in storage.cookies ?? [] {
            await store.setCookie(cookie)
        }
    }

    private static func mirrorToExHentai(storage: HTTPCookieStorage) {
        for cookie in storage.cookies(for: eHentaiURL) ?? [] {
            guard var properties = cookie.properties else { continue }
            properties[.domain] = ".exhentai.org"
            if let copy = HTTPCookie(properties: properties) {
                storage.setCookie(copy)
            }
        }
    }

    private static func makeCookie(name: String, value: String, domain: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: domain,
            .name: name,
            .value: value,
            .path: "/",
            .expires: Date(timeIntervalSinceNow: fiveYears),
        ])
    }
}
