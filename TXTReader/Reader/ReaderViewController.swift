import UIKit
import SwiftUI
import Combine

/// 单页内容控制器（供仿真翻页 UIPageViewController 使用）
final class ReaderContentViewController: UIViewController {
    let chapterIndex: Int
    let pageIndex: Int
    private let page: PageModel
    private let readRect: CGRect
    private let pageBackground: UIColor
    private let pageView = ReaderPageView()

    init(page: PageModel, readRect: CGRect, pageBackground: UIColor) {
        self.page = page
        self.chapterIndex = page.chapterIndex
        self.pageIndex = page.pageIndex
        self.readRect = readRect
        self.pageBackground = pageBackground
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageBackground
        pageView.backgroundColor = pageBackground
        pageView.content = page.content
        view.addSubview(pageView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pageView.frame = readRect
    }
}

/// 阅读器主控制器
final class ReaderViewController: UIViewController {

    private let viewModel: ReaderViewModel
    private let settings: ReaderSettings
    private let progressStore: ReadingProgressStore
    private var cancellables = Set<AnyCancellable>()
    private let speech = SpeechService()
    private weak var speechButton: UIButton?

    private let backgroundView = UIView()
    private let pageContainer = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let titleLabel = UILabel()
    private let pageLabel = UILabel()
    private let progressLabel = UILabel()

    // 翻页容器
    private var pageViewController: UIPageViewController?
    private var frontView: ReaderPageView?
    private var incomingView: ReaderPageView?
    private var scrollView: UIScrollView?
    private var panGesture: UIPanGestureRecognizer?

    private enum PanState {
        case idle
        case dragging(forward: Bool, chapter: Int, page: Int)
    }
    private var panState: PanState = .idle

    /// 连续滚动模式下的一个分页切片（按内容高度紧贴堆叠，滚动不再按页吸附）
    private struct ContinuousBlock {
        let chapter: Int
        let page: Int
        let top: CGFloat
        let height: CGFloat
        var bottom: CGFloat { top + height }
    }
    private var scrollBlocks: [ContinuousBlock] = []
    /// 当前已构建的居中章节（跨章后据此补齐新的前后章）
    private var builtCenterChapter = -1
    /// 连续滚动下视口顶部对应的章内字符偏移（比页码精确）
    private var currentCharOffsetInChapter = 0
    /// 连续滚动前后各缓冲的页数（跨章，保证章末能继续滚动、章首能滚到顶）
    private let scrollBufferPages = 3
    /// 是否已安排一次连续滚动重建，避免滚动过程中重复触发
    private var continuousReloadScheduled = false
    /// 上一次实际生效的翻页方式（用于跨模式的位置锚定）
    private var appliedStyle: PageTurnStyle?

    // 底部菜单（跟随阅读主题配色，不晃眼）
    private let menuBar = UIView()
    private let menuProgressLabel = UILabel()
    private let menuSlider = UISlider()
    private let menuStack = UIStackView()
    private var menuButtons: [UIButton] = []
    private var isMenuVisible = false

    // 目录侧边栏
    private let sidebarDim = UIView()
    private var sidebarContainer: UIView?
    private var sidebarHost: UIViewController?

    private var currentChapter = 0
    private var currentPage = 0
    private var didSetup = false
    private var readRect: CGRect = .zero

    /// 无动画模式的左右滑动手势
    private var swipeGestures: [UISwipeGestureRecognizer] = []
    /// 已触发过预取的章节，避免重复入队
    private var lastPrefetchedChapter = -1
    /// 启动时待恢复的全文偏移（readRect 就绪后用于精确定位）
    private var pendingCharOffset: Int?
    /// 在线缓存进度提示（为空表示本地书或缓存完成）
    private var cacheText = ""
    private var cacheObserver: NSObjectProtocol?
    /// 滚动过程中收到新缓存内容时，等停止后再补齐
    private var pendingContentRefresh = false

    init(book: Book, chapters: [Chapter], settings: ReaderSettings, progressStore: ReadingProgressStore) {
        self.viewModel = ReaderViewModel(book: book, chapters: chapters, typography: settings.typography)
        self.settings = settings
        self.progressStore = progressStore
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }

    private var theme: ReaderTheme {
        if settings.followSystemTheme, traitCollection.userInterfaceStyle == .dark {
            return ReaderTheme.theme(at: 1)
        }
        return ReaderTheme.theme(at: settings.typography.themeIndex)
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupChrome()
        setupMenu()
        bindSettings()
        appliedStyle = settings.style
        restoreProgress()
        setupTapGesture()
        observeOnlineCache()
    }

    deinit {
        if let cacheObserver { NotificationCenter.default.removeObserver(cacheObserver) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backgroundView.frame = view.bounds
        pageContainer.frame = view.bounds
        layoutBars()
        layoutMenu()

        let rect = ReaderLayout.readRect(in: view.bounds,
                                         safeTop: view.safeAreaInsets.top,
                                         safeBottom: view.safeAreaInsets.bottom,
                                         margin: settings.typography.margin)
        guard !didSetup, rect.width > 0, rect.height > 0 else { return }
        didSetup = true
        readRect = rect
        viewModel.readRect = rect
        applyPendingCharOffset()
        rebuildPager()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeepScreenOn()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        stopSpeech()
        saveProgress()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard settings.followSystemTheme,
              previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyTheme()
        rebuildPager()
    }

    private func applyKeepScreenOn() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
    }

    // MARK: - UI

