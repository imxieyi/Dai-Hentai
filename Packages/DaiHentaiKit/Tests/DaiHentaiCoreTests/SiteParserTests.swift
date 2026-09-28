import Foundation
import Testing
@testable import DaiHentaiCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self)
}

@Suite struct SiteParserTests {
    @Test func listPageYieldsUniqueGalleryReferencesInOrder() throws {
        let references = try SiteParser.galleryReferences(inListPage: fixtureText("list.html"))
        #expect(references == [
            .init(gid: "4217580", token: "9504af7609"),
            .init(gid: "4217579", token: "d2fe6d0b42"),
        ])
    }

    @Test func galleryPageYieldsImagePageLinks() throws {
        let links = try SiteParser.imagePageLinks(inGalleryPage: fixtureText("gallery.html"))
        #expect(links == [
            "https://e-hentai.org/s/614897845c/4217580-1",
            "https://e-hentai.org/s/0c3283bed8/4217580-2",
            "https://e-hentai.org/s/c7e111b927/4217580-3",
        ])
    }

    @Test func imagePageYieldsShowKeyImageAndOriginal() throws {
        let html = try fixtureText("imagepage.html")
        #expect(SiteParser.showKey(inImagePage: html) == "6ljzzv8ans6")
        let sources = try #require(try SiteParser.imageSources(inImagePage: html))
        #expect(sources.image.hasSuffix("/001.webp"))
        #expect(sources.original == "https://e-hentai.org/fullimg/4217580/1/1bb8s7xansc/001.jpg")
    }

    @Test func showPageResponseYieldsImageAndOriginal() throws {
        let sources = try #require(try SiteParser.imageSources(inShowPageResponse: fixture("showpage.json")))
        #expect(sources.image == "https://example.hath.network/h/def-1280-1807-wbp/002.webp")
        #expect(sources.original == "https://e-hentai.org/fullimg/4217580/2/5b8z182ansc/002.jpg")
        #expect(try SiteParser.imageSources(inShowPageResponse: Data(#"{"error":"Key mismatch"}"#.utf8)) == nil)
    }

    @Test func theImageLimitsPlaceholderIsRecognised() throws {
        #expect(SiteParser.isRateLimitImage("https://ehgt.org/g/509.gif"))
        #expect(SiteParser.isRateLimitImage("https://example.hath.network/h/abc/509s.gif"))
        #expect(!SiteParser.isRateLimitImage("https://example.hath.network/h/abc-1280-1807-wbp/001.webp"))
        let html = #"<div id="i3"><img id="img" src="https://ehgt.org/g/509.gif" /></div>"#
        #expect(try SiteParser.imageSources(inImagePage: html)?.image == "https://ehgt.org/g/509.gif")
    }

    @Test func imageResponsesThatArentImagesAreErrors() throws {
        func check(_ url: String, status: Int = 200, type: String = "image/jpeg") -> SiteError? {
            let response = HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
            do {
                try LiveGalleryService.check(imageResponse: response, data: Data([1, 2, 3]))
                return nil
            } catch {
                return error
            }
        }
        #expect(check("https://example.hath.network/h/abc/001.jpg") == nil)
        #expect(check("https://example.hath.network/h/abc/001.jpg", status: 509) == .rateLimited)
        #expect(check("https://ehgt.org/g/509.gif", type: "image/gif") == .rateLimited)
        #expect(check("https://e-hentai.org/bounce_login.php?b=ds&bt=7-1-1-key", type: "text/html") == .loginRequired)
        #expect(check("https://e-hentai.org/fullimg/1/1/key/001.jpg", type: "text/html") == .parse)
        #expect(check("https://example.hath.network/h/abc/001.jpg", status: 404) == .network)
    }

    @Test func aPageShownAsTheOriginalHasNoOriginalLink() throws {
        let html = #"<div id="i3"><img id="img" src="https://example.hath.network/h/9ca0497da6-335858-1280-1833-jpg/1.jpg" /></div><div id="i6"><div><a href="https://e-hentai.org/?f_shash=9ca0497da6">Show galleries with this image</a></div></div>"#
        let sources = try #require(try SiteParser.imageSources(inImagePage: html))
        #expect(sources.original == nil)
        let response = Data(#"{"i3":"<img id=\"img\" src=\"https://example.hath.network/h/9ca0-jpg/1.jpg\" />","i6":"<div>Reload broken image</div>"}"#.utf8)
        #expect(try SiteParser.imageSources(inShowPageResponse: response)?.original == nil)
    }

    @Test func gdataIsParsedLenientlyAndKeepsListOrder() throws {
        let order: [SiteParser.GalleryReference] = [.init(gid: "4217580", token: "9504af7609"), .init(gid: "4217579", token: "d2fe6d0b42")]
        let galleries = try SiteParser.galleries(inGDataResponse: fixture("gdata.json"), order: order)
        #expect(galleries.map(\.gid) == ["4217580", "4217579"])

        let first = try #require(galleries.first)
        #expect(first.fileCount == 101)
        #expect(first.rating == 4.52)
        #expect(first.category == .doujinshi)
        #expect(first.bestTitle == "[サークル] サンプル/ワン")
        #expect(first.tags == ["parody:original", "female:glasses"])
        #expect(first.posted.count == "yyyy-MM-dd HH:mm".count)
        #expect(galleries[1].title == "[Circle] Sample Two & Friends")
    }

    @Test func imagePageURLIsSplitIntoParts() throws {
        let page = try #require(ImagePage("https://e-hentai.org/s/1a8e31f2c6/1029334-12"))
        #expect(page.imageKey == "1a8e31f2c6")
        #expect(page.gid == "1029334")
        #expect(page.page == 12)
        #expect(ImagePage.fileName(for: "https://e-hentai.org/s/1a8e31f2c6/1029334-12") == "1029334-12")
    }
}

