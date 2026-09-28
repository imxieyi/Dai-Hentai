# Dai-Hentai 4.0

## 總覽
這個專案是一個讓 iOS 裝置方便閱讀, 使用, 收藏 e / ex hentai 網站內容的 App, 由於該網站的內容多半是成人觀看, 如果不喜歡這些內容的話, 請勿使用 >x<, 感恩

當然, 撇開內容的部分不談, 程式碼的部分或是使用上有任何問題, 都歡迎提出指教 >w<

下面的縮圖點擊後可以導向 youtube 觀看大致上功能使用的影片

<a href="http://www.youtube.com/watch?feature=player_embedded&v=DqkIxhpzP9s
" target="_blank"><img src="http://img.youtube.com/vi/DqkIxhpzP9s/0.jpg" 
alt="newHentai" width="240" height="180" border="10" /></a>

整體的使用體驗應該會比 2.x 來的穩定跟快速, 也加上了上鎖的功能, 讓大家在使用上可以更安心一些 =w=

4.0 整個用 SwiftUI 重寫了, 但是操作的流程跟 3.x 一樣 (列表 · 歷史 · 下載 · 設定), 舊版的觀看紀錄、下載、看到第幾頁、搜尋條件跟設定, 第一次打開時會自動搬過來, 已經下載的圖片也不用重新下載 O3Ob

- 列表點作品會先跳出「作品卡」(就是以前的「O3O 這部作品有 N 頁呦」), 在設定裡可以關掉, 改成直接開始看
- 閱讀時點一下畫面可以收起工具列, 底下的滑桿可以直接跳頁, 灰色的部分是已經下載好的頁面
- 下載中或是有看到一半的作品時, 分頁列上面會出現「下載中 / 繼續看」, 一鍵回去
- 介面設計的由來請看 [docs/UI-Design.md](docs/UI-Design.md)

