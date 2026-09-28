import DaiHentaiCore
import QuickLook
import SwiftUI

struct ReaderView: View {
    let route: ReaderRoute

    @Environment(AppModel.self) private var app
    @State private var reader: ReaderModel?

    var body: some View {
        Group {
            if let reader {
                ReaderContent(reader: reader)
            } else {
                Color.black
            }
        }
        .onAppear {
            if reader == nil { reader = ReaderModel(route: route, app: app) }
        }
    }
}

private struct ReaderContent: View {
    let reader: ReaderModel

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var containerSize: CGSize = .zero
    /// The scroll view's own visible size. It runs under the bars (vertical safe area) but not under
    /// a landscape iPad's sidebar; `containerSize` is only a fallback until it has been measured.
    @State private var viewport: CGSize = .zero
    @State private var isConfirmingDelete = false
    @State private var isAskingPage = false
    @State private var pageInput = ""
    @State private var quickLookURL: URL?
    @State private var isShowingNotFound = false
    @FocusState private var isFocused: Bool

    private var gallery: GalleryInfo { reader.gallery }
    private var phase: GalleryDownloader.Phase { reader.downloader?.phase ?? .loading }

    var body: some View {
        ZStack {
            readerBackground
                .ignoresSafeArea()
            // The same box the pages get: under the bars, beside the sidebar.
            Color.clear
                .ignoresSafeArea(edges: .vertical)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
                .allowsHitTesting(false)
            pages
            overlays
        }
        .navigationTitle(gallery.bestTitle)
        .navigationSubtitle(reader.statusText)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbarVisibility(reader.isChromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar { toolbar }
        .onAppear {
            reader.appear()
            app.router.visibleReaders += 1
            isFocused = true
        }
        .onDisappear {
            reader.disappear()
            app.router.visibleReaders = max(0, app.router.visibleReaders - 1)
            app.router.hidesSystemOverlays = false
        }
        .onChange(of: reader.isChromeVisible) { _, visible in
            app.router.hidesSystemOverlays = !visible
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { reader.saveNow() }
        }
        .onChange(of: reader.scrollRequest) { _, request in
            guard let request else { return }
            Task { await settle(on: request.page, anchor: request.anchor, animated: request.animated) }
        }
        .onChange(of: phase) { _, phase in
            if phase == .notFound, !reader.isDeleted { isShowingNotFound = true }
        }
        .onChange(of: reader.downloader?.readyCount) {
            reader.checkPrepend()
            reader.requestAround()
        }
        .onChange(of: containerSize.width) { old, new in
            // Rotation: stay on the same page.
            guard old > 0, old != new else { return }
            reader.keepCurrentPage()
        }
        .alert(Text(verbatim: "O3O"), isPresented: $isShowingNotFound) {
            Button(.commonOkayPlain) { app.router.popReader(of: gallery) }
        } message: {
            Text(.readerNotFound)
        }
        .alert(Text(verbatim: "O3O"), isPresented: $isConfirmingDelete) {
            Button(.commonOkayHappy, role: .destructive) { reader.delete() }
            Button(.commonNotNow, role: .cancel) {}
        } message: {
            Text(.commonConfirmDeleteGallery)
        }
        .alert(Text(.readerGoToPageTitle), isPresented: $isAskingPage) {
            TextField(String("1 – \(reader.pageCount)"), text: $pageInput)
                .keyboardType(.numberPad)
            Button(.commonOkay) {
                if let page = Int(pageInput) { reader.jump(to: page - 1) }
                pageInput = ""
            }
            Button(.commonCancel, role: .cancel) { pageInput = "" }
        }
        .quickLookPreview($quickLookURL)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.rightArrow, .downArrow, .space, .pageDown]) { _ in
            reader.jump(to: reader.currentPage + 1, animated: true)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .upArrow, .pageUp]) { _ in
            reader.jump(to: reader.currentPage - 1, animated: true)
            return .handled
        }
        .sensoryFeedback(.impact(weight: .light), trigger: reader.direction)
    }

    /// Scrolls, then repeats while the lazy stack lays out its estimated rows, then lets the
    /// scroll offset drive `currentPage` again.
    private func settle(on page: Int, anchor: UnitPoint = .top, animated: Bool = false) async {
        // No scroll view yet (still 讀取中): the pages' `.task` applies it when they appear.
        guard showsPages else { return }
        if animated {
            withAnimation(.smooth) { scroll(to: page, anchor: anchor) }
            reader.scrollSettled(on: page)
            return
        }
        scroll(to: page, anchor: anchor)
        for delay in [0, 60, 180] {
            if delay == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard reader.pendingScroll == page else { return }
            scroll(to: page, anchor: anchor)
        }
        reader.scrollSettled(on: page)
    }

    /// Scrolls to a page. A vertical page that isn't laid out yet is the loading row, which moves as
    /// pages arrive, so scroll to an edge instead of following it.
    private func scroll(to page: Int, anchor: UnitPoint = .top) {
        if reader.direction == .vertical, page >= reader.runEnd {
            position.scrollTo(edge: page == reader.runStart ? .top : .bottom)
        } else {
            position.scrollTo(id: page, anchor: anchor)
        }
    }

    /// A jump asked for before these pages were on screen (resume, 繼續看, direction switch) lands once they are.
    private func applyPendingScroll() async {
        guard let page = reader.pendingScroll else { return }
        await settle(on: page)
    }

    private var readerBackground: Color {
        colorScheme == .dark ? .black : Color(uiColor: .systemBackground)
    }

    // MARK: - Pages

    private var showsPages: Bool {
        phase != .failed && reader.pageCount > 0 && !(phase == .loading && reader.downloader?.readyCount == 0)
    }

    @ViewBuilder
    private var pages: some View {
        if phase == .failed {
            KaomojiState(kaomoji: "O口O", title: .commonNetworkError, message: .readerNoPagesMessage) {
                Button(.commonTryAgain) { reader.retry() }
                    .buttonStyle(.borderedProminent)
            }
        } else if reader.pageCount == 0 || (phase == .loading && reader.downloader?.readyCount == 0) {
            VStack(spacing: 12) {
                ProgressView()
                Text(.readerLoading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if reader.direction == .vertical {
            verticalPages
        } else {
            horizontalPages
        }
    }

    private var screen: CGSize { viewport == .zero ? containerSize : viewport }
    private var pageWidth: CGFloat { min(screen.width, 1000) }
    private var centerLine: CGFloat { screen.height / 2 }

    private var verticalPages: some View {
        let end = reader.runEnd
        // Captured as a value: geometry transforms are Sendable closures.
        let line = centerLine
        return ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                if reader.runStart > 0 {
                    EarlierPagesRow(first: reader.runStart, isLoading: reader.isLoadingEarlierPages) {
                        reader.loadEarlierPages()
                    }
                    .frame(height: ReaderModel.headerHeight)
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.frame(in: .scrollView).maxY > 0
                    } action: { visible in
                        reader.earlierRowVisibilityChanged(visible)
                    }
                    .id(-1)
                }
                ForEach(reader.runStart..<end, id: \.self) { page in
                    pageView(page, size: CGSize(width: pageWidth, height: pageWidth * reader.aspectRatio(of: page)))
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: Bool.self) { proxy in
                            // The page under the middle of the screen is the current one, as in 3.x.
                            let frame = proxy.frame(in: .scrollView)
                            return frame.minY <= line && frame.maxY > line
                        } action: { isCentered in
                            if isCentered { reader.pageReachedCenter(page) }
                        }
                        .id(page)
                }
                if end < reader.pageCount {
                    LoadingPageRow(page: end, state: reader.state(of: end)) {
                        reader.downloader?.request([end])
                    }
                    .frame(height: max(240, screen.height * 0.6))
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.frame(in: .scrollView).minY <= line
                    } action: { reached in
                        if reached { reader.pageReachedCenter(end) }
                    }
                    // Never reuse a page's id: the row would be recycled as that page later.
                    .id(ReaderModel.tailID)
                } else {
                    EndRow()
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .vertical)
        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in viewport = size }
        .task { await applyPendingScroll() }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { reader.userDidScroll() }
        }
        .onTapGesture { reader.toggleChrome() }
    }

    private var horizontalPages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(0..<reader.pageCount, id: \.self) { page in
                    Group {
                        if reader.isReady(page) {
                            pageView(page, size: screen)
                        } else {
                            LoadingPageRow(page: page, state: reader.state(of: page)) {
                                reader.downloader?.request([page])
                            }
                        }
                    }
                    .frame(width: screen.width, height: screen.height)
                    .id(page)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .vertical)
        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in viewport = size }
        .task(id: screen.width > 0) { await applyPendingScroll() }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x
        } action: { _, offset in
            reader.updateHorizontal(offsetX: offset, pageWidth: screen.width)
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { reader.userDidScroll() }
        }
        .onTapGesture { reader.toggleChrome() }
    }

    @ViewBuilder
    private func pageView(_ page: Int, size: CGSize) -> some View {
        if let url = reader.fileURL(forPage: page) {
            PageImage(fileURL: url, targetSize: size, version: reader.version(of: page))
                .frame(width: size.width, height: size.height)
                .contentShape(.rect)
                .contextMenu { pageMenu(page, url: url) }
                .accessibilityLabel(.commonPageNumber(page + 1))
                .accessibilityAddTraits(.isImage)
        }
    }

    @ViewBuilder
    private func pageMenu(_ page: Int, url: URL) -> some View {
        ShareLink(item: SharedPage(fileURL: url, title: gallery.bestTitle, page: page + 1), preview: SharePreview(String(localized: .commonPageNumber(page + 1)), image: Image(systemName: "photo"))) {
            Label(.readerSharePage, systemImage: "square.and.arrow.up")
        }
        Button(.readerSaveToPhotos, systemImage: "square.and.arrow.down") {
            Task {
                guard let copy = await PageExport.exportedCopy(of: url, title: gallery.bestTitle, page: page + 1) else { return }
                switch await PageExport.saveToPhotos(copy) {
                case .saved: app.toasts.show(.readerSaved, kaomoji: "O3Ob", symbol: "checkmark.circle.fill")
                case .denied: app.toasts.show(.readerPhotosDenied, kaomoji: "O口O")
                case .failed: app.toasts.show(.readerSaveFailed, kaomoji: "O口O")
                }
            }
        }
        Button(.readerViewFullSize, systemImage: "arrow.up.left.and.arrow.down.right") {
            Task { quickLookURL = await PageExport.exportedCopy(of: url, title: gallery.bestTitle, page: page + 1) }
        }
        Button(.readerReloadPage, systemImage: "arrow.clockwise") {
            reader.reload(page: page)
        }
    }

    // MARK: - Overlays

    private var overlays: some View {
        VStack(spacing: 0) {
            if let page = reader.resumeOffer, phase != .notFound {
                ResumeBanner(page: page, resume: reader.acceptResume, fromStart: reader.declineResume)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if reader.pageCount > 0, phase != .failed {
                if reader.isChromeVisible {
                    ReaderBottomBar(reader: reader)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    PagePill(page: reader.currentPage + 1, count: reader.pageCount)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: reader.isChromeVisible)
        .animation(.smooth, value: reader.resumeOffer)
    }

    // MARK: - Toolbar

    /// Only downloading stays in the bar (「我要下載」, then its progress); share and delete live
    /// in the ⋯ menu so the title gets the room.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !reader.isDownloaded || reader.downloader?.isDownloadingAll == true {
            ToolbarItem(placement: .topBarTrailing) {
                downloadButton
            }
        }
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Menu {
                Picker(.readerDirection, selection: Binding(get: { reader.direction }, set: { reader.setDirection($0) })) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Label(direction.title, systemImage: direction == .vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                            .tag(direction)
                    }
                }
                .pickerStyle(.inline)
                Button(.readerGoToPage, systemImage: "number") { isAskingPage = true }
                Button(.readerBackToFirst, systemImage: "arrow.up.to.line") { reader.jump(to: 0) }
                Divider()
                Button(.readerInfo, systemImage: "info.circle") {
                    app.router.galleryCard = GalleryCardRoute(gallery: gallery, showsReadActions: false)
                }
                ShareLink(item: gallery.galleryURL(on: app.site), subject: Text(gallery.bestTitle), message: Text(gallery.bestTitle)) {
                    Label(.commonShare, systemImage: "square.and.arrow.up")
                }
                if reader.isDownloaded {
                    Divider()
                    Button(.menuDeleteDownload, systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .accessibilityIdentifier("deleteButton")
                }
            } label: {
                Label(.readerMore, systemImage: "ellipsis")
            }
            .accessibilityIdentifier("readerMoreMenu")
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if let downloader = reader.downloader, downloader.isDownloadingAll {
            Button {
                isConfirmingDelete = true
            } label: {
                ProgressRing(progress: downloader.progress)
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel(.readerDownloadingAccessibility(downloader.progress.formatted(.percent.precision(.fractionLength(0)))))
            .accessibilityHint(Text(.readerDownloadingHint))
        } else {
            Button(.commonWantDownload, systemImage: "arrow.down.circle") { reader.download() }
                .accessibilityIdentifier("readerDownloadButton")
        }
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.moeAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
        }
    }
}

private struct LoadingPageRow: View {
    let page: Int
    let state: GalleryDownloader.PageState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if state == .failed {
                Kaomoji(text: "O口O", style: .title2.weight(.bold))
                    .foregroundStyle(.secondary)
                Button(.readerPageFailed(page + 1), action: retry)
                    .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text(.readerPageLoading(page + 1))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct EarlierPagesRow: View {
    let first: Int
    let isLoading: Bool
    let load: () -> Void

    var body: some View {
        Button(action: load) {
            HStack(spacing: 8) {
                if isLoading { ProgressView() } else { Image(systemName: "arrow.up") }
                Text(isLoading ? LocalizedStringResource.readerEarlierLoading : .readerLoadEarlier(first))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct EndRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(.readerEnd)
            Kaomoji(text: "O3Ob")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