    private func setupChrome() {
        backgroundView.frame = view.bounds
        view.addSubview(backgroundView)

        pageContainer.frame = view.bounds
        view.addSubview(pageContainer)

        topBar.backgroundColor = .clear
        bottomBar.backgroundColor = .clear
        view.addSubview(topBar)
        view.addSubview(bottomBar)

        titleLabel.font = .systemFont(ofSize: 12)
        pageLabel.font = .systemFont(ofSize: 12)
        progressLabel.font = .systemFont(ofSize: 12)
        topBar.addSubview(titleLabel)
        bottomBar.addSubview(pageLabel)
        bottomBar.addSubview(progressLabel)
        applyTheme()
    }

    private func layoutBars() {
        let top = view.safeAreaInsets.top
        let bottom = view.safeAreaInsets.bottom
        topBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + 30)
        bottomBar.frame = CGRect(x: 0, y: view.bounds.height - bottom - 30,
                                 width: view.bounds.width, height: bottom + 30)
        titleLabel.frame = CGRect(x: 20, y: top + 6, width: view.bounds.width - 40, height: 18)
        pageLabel.frame = CGRect(x: 20, y: 6, width: 160, height: 18)
        progressLabel.frame = CGRect(x: view.bounds.width - 180, y: 6, width: 160, height: 18)
        progressLabel.textAlignment = .right
    }

    private func applyTheme() {
        backgroundView.backgroundColor = theme.background
        let muted = theme.textColor.withAlphaComponent(0.6)
        titleLabel.textColor = muted
        pageLabel.textColor = muted
        progressLabel.textColor = muted
        scrollView?.backgroundColor = theme.background

        // 菜单与主题保持一致，避免纯白/纯黑晃眼
        menuBar.backgroundColor = theme.background.withAlphaComponent(0.96)
        menuBar.layer.borderWidth = 0.5
        menuBar.layer.borderColor = theme.textColor.withAlphaComponent(0.15).cgColor
        menuProgressLabel.textColor = theme.textColor.withAlphaComponent(0.65)
        for button in menuButtons {
            button.setTitleColor(theme.textColor, for: .normal)
        }
        menuSlider.minimumTrackTintColor = theme.textColor.withAlphaComponent(0.85)
        menuSlider.maximumTrackTintColor = theme.textColor.withAlphaComponent(0.20)
        menuSlider.thumbTintColor = theme.textColor
    }

    private func updateStatus() {
        guard viewModel.chapters.indices.contains(currentChapter) else { return }
        let chapter = viewModel.chapters[currentChapter]
        let pages = viewModel.buildPages(forChapter: currentChapter)
        titleLabel.text = cacheText.isEmpty ? chapter.title : "\(chapter.title)  ·  \(cacheText)"
        pageLabel.text = "第 \(currentPage + 1)/\(max(1, pages.count)) 页"
        progressLabel.text = "\(currentPercent())%"
        updateMenuProgress()
        prefetchAdjacentChapters()
    }

    /// 当前阅读百分比：连续滚动按精确字符偏移，分页模式按页码起点
    private func currentPercent() -> Int {
        guard viewModel.chapters.indices.contains(currentChapter) else { return 0 }
        if settings.style == .verticalScroll {
            let absolute = viewModel.chapters[currentChapter].start + currentCharOffsetInChapter
            let total = max(1, viewModel.book.totalChars)
            return Int(min(1.0, Double(absolute) / Double(total)) * 100)
        }
        return Int(viewModel.makeRecord(chapterIndex: currentChapter,
                                        pageIndex: currentPage).percent * 100)
    }

    // MARK: - 菜单

