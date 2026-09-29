import XCTest

/// Walks every screen in demo mode (offline, generated content) and keeps a screenshot of each,
/// for visual QA. Screens are named `NN-description`.
@MainActor
final class SmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // The walkthroughs below find controls by their Traditional Chinese titles, so pin the language.
        app.launchArguments = ["-DemoMode", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tab(_ title: String) -> XCUIElement {
        app.tabBars.buttons[title].exists ? app.tabBars.buttons[title] : app.buttons[title].firstMatch
    }

    private func pause(_ seconds: Double = 0.8) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    /// Waits for 「下載缺少的圖片」 / 「升級成原圖」 to finish.
    private func waitForBatch(timeout: TimeInterval = 40) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("stopBatchButton"))
        let done = XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
        pause(1)
        return done
    }

    /// Taps the dimmed backdrop under the status bar (which ignores taps), away from the card and its menu.
    private func dismissContextMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09)).tap()
        pause()
    }

    func testLaunch() {
        app.launch()
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
    }

    // MARK: - 列表 → 作品卡 → 閱讀

    func testListCardAndReader() {
        app.launch()
        let card = element("galleryCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        pause(1.5)
        snap("01-list")

        card.tap()
        XCTAssertTrue(element("readNowButton").waitForExistence(timeout: 5))
        pause()
        snap("02-card-medium")

        element("dismissCardButton").tap()
        pause()

        // Card for a half-read gallery offers 繼續從 N 頁看起.
        let third = app.descendants(matching: .any).matching(identifier: "galleryCard").element(boundBy: 2)
        third.tap()
        XCTAssertTrue(element("resumeButton").waitForExistence(timeout: 5))
        snap("03-card-resume")
        app.swipeUp()
        pause()
        snap("04-card-large")
        element("resumeButton").tap()
        pause(3)
        snap("05-reader-resumed-vertical")

        // Tap hides chrome.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause()
        snap("06-reader-chrome-hidden")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause()

        element("readerMoreMenu").tap()
        pause()
        snap("07-reader-menu")
        app.buttons["左右捲動"].firstMatch.tap()
        pause(2)
        snap("08-reader-horizontal")
        app.swipeLeft()
        pause(1.5)
        snap("09-reader-horizontal-next")

        // Back to vertical for the next runs.
        element("directionToggle").tap()
        pause(1.5)
        snap("10-reader-vertical-again")

        app.navigationBars.buttons.firstMatch.tap()
        pause()
        snap("11-list-after-reading")
    }

    func testReadFromStartAndScrub() {
        app.launch()
        let card = element("galleryCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        element("readNowButton").tap()
        pause(3)
        snap("12-reader-first-page")
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        pause(1.5)
        snap("13-reader-scrolled")
        let scrubber = element("pageScrubber")
        if scrubber.exists {
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            pause(2)
            snap("14-reader-scrubbed")
        }
        // Long press a page: context menu.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.2)
        pause()
        snap("15-reader-page-menu")
    }

    // MARK: - 搜尋 / 相關字詞

    func testSearchAndRelated() {
        app.launch()
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
        element("searchButton").tap()
        XCTAssertTrue(element("keywordField").waitForExistence(timeout: 5))
        pause()
        snap("20-search")
        app.buttons["中文"].firstMatch.tap()
        app.swipeUp()
        pause()
        if app.buttons["4星以上"].firstMatch.exists { app.buttons["4星以上"].firstMatch.tap() }
        pause()
        snap("21-search-scrolled")
        app.buttons["反選"].firstMatch.tap()
        pause()
        snap("22-search-no-category")
        app.buttons["全選"].firstMatch.tap()
        app.buttons["Cosplay"].firstMatch.tap()
        pause()
        element("searchConfirmButton").tap()
        pause(2)
        snap("23-list-filtered")

        element("galleryCard").tap()
        element("relatedButton").tap()
        pause()
        snap("24-related")
        let chips = app.scrollViews.buttons
        if chips.count > 1 {
            chips.element(boundBy: 0).tap()
            chips.element(boundBy: 1).tap()
        }
        pause()
        snap("25-related-picked")
        element("relatedConfirmButton").tap()
        pause(2)
        snap("26-list-related-search")
    }

    // MARK: - 歷史 / 下載

    func testHistoryAndDownloads() {
        app.launch()
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
        tab("歷史").tap()
        pause(1.5)
        snap("30-history")
        app.swipeUp()
        pause()
        snap("31-history-scrolled")
        app.swipeDown()
        app.swipeDown()

        let card = element("galleryCard")
        card.swipeLeft()
        pause()
        snap("32-history-swipe")
        app.staticTexts["今天"].firstMatch.tap()
        pause()

        // Opening a half-read gallery from history offers 您曾經閱讀過此作品.
        card.tap()
        pause(2.5)
        snap("33-reader-resume-banner")
        if element("bannerResumeButton").exists {
            element("bannerResumeButton").tap()
            pause(2)
            snap("34-reader-after-resume")
        }
        app.navigationBars.buttons.firstMatch.tap()
        pause()

        tab("下載").tap()
        pause(2)
        snap("35-downloads")

        // Seeded: a complete download in original quality, one from 3.x (reduced pages) and one that stopped
        // half way, none with a cover. The two jobs sit at the top, whatever the length of the list.
        XCTAssertTrue(element("downloadMissingButton").exists)
        XCTAssertTrue(element("upgradeOriginalsButton").exists)
        XCTAssertTrue(app.staticTexts["缺少封面"].exists)
        // A download's context menu offers only the jobs it needs.
        element("galleryCard").press(forDuration: 1.2)
        pause()
        XCTAssertTrue(element("menuResumeDownload").exists)
        XCTAssertFalse(element("menuUpgradeToOriginals").exists)
        snap("35-downloads-incomplete-menu")
        dismissContextMenu()
        // The 3.x download needs both: its cover, and originals for its pages.
        app.descendants(matching: .any).matching(identifier: "galleryCard").element(boundBy: 1).press(forDuration: 1.2)
        pause()
        XCTAssertTrue(element("menuResumeDownload").exists)
        XCTAssertTrue(element("menuUpgradeToOriginals").exists)
        snap("35-downloads-both-jobs-menu")
        dismissContextMenu()

        // 下載缺少的圖片: covers and missing pages, one download at a time, leaving reduced pages alone.
        element("downloadMissingButton").tap()
        XCTAssertTrue(element("stopBatchButton").waitForExistence(timeout: 3))
        snap("35-downloads-missing-running")
        XCTAssertTrue(waitForBatch())
        XCTAssertFalse(element("downloadMissingButton").exists)
        XCTAssertFalse(app.staticTexts["缺少封面"].exists)
        XCTAssertTrue(element("upgradeOriginalsButton").exists)
        snap("35-downloads-missing-done")
        // The complete download has nothing left to do.
        element("galleryCard").press(forDuration: 1.2)
        pause()
        XCTAssertTrue(app.buttons["我要現在看"].exists)
        XCTAssertFalse(element("menuResumeDownload").exists)
        XCTAssertFalse(element("menuUpgradeToOriginals").exists)
        snap("35-downloads-complete-menu")
        dismissContextMenu()

        // 升級成原圖 replaces the rest with originals.
        element("upgradeOriginalsButton").tap()
        XCTAssertTrue(waitForBatch())
        XCTAssertFalse(element("upgradeOriginalsButton").exists)
        XCTAssertFalse(element("downloadGaps").exists)
        snap("35-downloads-upgraded")
        element("galleryCard").tap()
        pause(2.5)
        snap("36-reader-downloaded")
        // Share and delete live in the ⋯ menu; a downloaded gallery's bar has only the menu.
        XCTAssertFalse(element("readerDownloadButton").exists)
        element("readerMoreMenu").tap()
        pause()
        XCTAssertTrue(element("deleteButton").exists)
        snap("36-reader-downloaded-menu")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        pause()
        app.navigationBars.buttons.firstMatch.tap()
        pause()

        // Start a download from the list and watch the accessory.
        tab("列表").tap()
        pause()
        let listCard = app.descendants(matching: .any).matching(identifier: "galleryCard").element(boundBy: 1)
        listCard.swipeRight()
        pause()
        snap("37-list-swipe-download")
        if element("swipeDownload").exists { element("swipeDownload").tap() }
        pause(1.2)
        snap("38-list-downloading")
        tab("下載").tap()
        pause(1)
        snap("39-downloads-active")
    }

    // MARK: - 設定

    func testSettings() {
        app.launch()
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
        tab("設定").tap()
        pause(2)
        snap("40-settings")
        app.swipeUp()
        pause()
        snap("41-settings-scrolled")
        app.swipeDown()
        pause()

        element("settingsExKey").tap()
        let field = element("exKeyField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("not-a-key")
        pause()
        snap("42-exkey-invalid")
        field.clearAndType(String(repeating: "a", count: 32) + "12345x" + "igneousvalue")
        pause()
        snap("43-exkey-valid")
        element("exKeyConfirm").tap()
        pause(2)
        snap("44-exkey-success")
        pause(1)
        snap("45-settings-logged-in")
        tab("列表").tap()
        pause(2)
        snap("46-list-ex")
    }

    func testExWebLoginDemo() {
        app.launch()
        XCTAssertTrue(element("exLoginButton").waitForExistence(timeout: 10))
        element("exLoginButton").tap()
        pause()
        snap("47-ex-web-login-demo")
        element("demoLoginButton").tap()
        pause(2)
        snap("48-list-after-web-login")
    }

    func testDarkModeTour() {
        app.launchArguments += ["-DemoDark"]
        app.launch()
        let card = element("galleryCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        pause(1.5)
        snap("60-dark-list")
        app.descendants(matching: .any).matching(identifier: "galleryCard").element(boundBy: 2).tap()
        XCTAssertTrue(element("resumeButton").waitForExistence(timeout: 5))
        pause()
        snap("61-dark-card")
        element("resumeButton").tap()
        pause(3)
        snap("62-dark-reader")
        element("directionToggle").tap()
        pause(0.5)
        snap("63-dark-reader-toast")
        pause(1.5)
        element("directionToggle").tap()
        app.navigationBars.buttons.firstMatch.tap()
        pause()
        element("searchButton").tap()
        pause()
        snap("64-dark-search")
        app.swipeUp()
        pause()
        snap("65-dark-search-categories")
        app.buttons["取消"].firstMatch.tap()
        pause()
        tab("歷史").tap()
        pause()
        snap("66-dark-history")
        tab("下載").tap()
        pause()
        snap("67-dark-downloads")
        tab("設定").tap()
        pause(1.5)
        snap("68-dark-settings")
    }

    func testLandscapeReader() {
        app.launch()
        let card = element("galleryCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        element("readNowButton").tap()
        pause(2.5)
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2)
        snap("70-landscape-vertical")
        app.swipeUp()
        pause(1)
        snap("71-landscape-vertical-scrolled")
        if element("directionToggle").exists { element("directionToggle").tap() }
        pause(2)
        snap("72-landscape-horizontal")
        app.swipeLeft()
        pause(1.5)
        snap("73-landscape-horizontal-next")
        XCUIDevice.shared.orientation = .portrait
        pause(2)
        snap("74-portrait-again")
        if element("directionToggle").exists { element("directionToggle").tap() }
        pause()
    }

    func testLargeText() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        let card = element("galleryCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        pause(1)
        snap("75-large-list")
        card.tap()
        pause()
        snap("76-large-card")
        app.swipeDown(velocity: .fast)
        pause()
        tab("設定").tap()
        pause(1.5)
        snap("77-large-settings")
    }

    // MARK: - 歷史 / 下載 filters

    func testLibraryFilters() {
        app.launch()
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
        let cards = app.descendants(matching: .any).matching(identifier: "galleryCard")

        // 歷史 has the list's filters and search sheet, applied to what's on the device.
        tab("歷史").tap()
        pause(1.5)
        XCTAssertTrue(element("filterDefaultChip").exists)
        element("historySearchButton").tap()
        let field = element("keywordField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("winter")
        pause()
        snap("52-history-search")
        element("searchConfirmButton").tap()
        pause(1.2)
        XCTAssertEqual(cards.count, 1) // Winter Onsen Trip
        XCTAssertFalse(element("filterDefaultChip").exists)
        snap("53-history-filtered")

        // Nothing left: the same ways out as the list.
        element("historySearchButton").tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("nothing like this")
        element("searchConfirmButton").tap()
        pause(1.2)
        XCTAssertEqual(cards.count, 0)
        XCTAssertTrue(element("clearFiltersButton").exists)
        snap("54-history-no-matches")
        element("clearFiltersButton").tap()
        pause()
        XCTAssertTrue(element("filterDefaultChip").exists)
        XCTAssertGreaterThan(cards.count, 2)

        // 下載 too, and its jobs only count the downloads shown.
        tab("下載").tap()
        pause(1.5)
        XCTAssertTrue(element("upgradeOriginalsButton").exists)
        element("downloadsSearchButton").tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("cherry")
        element("searchConfirmButton").tap()
        pause(1.2)
        XCTAssertEqual(cards.count, 1) // Cherry Blossom Letters, in original quality but without a cover
        XCTAssertTrue(element("downloadMissingButton").exists)
        XCTAssertFalse(element("upgradeOriginalsButton").exists)
        snap("55-downloads-filtered")
    }

    func testEmptyLibrary() {
        app.launchArguments += ["-DemoEmptyLibrary"]
        app.launch()
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
        tab("歷史").tap()
        pause()
        snap("50-history-empty")
        tab("下載").tap()
        pause()
        snap("51-downloads-empty")
    }
}

// MARK: - Other languages

extension SmokeUITests {
    private struct Language {
        let code: String
        let locale: String
        let tabs: [String]
        let cancel: String
    }

    func testTourEnglish() {
        tour(Language(code: "en", locale: "en_US", tabs: ["Browse", "History", "Downloads", "Settings"], cancel: "Cancel"))
    }

    func testTourSimplifiedChinese() {
        tour(Language(code: "zh-Hans", locale: "zh_CN", tabs: ["列表", "历史", "下载", "设置"], cancel: "取消"))
    }

    func testTourJapanese() {
        tour(Language(code: "ja", locale: "ja_JP", tabs: ["一覧", "履歴", "ダウンロード", "設定"], cancel: "キャンセル"))
    }

    /// The main screens in one language, found by identifier (or by the expected tab titles).
    private func tour(_ language: Language) {
        app.launchArguments = ["-DemoMode", "-AppleLanguages", "(\(language.code))", "-AppleLocale", language.locale]
        app.launch()
        let name = { (step: String) in "80-\(language.code)-\(step)" }
        XCTAssertTrue(element("galleryCard").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(language.tabs[0]).exists, "tab titles are localized")
        pause(1.5)
        snap(name("01-list"))

        app.descendants(matching: .any).matching(identifier: "galleryCard").element(boundBy: 2).tap()
        XCTAssertTrue(element("resumeButton").waitForExistence(timeout: 5))
        pause()
        snap(name("02-card"))
        app.swipeUp()
        pause()
        snap(name("03-card-large"))
        element("relatedButton").tap()
        pause()
        snap(name("04-related"))
        app.navigationBars.buttons.firstMatch.tap()
        pause()

        element("resumeButton").tap()
        pause(3)
        snap(name("05-reader"))
        element("readerMoreMenu").tap()
        pause()
        snap(name("06-reader-menu"))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        pause()
        app.navigationBars.buttons.firstMatch.tap()
        pause()

        element("searchButton").tap()
        XCTAssertTrue(element("keywordField").waitForExistence(timeout: 5))
        pause()
        snap(name("07-search"))
        app.swipeUp()
        pause()
        snap(name("08-search-categories"))
        app.buttons[language.cancel].firstMatch.tap()
        pause()

        tab(language.tabs[1]).tap()
        pause(1.5)
        snap(name("09-history"))
        tab(language.tabs[2]).tap()
        pause(1.5)
        snap(name("10-downloads"))
        tab(language.tabs[3]).tap()
        pause(2)
        snap(name("11-settings"))
        app.swipeUp()
        pause()
        snap(name("12-settings-more"))
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
