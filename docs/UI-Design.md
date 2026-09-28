# 萌萌噠 4 — UI design (final)

The 4.0 UI was chosen in a design competition: four designers worked from the same brief, then four reviewers each scored all four designs (0–10) against a fixed rubric (feels-like-home 25%, usability 20%, iOS 27 idiom 15%, visual coherence 15%, feasibility 15%, completeness & accessibility 10%).

| Design | Reviewer 1 | Reviewer 2 | Reviewer 3 | Reviewer 4 | **Total /40** |
|---|---|---|---|---|---|
| **A 「糖玻璃 Candy Glass」** | 8.5 | 8.7 | 8.8 | 8.5 | **34.5** |
| B 「Q彈」 | 8.2 | 8.2 | 8.5 | 8.3 | 33.2 |
| C 「麻糬 Mochi」 | 8.0 | 8.5 | 8.3 | 8.0 | 32.8 |
| D 「Candy Glass」 (second) | 8.3 | 8.4 | 8.4 | 8.2 | 33.3 |

**Design A is the base.** The final design adds the ideas every reviewer said to borrow, and fixes the weak spots they found in A.

| From | Adopted | Why |
|---|---|---|
| B | First-launch import of the 3.x Couchbase data (history, downloads, last page, saved search, preferences) | An empty 歷史/下載 after the update breaks "feels like home" more than any UI change could. |
| B | Category **ink** colours: the legacy hex is used for the dot and the tint, and a darker ink is used for the category *name* | The name stays coloured, as users remember it, and still meets 4.5:1 contrast. |
| B | Legacy settings section headers: App 狀態 · 用量 · 觀看習慣 · 隱私設定 | Same map as 3.x. |
| B | No glass on glass: buttons inside sheets use `.bordered` / `.borderedProminent` | Fixes A's own rule violation. |
| B, C, D | Search hints **replace the keyword on 好** (legacy behaviour), with a live 「將搜尋：」 preview | Reverts A's change to a journey old users know, and makes the rule visible. |
| C | 作品卡 keeps the alert's shape: heading 「O3O 這部作品有 N 頁呦」, and all four actions visible at the medium detent, including a plain 「都不要 O3O」 | Fixes A's 都不要 O3O sitting below the fold. |
| C | Tag chips open a menu: 用這個 Tag 搜尋 / 挑更多相關字詞… / 拷貝 | One control covers both "search now" and "refine". |
| C | Status bar hidden through the root view (preference), not inside the pushed reader. `title_jpn` uses `.typesettingLanguage(.japanese)`. Pages are downsampled with ImageIO. | Reliable, correct glyphs, bounded memory. |
| C | Logout has no confirmation, like 3.x. ExKey keeps the strings 「用Cookie登錄」 / 「請在此處輸入Cookie」. | Legacy fidelity. |
| D | Bottom accessory 「下載中 / 繼續看」 via `tabViewBottomAccessory(isEnabled:)`, with separate inline and expanded layouts. It shows **no covers** (A's discretion rule). | One-tap resume from any tab, discreet in public. |
| D | ExKey is validated as you type. 好 writes the cookies, runs the Ex test, and only then reports success. | No false "登入成功". |
| D | Lock falls back to the device passcode once if biometrics are no longer enrolled | Nobody is locked out forever. |
| D | Reading progress is saved on every page change (debounced), on exit, and when the app goes to the background | Protects against crashes. |

Legacy strings are kept **exactly**. This includes the trailing `"` in 「先不要好了 OwO"」, the toast 「閱讀方向改為橫向 / 直向」 (no added prefix), and the status formats 「當前:12 總共:40」 / 「當前:12 卡在:13」 / 「讀取中」.

## Visual language

- **Accent 萌粉**: `#D12F6A` in light mode, `#FF7AA8` in dark mode. It is used as the app tint and for the one prominent action per screen.
- **Canvas / cards**: grouped background colours. Cards have radius 22 with the cover at radius 12 (concentric). Cards get a soft shadow in light mode and a hairline stroke in dark mode.
- **Categories**: a dot in the legacy colour and a 16% tinted capsule, with the name in the category's ink colour.
- **Liquid Glass**: only on the tab bar, toolbars, bottom accessory, reader bottom bar, page pill, toasts, HUD and the lock button. Content (cards, covers, pages) never gets glass. Buttons inside sheets are bordered, never glass.
- **Discretion**: always-visible surfaces never show cover or page images. These are the accessory, toasts, the lock and privacy shield, and share previews.
- **Voice**: kaomoji use `.fontDesign(.rounded)` and are hidden from VoiceOver. Spoken labels drop the kaomoji.
- **Motion**: the cover zooms into the reader, or cross-fades when Reduce Motion is on. Numbers use `.numericText()` transitions. Haptics fire for selection, download start and finish, and unlock success or failure.

## Information architecture

`TabView` (`.sidebarAdaptable`, `.tabBarMinimizeBehavior(.onScrollDown)`) with four tabs:

- **列表** `list.bullet.rectangle.portrait`
- **歷史** `clock.arrow.circlepath`
- **下載** `arrow.down.circle`, with a badge for active downloads
- **設定** `gearshape`

Search stays a trailing toolbar button on 列表, as in 3.x. There is no search tab.

| From | To | How |
|---|---|---|
| Card (列表) | 作品卡 | sheet (medium / large) |
| Card (歷史 / 下載) | Reader | push, zoom transition |
| 作品卡 | 相關字詞 | push inside the sheet |
| 作品卡 「我要現在看」 | Reader | dismiss the sheet, then push |
| 列表 🔍 | 搜尋 | sheet, zooming out of the button |
| 列表 Ex / 設定 | Ex web login | sheet |
| 設定 | ExKey login | sheet |
| 設定 | diagnostic web pages | push |

The **lock** lives in its own `UIWindow` above everything, including sheets.

## Screens (summary)

- **列表**
  - Toolbar: 「Ex」 (leading, shown only when not logged in) and 🔍 (trailing).
  - Filter summary row: a site chip, then chips for non-default filters, each with ✕. When no filter is set, a default chip reads 「全部作品 · 點我設定搜尋條件」.
  - Cards, in reading order: cover on the left; title (3 lines); category chip and language pill; 「N 頁 · size」; bottom-left state slot (DL: 42 % / ✓ 已下載 / 看到 12/40); bottom-right ★ rating.
  - States: loading, empty, network error, sad panda, next-page error and end of list.
  - Gestures: pull to refresh, context menu, leading swipe to 下載.
- **作品卡**
  - Header: cover, both titles, chips and stars.
  - Stat strip: pages, size, posted date.
  - 「O3O 這部作品有 N 頁呦」, followed by the actions: 我要現在看 (becomes 繼續從 N 頁看起 plus 我要從頭看 when read before), 我要下載 (turns into 下載中 42% and then ✓ 已下載), 用相關字詞搜尋, 都不要 O3O.
  - Large detent: uploader, and tags grouped by namespace as menus.
- **Reader**
  - Vertical mode renders the contiguous run of ready pages plus a 「第 N 頁載入中...」 tail, so nothing ever jumps. Horizontal mode pages.
  - Top bar: title, with the legacy status under it.
  - Glass bottom bar: mode toggle, scrubber with a buffer track, 「12 / 40」.
  - Tap toggles the chrome. When the chrome is hidden, a page pill shows the current page.
  - Resume banner 「您曾經閱讀過此作品」: 繼續從 N 頁看起 / 我要從頭看.
  - Missing gallery shows 「這部作品好像不見囉」. If downloaded, local pages still open.
  - Long-press on a page: 分享這頁 · 儲存到照片 · 放大看 (QuickLook) · 重新載入這頁.
  - Toolbar: download → progress ring → trash (legacy confirmation), share, and an overflow menu (閱讀方向, 跳到第幾頁…, 回到第 1 頁, 作品資訊).
- **搜尋**
  - Sections in legacy order: 手動輸入關鍵字 / 只搜尋固定語言 (不限 | 中文 | 原汁原味不翻譯) / 從近期標題選取 / 從近期 Tag 選取 / 評分要求 / 作品類別 (10 tiles, 全選 · 反選).
  - 「將搜尋：」 preview.
  - Guard: 好 is disabled when no category is selected.
- **相關字詞**: 英文名稱切碎 / 日文名稱切碎 / Tags, with a glass preview bar. 好 searches in 列表.
- **歷史**
  - `.searchable`, a 繼續看 shelf, and 今天 / 昨天 / 本週 / 更早 sections.
  - Swipe actions: 刪除紀錄 and 下載.
  - Clearing all history asks for confirmation, then shows a HUD 「作品刪除中 ( i / n )」.
- **下載**: 共 N 部 · size, then 下載中 and 已下載 sections, with live progress. The footnote explains that the screen stays awake while downloading.
- **設定**
  - App 狀態: the four tests (the API row shows 不知道 on a parse failure), Ex status, 用網頁登入 Ex, ExKey 登錄, 「Ex 登入整個失敗 還是只有熊貓 點我登出」.
  - 用量: stacked bar, 歷史 / 下載 「12.3 MB (45)」, 清除所有觀看紀錄.
  - 觀看習慣: 滑動方向切換, 點列表作品時先跳出作品卡.
  - 隱私設定: App 上鎖 (legacy dialog, then one biometric check), 切換 App 時遮住畫面.
  - 關於.
- **Lock**
  - Opaque mascot screen reading 「使用這個 App 需要先解鎖呦」.
  - It prompts automatically once. A glass 解鎖 button retries after a failure.
  - It never quits the app. It shows lockout copy when biometrics are locked out, and falls back to the passcode when biometrics are no longer enrolled.