    private func setupMenu() {
        menuBar.layer.cornerRadius = 14
        menuBar.clipsToBounds = true
        menuBar.alpha = 0
        menuBar.isHidden = true
        view.addSubview(menuBar)

        menuProgressLabel.font = .systemFont(ofSize: 13, weight: .medium)
        menuProgressLabel.textAlignment = .center
        menuBar.addSubview(menuProgressLabel)

        menuSlider.minimumValue = 0
        menuSlider.maximumValue = 1
        menuSlider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        menuSlider.addTarget(self, action: #selector(sliderEnded(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        menuBar.addSubview(menuSlider)

        menuStack.axis = .horizontal
        menuStack.distribution = .fillEqually
        menuStack.alignment = .fill
        menuStack.spacing = 0
        menuBar.addSubview(menuStack)

        menuStack.addArrangedSubview(makeMenuButton("目录", #selector(menuChapters)))
        menuStack.addArrangedSubview(makeMenuButton("搜索", #selector(menuSearch)))
        let speak = makeMenuButton("朗读", #selector(menuSpeech))
        speechButton = speak
        menuStack.addArrangedSubview(speak)
        menuStack.addArrangedSubview(makeMenuButton("上一章", #selector(menuPrevChapter)))
        menuStack.addArrangedSubview(makeMenuButton("下一章", #selector(menuNextChapter)))
        menuStack.addArrangedSubview(makeMenuButton("设置", #selector(menuSettings)))
    }

    private func makeMenuButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
        menuButtons.append(button)
        return button
    }

    private func layoutMenu() {
        let width = min(view.bounds.width - 40, 340)
        let height: CGFloat = 118
        let y = view.bounds.height - view.safeAreaInsets.bottom - 30 - height - 12
        menuBar.frame = CGRect(x: (view.bounds.width - width) / 2, y: y, width: width, height: height)
        menuProgressLabel.frame = CGRect(x: 0, y: 8, width: width, height: 20)
        menuSlider.frame = CGRect(x: 16, y: 34, width: width - 32, height: 24)
        menuStack.frame = CGRect(x: 0, y: 66, width: width, height: 48)
    }

    private func updateMenuProgress() {
        guard viewModel.chapters.indices.contains(currentChapter) else { return }
        let percent = currentPercent()
        menuProgressLabel.text = "阅读进度 \(percent)%"
        if !menuSlider.isTracking {
            menuSlider.value = Float(percent) / 100
        }
    }

    @objc private func sliderChanged(_ slider: UISlider) {
        menuProgressLabel.text = "阅读进度 \(Int(slider.value * 100))%"
    }

    @objc private func sliderEnded(_ slider: UISlider) {
        jumpToProgress(slider.value)
    }

    private func jumpToProgress(_ value: Float) {
        let total = max(1, viewModel.book.totalChars)
        let offset = Int(Double(value) * Double(total))
        let chapter = viewModel.chapterIndex(forCharOffset: offset)
        let page = viewModel.pageIndex(forCharOffset: offset, chapterIndex: chapter)
        currentChapter = chapter
        currentPage = page
        currentCharOffsetInChapter = max(0, offset - viewModel.chapters[chapter].start)
        rebuildPager()
        updateStatus()
        saveProgress()
    }

    private func toggleMenu() {
        isMenuVisible.toggle()
        if isMenuVisible {
            updateMenuProgress()
            menuBar.isHidden = false
            UIView.animate(withDuration: 0.2) { self.menuBar.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.2) {
                self.menuBar.alpha = 0
            } completion: { _ in
                self.menuBar.isHidden = true
            }
        }
    }

    @objc private func menuChapters() {
        if isMenuVisible { toggleMenu() }
        showSidebar(startInSearch: false)
    }

    @objc private func menuSearch() {
        if isMenuVisible { toggleMenu() }
        showSidebar(startInSearch: true)
    }

    @objc private func menuPrevChapter() {
        jumpToChapter(currentChapter - 1)
    }

    @objc private func menuNextChapter() {
        jumpToChapter(currentChapter + 1)
    }

    @objc private func menuSettings() {
        if isMenuVisible { toggleMenu() }
        presentSettings()
    }

    // MARK: - 语音朗读

    @objc private func menuSpeech() {
        if speech.isSpeaking || speech.isPaused {
            stopSpeech()
        } else {
            startSpeech()
        }
    }

    private func startSpeech() {
        speech.onFinishUtterance = { [weak self] in self?.advanceForSpeech() }
        speechButton?.setTitle("停止", for: .normal)
        speakCurrentPage()
    }

    private func stopSpeech() {
        speech.stop()
        speech.onFinishUtterance = nil
        speechButton?.setTitle("朗读", for: .normal)
    }

    private func speakCurrentPage() {
        let pages = viewModel.buildPages(forChapter: currentChapter)
        guard pages.indices.contains(currentPage) else {
            stopSpeech()
            return
        }
        speech.speak(pages[currentPage].content.string)
    }

    /// 读完一页后自动翻页续读
    private func advanceForSpeech() {
        guard speech.isSpeaking || speech.isPaused else { return }
        let pages = viewModel.buildPages(forChapter: currentChapter)
        let hasNext = (currentPage + 1 < pages.count) || (currentChapter + 1 < viewModel.chapters.count)
        guard hasNext else {
            stopSpeech()
            return
        }
        goNext()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.speakCurrentPage()
        }
    }

    // MARK: - 目录侧边栏

    private func showSidebar(startInSearch: Bool) {
        guard sidebarContainer == nil else { return }
        viewModel.preloadText() // 预热全文，供后台搜索
        let width = min(view.bounds.width * 0.8, 360)

        let container = UIView(frame: CGRect(x: -width, y: 0, width: width, height: view.bounds.height))
        container.backgroundColor = theme.background
        container.layer.cornerRadius = 16
        container.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        container.clipsToBounds = true
        view.addSubview(container)

        sidebarDim.frame = view.bounds
        sidebarDim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        sidebarDim.alpha = 0
        sidebarDim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeSidebar)))
        view.insertSubview(sidebarDim, belowSubview: container)

        let root = ReaderSidebarView(chapters: viewModel.chapters,
                                     currentIndex: currentChapter,
                                     backgroundColor: Color(uiColor: theme.background),
                                     textColor: Color(uiColor: theme.textColor),
                                     accentColor: .accentColor,
                                     startInSearch: startInSearch,
                                     onSelectChapter: { [weak self] index in
                                         self?.closeSidebar()
                                         self?.jumpToChapter(index)
                                     },
                                     onSelectOffset: { [weak self] offset in
                                         self?.closeSidebar()
                                         self?.jumpToOffset(offset)
                                     },
                                     searchProvider: { [weak self] keyword in
                                         self?.viewModel.search(keyword) ?? []
                                     })
        let host = UIHostingController(rootView: root)
        host.overrideUserInterfaceStyle = theme.id == 1 ? .dark : .light
        host.view.backgroundColor = theme.background
        addChild(host)
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host.view)
        host.didMove(toParent: self)

        sidebarContainer = container
        sidebarHost = host

        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            container.frame.origin.x = 0
            self.sidebarDim.alpha = 1
        }
    }

    @objc private func closeSidebar() {
        guard let container = sidebarContainer else { return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn], animations: {
            container.frame.origin.x = -container.frame.width
            self.sidebarDim.alpha = 0
        }, completion: { _ in
            self.sidebarHost?.willMove(toParent: nil)
            self.sidebarHost?.view.removeFromSuperview()
            self.sidebarHost?.removeFromParent()
            self.sidebarHost = nil
            container.removeFromSuperview()
            self.sidebarContainer = nil
            self.sidebarDim.removeFromSuperview()
        })
    }

    // MARK: - 设置绑定

    private func bindSettings() {
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyReaderSettings() }
            }
            .store(in: &cancellables)
    }

    /// 设置变化：排版变了要重排；翻页方式变了要重建容器。两者都按字符偏移锚定位置。
    private func applyReaderSettings() {
        let anchor = currentAnchorCharOffset()
        let typographyChanged = viewModel.typography != settings.typography
        let styleChanged = appliedStyle != settings.style
        appliedStyle = settings.style

        if !typographyChanged {
            if styleChanged {
                restorePosition(anchor: anchor)
                applyTheme()
                applyKeepScreenOn()
                rebuildPager()
            } else {
                applyTheme()
                applyKeepScreenOn()
            }
            return
        }

        viewModel.typography = settings.typography

        // 页边距变化会改变可视区域，这里一起更新
        let rect = ReaderLayout.readRect(in: view.bounds,
                                         safeTop: view.safeAreaInsets.top,
                                         safeBottom: view.safeAreaInsets.bottom,
                                         margin: settings.typography.margin)
        if rect.width > 0, rect.height > 0 {
            readRect = rect
            viewModel.readRect = rect
        }

        viewModel.invalidatePagination()
        lastPrefetchedChapter = -1   // 缓存已失效，允许重新预取
        restorePosition(anchor: anchor)
        applyTheme()
        applyKeepScreenOn()
        rebuildPager()
    }

    /// 取当前阅读位置的精确字符偏移（连续滚动用视口顶部偏移，其余用页码范围起点）
    private func currentAnchorCharOffset() -> Int {
        guard viewModel.chapters.indices.contains(currentChapter) else { return 0 }
        if appliedStyle == .verticalScroll {
            return viewModel.chapters[currentChapter].start + currentCharOffsetInChapter
        }
        return viewModel.makeRecord(chapterIndex: currentChapter, pageIndex: currentPage).charOffset
    }

    /// 用字符偏移把 currentPage / currentCharOffsetInChapter 对齐到新排版
    private func restorePosition(anchor: Int) {
        guard viewModel.chapters.indices.contains(currentChapter) else { return }
        currentPage = viewModel.pageIndex(forCharOffset: anchor, chapterIndex: currentChapter)
        currentCharOffsetInChapter = max(0, anchor - viewModel.chapters[currentChapter].start)
    }

    /// 用上次保存的字符偏移精确定位（页码随排版变化，偏移不会）
    private func applyPendingCharOffset() {
        guard let offset = pendingCharOffset else { return }
        pendingCharOffset = nil
        guard !viewModel.chapters.isEmpty else { return }
        let chapter = viewModel.chapterIndex(forCharOffset: offset)
        currentChapter = chapter
        currentPage = viewModel.pageIndex(forCharOffset: offset, chapterIndex: chapter)
        currentCharOffsetInChapter = max(0, offset - viewModel.chapters[chapter].start)
    }

    /// 提前算好前后章分页，跨章翻页时不再现算
    private func prefetchAdjacentChapters() {
        guard lastPrefetchedChapter != currentChapter else { return }
        lastPrefetchedChapter = currentChapter
        viewModel.prefetch(chapterIndex: currentChapter + 1)
        viewModel.prefetch(chapterIndex: currentChapter - 1)
    }

    // MARK: - 进度

    private func restoreProgress() {
        if let record = progressStore.load(bookId: viewModel.book.id) {
            currentChapter = min(max(0, record.chapterIndex), max(0, viewModel.chapters.count - 1))
            currentPage = max(0, record.pageIndex)
            // 页码依赖排版，真正定位等 readRect 就绪后用字符偏移重算
            pendingCharOffset = record.charOffset > 0 ? record.charOffset : nil
        }
    }

    private func saveProgress() {
        guard viewModel.chapters.indices.contains(currentChapter) else { return }
        var record = viewModel.makeRecord(chapterIndex: currentChapter, pageIndex: currentPage)
        if settings.style == .verticalScroll {
            // 连续滚动没有页，保存视口顶部的精确字符偏移
            record.charOffset = viewModel.chapters[currentChapter].start + currentCharOffsetInChapter
            let total = max(1, viewModel.book.totalChars)
            record.percent = min(1.0, Double(record.charOffset) / Double(total))
        }
        progressStore.save(record)
    }

    private func jumpToChapter(_ index: Int) {
        guard viewModel.chapters.indices.contains(index) else { return }
        currentChapter = index
        currentPage = 0
        currentCharOffsetInChapter = 0
        rebuildPager()
        updateStatus()
        saveProgress()
    }

    /// 按全文搜索结果的字符偏移跳转
    private func jumpToOffset(_ offset: Int) {
        guard !viewModel.chapters.isEmpty else { return }
        let chapter = viewModel.chapterIndex(forCharOffset: offset)
        let page = viewModel.pageIndex(forCharOffset: offset, chapterIndex: chapter)
        currentChapter = chapter
        currentPage = page
        currentCharOffsetInChapter = max(0, offset - viewModel.chapters[chapter].start)
        rebuildPager()
        updateStatus()
        saveProgress()
    }

    private func presentSettings() {
        let host = UIHostingController(rootView: ReaderSettingsView(settings: settings, speech: speech))
        host.modalPresentationStyle = .pageSheet
        host.overrideUserInterfaceStyle = theme.id == 1 ? .dark : .light
        if let presentation = host.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    // MARK: - 翻页容器

    private func rebuildPager() {
        pageViewController?.view.removeFromSuperview()
        pageViewController?.removeFromParent()
        pageViewController = nil
        scrollView?.removeFromSuperview()
        scrollView = nil
        frontView?.removeFromSuperview()
        frontView = nil
        incomingView?.removeFromSuperview()
        incomingView = nil
        panState = .idle

        if let pan = panGesture {
            pageContainer.removeGestureRecognizer(pan)
            panGesture = nil
        }
        swipeGestures.forEach { pageContainer.removeGestureRecognizer($0) }
        swipeGestures.removeAll()

        switch settings.style {
        case .curl:
            setupPageViewController()
        case .cover, .slide:
            setupHorizontal()
        case .instant:
            setupInstant()
        case .verticalScroll:
            setupScrollView()
        }
        updateStatus()
    }

    private func setupPageViewController() {
        let pvc = UIPageViewController(transitionStyle: .pageCurl,
                                       navigationOrientation: .horizontal,
                                       options: nil)
        pvc.dataSource = self
        pvc.delegate = self
        pvc.view.frame = pageContainer.bounds
        pvc.view.backgroundColor = theme.background
        addChild(pvc)
        pageContainer.addSubview(pvc.view)
        pvc.didMove(toParent: self)
        pageViewController = pvc

        if let first = makeContent(chapter: currentChapter, page: currentPage) {
            pvc.setViewControllers([first], direction: .forward, animated: false)
        }
    }

    private func setupHorizontal() {
        let front = ReaderPageView(frame: readRect)
        front.backgroundColor = theme.background
        let pages = viewModel.buildPages(forChapter: currentChapter)
        let index = min(currentPage, max(0, pages.count - 1))
        if pages.indices.contains(index) {
            front.content = pages[index].content
        }
        pageContainer.addSubview(front)
        frontView = front

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pageContainer.addGestureRecognizer(pan)
        panGesture = pan
    }

    /// 无动画：只有一张前景页，点击或滑动后直接替换内容，不做过渡动画
    private func setupInstant() {
        let front = ReaderPageView(frame: readRect)
        front.backgroundColor = theme.background
        let pages = viewModel.buildPages(forChapter: currentChapter)
        let index = min(currentPage, max(0, pages.count - 1))
        if pages.indices.contains(index) {
            front.content = pages[index].content
        }
        pageContainer.addSubview(front)
        frontView = front

        let left = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        right.direction = .right
        pageContainer.addGestureRecognizer(left)
        pageContainer.addGestureRecognizer(right)
        swipeGestures = [left, right]
    }

    private func setupScrollView() {
        let scroll = UIScrollView(frame: readRect)
        // 连续滚动：不按页吸附，文字一行行连续流动
        scroll.isPagingEnabled = false
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        scroll.backgroundColor = theme.background
        pageContainer.addSubview(scroll)
        scrollView = scroll
        reloadContinuousContent()
    }

    /// 重建连续滚动内容：以 centerChapter 为中心，跨章前后各缓冲若干页。
    /// 重建后按 anchor（视口顶部锚点）还原位置，保证滚动过程中扩充内容视觉不跳。
    private func reloadContinuousContent(centerChapter: Int? = nil,
                                         anchor: (chapter: Int, page: Int, localChar: Int)? = nil) {
        guard let scroll = scrollView else { return }
        scroll.subviews.forEach { $0.removeFromSuperview() }
        scrollBlocks.removeAll()

        let center = centerChapter ?? currentChapter
        guard viewModel.chapters.indices.contains(center) else {
            scroll.contentSize = CGSize(width: readRect.width, height: readRect.height)
            return
        }

        let centerPageCount = viewModel.buildPages(forChapter: center).count
        var items: [(chapter: Int, page: Int)] = []
        // 前缓冲：跨章往前取若干页，保证中心章首屏也能滚到顶
        items.append(contentsOf: collectPages(fromChapter: center, page: -1,
                                              forward: false, limit: scrollBufferPages).reversed())
        // 中心章全部页
        for index in 0..<centerPageCount {
            items.append((center, index))
        }
        // 后缓冲：跨章往后取若干页，保证章末能持续滚动到后续内容
        items.append(contentsOf: collectPages(fromChapter: center, page: centerPageCount,
                                              forward: true, limit: scrollBufferPages))

        let lineSpacing = settings.typography.lineSpacing
        var y: CGFloat = 0
        var previousChapter = -1
        for item in items {
            let pages = viewModel.buildPages(forChapter: item.chapter)
            guard pages.indices.contains(item.page) else { continue }
            let page = pages[item.page]

            // 上一页把某段从中间截断时，下一页顶部补一个行距，保证行距视觉均匀
            if item.page > 0, item.chapter == previousChapter, page.range.location > 0 {
                let text = viewModel.chapterText(at: item.chapter) as NSString
                if page.range.location <= text.length {
                    let prevChar = text.substring(with: NSRange(location: page.range.location - 1, length: 1))
                    if prevChar != "\n" { y += lineSpacing }
                }
            }

            let height = max(1, page.textHeight)
            let pageView = ReaderPageView(frame: CGRect(x: 0, y: y,
                                                        width: readRect.width, height: height))
            pageView.backgroundColor = theme.background
            pageView.content = page.content
            scroll.addSubview(pageView)
            scrollBlocks.append(ContinuousBlock(chapter: item.chapter, page: item.page,
                                                top: y, height: height))
            y += height
            previousChapter = item.chapter
        }

        scroll.contentSize = CGSize(width: readRect.width, height: max(readRect.height, y))
        builtCenterChapter = center

        // 以视口顶部锚点还原视觉位置（内容变了但屏幕上的那一行不动）
        let target = anchor ?? (chapter: currentChapter, page: currentPage,
                                localChar: currentCharOffsetInChapter)
        if let block = scrollBlocks.first(where: { $0.chapter == target.chapter && $0.page == target.page }) {
            let pages = viewModel.buildPages(forChapter: target.chapter)
            let range = pages.indices.contains(target.page) ? pages[target.page].range
                                                             : NSRange(location: 0, length: 0)
            let fraction = range.length > 0
                ? min(1, max(0, CGFloat(target.localChar - range.location) / CGFloat(range.length)))
                : 0
            scroll.setContentOffset(CGPoint(x: 0, y: block.top + block.height * fraction), animated: false)
        }
    }

    /// 视口顶部的精确锚点：(章, 页, 章内字符偏移)
    private func topAnchor(_ scroll: UIScrollView) -> (chapter: Int, page: Int, localChar: Int)? {
        let y = scroll.contentOffset.y
        guard let block = scrollBlocks.last(where: { $0.top <= y }) ?? scrollBlocks.first else { return nil }
        let pages = viewModel.buildPages(forChapter: block.chapter)
        guard pages.indices.contains(block.page) else { return nil }
        let page = pages[block.page]
        let local = max(0, min(block.height, y - block.top))
        let within = page.range.length > 0
            ? Int(CGFloat(page.range.length) * (local / max(1, block.height)))
            : 0
        let localChar = page.range.location + min(page.range.length, max(0, within))
        return (block.chapter, block.page, localChar)
    }

    /// 跨章连续取页：从 (chapter, page) 起向前/向后取 limit 页，自动跨章
    private func collectPages(fromChapter chapter: Int, page: Int,
                              forward: Bool, limit: Int) -> [(chapter: Int, page: Int)] {
        var result: [(chapter: Int, page: Int)] = []
        var chapterIndex = chapter
        var pageIndex = page
        var hops = 0
        while result.count < limit,
              viewModel.chapters.indices.contains(chapterIndex),
              hops < 4096 {
            hops += 1
            let pages = viewModel.buildPages(forChapter: chapterIndex)
            if pages.isEmpty {
                chapterIndex += forward ? 1 : -1
                pageIndex = forward ? 0 : Int.max
                continue
            }
            if forward {
                if pageIndex >= pages.count {
                    chapterIndex += 1
                    pageIndex = 0
                    continue
                }
                result.append((chapterIndex, pageIndex))
                pageIndex += 1
            } else {
                if pageIndex >= pages.count { pageIndex = pages.count - 1 }
                if pageIndex < 0 {
                    chapterIndex -= 1
                    pageIndex = Int.max
                    continue
                }
                result.append((chapterIndex, pageIndex))
                pageIndex -= 1
            }
        }
        return result
    }

    /// 连续滚动：换算视口顶部位置并刷新进度，并在必要时安排重建补齐后续内容
    private func syncContinuousPosition(_ scroll: UIScrollView) {
        guard let anchor = topAnchor(scroll) else { return }
        currentChapter = anchor.chapter
        currentPage = anchor.page
        currentCharOffsetInChapter = anchor.localChar
        updateStatus()
        scheduleContinuousReloadIfNeeded()
    }

    /// 视口顶部进入新章时，延迟以该章为中心重建，持续补齐后续内容。
    /// 中心取「顶部所在章」，锚点页必然包含在重建内容里，因此不会跳章。
    /// 拖动/惯性滚动中不重排，避免打断惯性造成跳变；停止后由 finalize 强制触发。
    private func scheduleContinuousReloadIfNeeded(force: Bool = false) {
        guard let scroll = scrollView, !scrollBlocks.isEmpty, !continuousReloadScheduled else { return }
        if !force, scroll.isDragging || scroll.isDecelerating { return }
        guard let anchor = topAnchor(scroll), anchor.chapter != builtCenterChapter else { return }

        continuousReloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.continuousReloadScheduled = false
            guard self.settings.style == .verticalScroll,
                  let scroll = self.scrollView,
                  let anchor = self.topAnchor(scroll),
                  anchor.chapter != self.builtCenterChapter else { return }
            self.reloadContinuousContent(centerChapter: anchor.chapter, anchor: anchor)
        }
    }

    // MARK: - 在线阅读（后台缓存）

    /// 监听后台缓存进度：追加章节后重读文件、重排，并按字符偏移保持位置
    private func observeOnlineCache() {
        cacheObserver = NotificationCenter.default.addObserver(
            forName: .onlineBookCacheUpdated, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let bookId = note.userInfo?["bookId"] as? UUID,
                  bookId == self.viewModel.book.id else { return }
            var consistent = true
            if let text = note.userInfo?["text"] as? String {
                let offset = note.userInfo?["offset"] as? Int ?? -1
                consistent = self.viewModel.appendText(text, at: offset)
            }
            if let chapters = note.userInfo?["chapters"] as? [Chapter] {
                self.viewModel.setChapters(chapters)
            }
            if let cached = note.userInfo?["cached"] as? Int,
               let total = note.userInfo?["total"] as? Int {
                let done = (note.userInfo?["done"] as? Bool) ?? false
                self.cacheText = done ? "" : "缓存中 \(cached)/\(total)"
            }
            if consistent {
                self.refreshForNewContent()
            } else {
                // 缓存与文件不一致：清分页后按字符偏移重建，自愈
                self.viewModel.invalidatePagination()
                let anchor = self.currentAnchorCharOffset()
                self.restorePosition(anchor: anchor)
                self.rebuildPager()
            }
        }
    }

    /// 书架侧章节列表更新（每 10 章落库）时同步，兜底漏通知的情况
    func updateOnlineContent(chapters: [Chapter]) {
        guard chapters.count != viewModel.chapters.count else { return }
        viewModel.setChapters(chapters)
        viewModel.reloadText()
        viewModel.invalidatePagination()
        let anchor = currentAnchorCharOffset()
        restorePosition(anchor: anchor)
        lastPrefetchedChapter = -1
        rebuildPager()
    }

    /// 后台追加新章节后刷新阅读视图
    private func refreshForNewContent() {
        if settings.style == .verticalScroll {
            if scrollView?.isDragging == true || scrollView?.isDecelerating == true {
                pendingContentRefresh = true
                return
            }
            reloadContinuousContent()
        }
        updateStatus()
    }

    private func reloadOnlineContent() {
        let anchor = currentAnchorCharOffset()
        viewModel.reloadText()
        viewModel.invalidatePagination()
        restorePosition(anchor: anchor)
        lastPrefetchedChapter = -1
        rebuildPager()
    }

    /// 滚动停止后保存进度，并检查是否需要补齐前后内容
    private func finalizeContinuousScroll() {
        guard let scroll = scrollView else { return }
        syncContinuousPosition(scroll)
        saveProgress()
        if pendingContentRefresh {
            pendingContentRefresh = false
            reloadContinuousContent()
        }
        scheduleContinuousReloadIfNeeded(force: true)
    }

    private func makeContent(chapter: Int, page: Int) -> ReaderContentViewController? {
        let pages = viewModel.buildPages(forChapter: chapter)
        guard pages.indices.contains(page) else { return nil }
        return ReaderContentViewController(page: pages[page],
                                           readRect: readRect,
                                           pageBackground: theme.background)
    }

    // MARK: - 手势

    private func setupTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pageContainer.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if isMenuVisible {
            toggleMenu()
            return
        }
        let point = gesture.location(in: view)
        let width = view.bounds.width
        if point.x < width / 3 {
            goPrevious()
        } else if point.x > width / 3 * 2 {
            goNext()
        } else {
            toggleMenu()
        }
    }

    // MARK: - 导航

    private func goNext() {
        switch settings.style {
        case .cover, .slide:  animatedTurn(forward: true)
        case .instant:        instantTurn(forward: true)
        case .verticalScroll: scrollByPage(+1)
        case .curl:           pageGoNext()
        }
    }

    private func goPrevious() {
        switch settings.style {
        case .cover, .slide:  animatedTurn(forward: false)
        case .instant:        instantTurn(forward: false)
        case .verticalScroll: scrollByPage(-1)
        case .curl:           pageGoPrevious()
        }
    }

    private func neighborPage(forward: Bool) -> (content: NSAttributedString, chapter: Int, page: Int)? {
        var chapter = currentChapter
        var page = currentPage
        let pages = viewModel.buildPages(forChapter: chapter)
        if forward {
            if page + 1 < pages.count {
                page += 1
            } else if chapter + 1 < viewModel.chapters.count {
                chapter += 1
                page = 0
            } else {
                return nil
            }
        } else {
            if page > 0 {
                page -= 1
            } else if chapter > 0 {
                chapter -= 1
                page = max(0, viewModel.buildPages(forChapter: chapter).count - 1)
            } else {
                return nil
            }
        }
        let targetPages = viewModel.buildPages(forChapter: chapter)
        guard targetPages.indices.contains(page) else { return nil }
        return (targetPages[page].content, chapter, page)
    }

    private func animatedTurn(forward: Bool) {
        guard let front = frontView,
              let pending = neighborPage(forward: forward) else { return }

        let incoming = ReaderPageView(frame: readRect)
        incoming.backgroundColor = theme.background
        incoming.content = pending.content

        let width = view.bounds.width
        let movesOutgoing = settings.style == .slide

        if forward {
            incoming.frame.origin.x = readRect.minX + width
            pageContainer.addSubview(incoming)
        } else {
            incoming.frame.origin.x = readRect.minX - width
            pageContainer.insertSubview(incoming, belowSubview: front)
        }
        incomingView = incoming

        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut], animations: {
            incoming.frame.origin.x = self.readRect.minX
            if movesOutgoing {
                front.frame.origin.x = self.readRect.minX + (forward ? -width : width)
            }
        }, completion: { _ in
            front.content = incoming.content
            front.frame = self.readRect
            incoming.removeFromSuperview()
            self.incomingView = nil
            self.commitTurn(chapter: pending.chapter, page: pending.page)
        })
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:  goNext()
        case .right: goPrevious()
        default:     break
        }
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard settings.style == .cover || settings.style == .slide,
              let front = frontView else { return }

        let translation = pan.translation(in: pageContainer)
        let width = view.bounds.width
        let movesOutgoing = settings.style == .slide

        switch pan.state {
        case .began:
            incomingView?.removeFromSuperview()
            incomingView = nil
            panState = .idle

        case .changed:
            if case .idle = panState {
                guard abs(translation.x) > 8 else { return }
                let forward = translation.x < 0
                guard let pending = neighborPage(forward: forward) else { return }
                let incoming = ReaderPageView(frame: readRect)
                incoming.backgroundColor = theme.background
                incoming.content = pending.content
                if forward {
                    incoming.frame.origin.x = readRect.minX + width
                    pageContainer.addSubview(incoming)
                } else {
                    incoming.frame.origin.x = readRect.minX - width
                    pageContainer.insertSubview(incoming, belowSubview: front)
                }
                incomingView = incoming
                panState = .dragging(forward: forward, chapter: pending.chapter, page: pending.page)
            }
            if case .dragging(let forward, _, _) = panState, let incoming = incomingView {
                let dx = translation.x
                incoming.frame.origin.x = readRect.minX + (forward ? width + dx : -width + dx)
                if movesOutgoing {
                    front.frame.origin.x = readRect.minX + dx
                }
            }

        case .ended, .cancelled:
            guard case .dragging(let forward, let chapter, let page) = panState,
                  let incoming = incomingView else {
                panState = .idle
                return
            }
            let dx = translation.x
            let velocity = pan.velocity(in: pageContainer).x
            let shouldCommit = forward
                ? (dx < -width * 0.3 || velocity < -500)
                : (dx > width * 0.3 || velocity > 500)

            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut], animations: {
                if shouldCommit {
                    incoming.frame.origin.x = self.readRect.minX
                    if movesOutgoing {
                        front.frame.origin.x = self.readRect.minX + (forward ? -width : width)
                    }
                } else {
                    incoming.frame.origin.x = self.readRect.minX + (forward ? width : -width)
                    if movesOutgoing {
                        front.frame.origin.x = self.readRect.minX
                    }
                }
            }, completion: { _ in
                if shouldCommit {
                    front.content = incoming.content
                    front.frame = self.readRect
                    self.commitTurn(chapter: chapter, page: page)
                }
                incoming.removeFromSuperview()
                self.incomingView = nil
                self.panState = .idle
            })

        default:
            break
        }
    }

    private func commitTurn(chapter: Int, page: Int) {
        currentChapter = chapter
        currentPage = page
        updateStatus()
        saveProgress()
    }

    /// 无动画翻页：直接替换内容，不做过渡
    private func instantTurn(forward: Bool) {
        guard let front = frontView, let pending = neighborPage(forward: forward) else { return }
        front.content = pending.content
        commitTurn(chapter: pending.chapter, page: pending.page)
    }

    private func pageGoNext() {
        let pages = viewModel.buildPages(forChapter: currentChapter)
        var chapter = currentChapter
        var page = currentPage
        if page + 1 < pages.count {
            page += 1
        } else if chapter + 1 < viewModel.chapters.count {
            chapter += 1
            page = 0
        } else {
            return
        }
        guard let vc = makeContent(chapter: chapter, page: page) else { return }
        currentChapter = chapter
        currentPage = page
        pageViewController?.setViewControllers([vc], direction: .forward, animated: true)
        updateStatus()
        saveProgress()
    }

    private func pageGoPrevious() {
        var chapter = currentChapter
        var page = currentPage
        if page > 0 {
            page -= 1
        } else if chapter > 0 {
            chapter -= 1
            page = max(0, viewModel.buildPages(forChapter: chapter).count - 1)
        } else {
            return
        }
        guard let vc = makeContent(chapter: chapter, page: page) else { return }
        currentChapter = chapter
        currentPage = page
        pageViewController?.setViewControllers([vc], direction: .reverse, animated: true)
        updateStatus()
        saveProgress()
    }

    /// 点击左右区域时按一屏高度滚动（连续滚动没有按页吸附）
    private func scrollByPage(_ delta: Int) {
        guard let scroll = scrollView else { return }
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        let target = min(max(0, scroll.contentOffset.y + CGFloat(delta) * scroll.bounds.height), maxY)
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }
}