@Suite struct SearchFilterTests {
    @Test func defaultFilterOnlyAsksForTheListLayout() {
        let items = SearchFilter().queryItems(next: nil)
        #expect(items == [URLQueryItem(name: "inline_set", value: "dm_l")])
    }

    @Test func refinementsMapToSiteParameters() {
        var filter = SearchFilter(keyword: "maid cafe", minimumRating: .four, language: .chineseOnly)
        filter.categories = [.doujinshi, .manga]
        let items = Dictionary(uniqueKeysWithValues: filter.queryItems(next: "123").map { ($0.name, $0.value ?? "") })
        #expect(items["f_search"] == "maid cafe language:Chinese")
        #expect(items["f_cats"] == String(1023 - 2 - 4))
        #expect(items["f_srdd"] == "4") // 3.x: rating index + 1
        #expect(items["advsearch"] == "1")
        #expect(items["next"] == "123")
    }

    @Test func originalOnlyExcludesTranslations() {
        let filter = SearchFilter(language: .originalOnly)
        #expect(filter.queryItems(next: nil).first { $0.name == "f_search" }?.value == "-translated -rewrite")
    }
}

@Suite struct GalleryInfoTests {
    @Test func folderNameMatchesVersion3() {
        // 3.x: [[bestTitle componentsSeparatedByString:@"/"] componentsJoinedByString:@"-"]
        let info = GalleryInfo(gid: "1", token: "t", title: "A/B", titleJpn: "日本語/タイトル/です")
        #expect(info.folderName == "日本語-タイトル-です")
        #expect(GalleryInfo(gid: "1", token: "t", title: "English / Title").folderName == "English - Title")
    }

    @Test func overlongTitlesGetAFolderTheFileSystemAccepts() {
        let info = GalleryInfo(gid: "42", token: "t", title: String(repeating: "長", count: 120))
        #expect(info.folderName.utf8.count <= 255)
        #expect(info.folderName.hasSuffix("-42"))
    }

    @Test func titleSplittingDropsPunctuationAndDashedWords() {
        #expect(GalleryInfo.splitTitle("[Circle] Title-Case (Original) Vol.2 ~Extra~") == ["Circle", "Original", "Vol", "2", "Extra"])
    }

    @Test func legacyCategoryNamesAreRecognised() {
        #expect(GalleryCategory(apiName: "Artist CG Sets") == .artistCG)
        #expect(GalleryCategory(apiName: "Image Sets") == .imageSet)
        #expect(GalleryCategory(apiName: "Non-H") == .nonH)
    }
}

@Suite struct ExSessionTests {
    @Test func exKeyIsSplitIntoCookies() throws {
        let key = ExSession.parse(exKey: "0123456789abcdef0123456789abcdef1234567xdeadbeef")
        #expect(key == ExSession.ExKey(passHash: "0123456789abcdef0123456789abcdef", memberID: "1234567", igneous: "deadbeef"))
        #expect(ExSession.parse(exKey: "nonsense") == nil)
        #expect(ExSession.parse(exKey: "0123456789abcdef0123456789abcdefx") == nil)
    }

    @Test func loggingInWithExKeySetsBothDomains() throws {
        let storage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "test.\(UUID().uuidString)")
        #expect(ExSession.logIn(exKey: "0123456789abcdef0123456789abcdef1234567xdeadbeef", storage: storage))
        let exCookies = storage.cookies(for: URL(string: "https://exhentai.org")!) ?? []
        #expect(Set(exCookies.map(\.name)) == ["ipb_member_id", "ipb_pass_hash", "igneous"])
        #expect(ExSession.isLoggedIn(storage: storage))
    }
}

@Suite struct SearchHintsTests {
    @Test func mostFrequentWordsComeFirstAndNoiseIsIgnored() {
        let galleries = [
            GalleryInfo(gid: "1", token: "a", title: "Maid Cafe Diary", tags: ["language:chinese", "female:maid"]),
            GalleryInfo(gid: "2", token: "b", title: "Maid Festival", tags: ["female:maid", "other:full color"]),
            GalleryInfo(gid: "3", token: "c", title: "Cafe Maid", titleJpn: "メイド 喫茶", tags: ["female:maid"]),
        ]
        #expect(SearchHints.recentTags(from: galleries).first == "female:maid")
        #expect(!SearchHints.recentTags(from: galleries).contains("language:chinese"))
        #expect(SearchHints.recentTitleWords(from: galleries).first == "maid")
    }

    @Test func keywordFromHintsUsesSiteSyntax() {
        #expect(SearchHints.keyword(from: ["female:big breasts", "maid", "Maid"]) == #"female:"big breasts$" maid"#)
    }

    @Test func translatorStripsNamespaces() {
        let translator = TagTranslator(dictionary: ["glasses": "眼鏡"])
        #expect(translator.translate("female:glasses") == "眼鏡")
        #expect(translator.annotated("glasses") == "glasses (眼鏡)")
        #expect(translator.annotated("unknown") == "unknown")
        #expect(TagTranslator(display: .simplified).translate("1 equals 2") == "1=2")
        // The dictionary is Simplified Chinese: converted for Traditional, hidden elsewhere.
        #expect(TagTranslator(dictionary: ["glasses": "眼镜"], display: .traditional).translate("glasses") == "眼鏡")
        #expect(TagTranslator(dictionary: ["glasses": "眼镜"], display: .hidden).translate("glasses") == nil)
    }
}