## Tag 中文轉換
感謝隔壁的朋友有整理好的 tag 可以查找了, 所以這邊的轉換參考內容都是從 [https://github.com/Mapaler/EhTagTranslator](https://github.com/Mapaler/EhTagTranslator) 來的, 深表感謝

字典本身是簡體中文: 簡體中文介面直接顯示, 繁體中文介面會自動轉成繁體, 英文跟日文介面就不顯示

## 語言
介面支援繁體中文 (開發語言)、簡體中文、英文、日文, 跟著系統或是「設定 > 萌萌噠 > 語言」切換

- 字串都放在 String Catalog 裡: `DaiHentaiUI` 跟 `DaiHentaiCore` 各有一份 `Resources/Localizable.xcstrings`, App 本體的 `InfoPlist.xcstrings` 放主畫面名稱跟權限說明
- key 是手動管理的 (例如 `Reader.GoToPage`), Xcode 會產生對應的 `LocalizedStringResource` symbol, 程式裡寫 `Text(.readerGoToPage)`、`Button(.commonWantDownload) { ... }`、`.commonPageCount(n)`; 在 package 裡也會自動用對 bundle
- 英文的數量字串有單複數變化 (`%lld page` / `%lld pages`)
- 顏文字 (O3O、OwO、O口O...) 在每個語言都保留

## 原生 Xcode 直接安裝方法
1. 獲取專案（兩種方法）

 - 使用 `Download ZIP` 或 `Release` 下載專案打包並解壓縮；
 - 通過 `$ git clone https://github.com/DaidoujiChen/Dai-Hentai.git` 複製專案數據庫；

2. 用 Xcode 27 以上的版本打開 **`Dai-Hentai.xcodeproj`**

  不需要 CocoaPods 了, 也沒有 `.xcworkspace` 囉, 相依的套件 (SwiftSoup) 會由 Swift Package Manager 自動下載

3. 選 `Dai-Hentai` scheme, 接上裝置或選模擬器, 按下執行

## 專案結構

```
Dai-Hentai.xcodeproj         App 本體 (只有進入點跟圖示)
Dai-HentaiUITests/           UI 測試, 會把每個畫面截圖存起來
Packages/DaiHentaiKit/       本地 Swift Package
  Sources/DaiHentaiCore/     網站解析、下載、SwiftData 資料庫、舊版資料搬家、上鎖
  Sources/DaiHentaiUI/       所有 SwiftUI 畫面
  Tests/DaiHentaiCoreTests/  單元測試
docs/UI-Design.md            4.0 介面設計
Storage.md                   資料存放方式
```

- Swift 6 語言模式, 嚴格的 concurrency 檢查全開
- 資料庫是 SwiftData (資料格式請看 [Storage.md](Storage.md))

## 展示模式與測試

啟動參數加上 `-DemoMode` 會用產生出來的假作品離線執行, 不會連到網站, 也不會動到真正的資料, 適合截圖跟測試. 另外還有 `-DemoLoggedIn`、`-DemoLocked`、`-DemoEmptyLibrary`、`-DemoDark` 可以搭配使用.

```bash
# 單元測試
cd Packages/DaiHentaiKit
xcodebuild -scheme DaiHentaiKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test

# 連到真的網站的測試 (選用)
TEST_RUNNER_DAIHENTAI_LIVE_TESTS=1 xcodebuild -scheme DaiHentaiKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test

# UI 測試 (展示模式, 每個畫面的截圖會存在 .xcresult 裡; testTourEnglish / testTourSimplifiedChinese / testTourJapanese 會用其他語言走一遍)
cd ../..
xcodebuild -project Dai-Hentai.xcodeproj -scheme Dai-Hentai -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

## Windows / Linux 不需 JB 安裝方法
後來 [VVVVictorJ](https://github.com/VVVVictorJ) 提出 Cydia Impactor 已經沒有辦法安裝囉, 可以使用 [shinrenpan](https://github.com/shinrenpan) 提到的 [AltStore](https://altstore.io/) 試試

**需要注意的一點, 這種安裝方式只有七天的賞味期喔, 需要在期限內再裝一次才行**

## 支援
- iOS 27.0 以上
- iPhone / iPad

## 最新測試版本試玩

[點我導向 appetize](https://appetize.io/embed/qk23vcyrmbtecy7n12h6118wa4?device=iphone7&scale=100&orientation=portrait&osVersion=10.0&deviceColor=white)

但是由於是免費帳號, 所以試玩一個月只有 100 分鐘的額度, 付費每一分鐘 0.05 鎂, 成本實在過高, 有玩到的人只能說有拜拜, 沒有玩到的人可以直接用下面的 IPA 檔案...如果能的話啦 O3Ob

## 最新測試版本 IPA

因為懶惰所以懶得每次一直手動發布版本, 所以用了一個自動生產 ipa 的服務, 會在每當有新的 commit 時運作

![](https://app.bitrise.io/app/446db4b9b316a724.svg?token=I0YMFQ8S5i30cN95ZVgvhw)

^^^^^^^^^^^^^ 上面這串文字為 `Bitrise Passing` 時, 可以取得最新的版本

版本的識別由兩個部分組合而成, 都在 `Dai-Hentai.xcodeproj` 的 Build Settings 裡
  * 版本號: `MARKETING_VERSION`
  * Build號: `CURRENT_PROJECT_VERSION`

可以組成如下的網址

```
https://s3-ap-northeast-1.amazonaws.com/dai-hentai-ipa/bitrise/{版本號}_{Build號}/Dai-Hentai.ipa
```

以當前編譯文件時的範例網址為 `https://s3-ap-northeast-1.amazonaws.com/dai-hentai-ipa/bitrise/1.0_201703090649/Dai-Hentai.ipa`

## 1 鎂捐獻箱
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=N86FK92G3V4BS)
<img alt="" border="0" src="https://www.paypalobjects.com/zh_TW/i/scr/pixel.gif" width="1" height="1">

[捐獻紀錄表](https://docs.google.com/spreadsheets/d/17eY6Hi2Ol-tbb3pL11yRoAg6SeNKa-plj4VJvSuPQY8/edit#gid=0)