// MARK: - UIPageViewControllerDataSource / Delegate（仿真翻页）

extension ReaderViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let content = viewController as? ReaderContentViewController else { return nil }
        var chapter = content.chapterIndex
        var page = content.pageIndex
        if page > 0 {
            page -= 1
        } else if chapter > 0 {
            chapter -= 1
            page = max(0, viewModel.buildPages(forChapter: chapter).count - 1)
        } else {
            return nil
        }
        return makeContent(chapter: chapter, page: page)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let content = viewController as? ReaderContentViewController else { return nil }
        var chapter = content.chapterIndex
        var page = content.pageIndex
        let pages = viewModel.buildPages(forChapter: chapter)
        if page + 1 < pages.count {
            page += 1
        } else if chapter + 1 < viewModel.chapters.count {
            chapter += 1
            page = 0
        } else {
            return nil
        }
        return makeContent(chapter: chapter, page: page)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed,
              let content = pageViewController.viewControllers?.first as? ReaderContentViewController else { return }
        currentChapter = content.chapterIndex
        currentPage = content.pageIndex
        updateStatus()
        saveProgress()
    }
}

// MARK: - UIScrollViewDelegate（上下滚动）

extension ReaderViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard settings.style == .verticalScroll, !scrollBlocks.isEmpty else { return }
        syncContinuousPosition(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard settings.style == .verticalScroll else { return }
        if !decelerate { finalizeContinuousScroll() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard settings.style == .verticalScroll else { return }
        finalizeContinuousScroll()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard settings.style == .verticalScroll else { return }
        finalizeContinuousScroll()
    }
}
