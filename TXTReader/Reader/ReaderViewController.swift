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

    init(book: Book, chapters: [Chapter], settings: ReaderSettings, progressStore: ReadingProgressStore) {
        self.viewModel = ReaderViewModel(book: book, chapters: chapters, typography: settings.typography)
        self.settings = settings
        self.progressStore = progressStore
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }

    private var theme: ReaderTheme { ReaderTheme.theme(at: settings.typography.themeIndex) }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupChrome()
        setupMenu()
        bindSettings()
        restoreProgress()
        setupTapGesture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backgroundView.frame = view.bounds
        pageContainer.frame = view.bounds
        layoutBars()
        layoutMenu()

        let rect = ReaderLayout.readRect(in: view.bounds,
                                         safeTop: view.safeAreaInsets.top,
                                         safeBottom: view.safeAreaInsets.bottom)
        guard !didSetup, rect.width > 0, rect.height > 0 else { return }
        didSetup = true
        readRect = rect
        viewModel.readRect = rect
        rebuildPager()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveProgress()
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
        titleLabel.text = chapter.title
        pageLabel.text = "第 \(currentPage + 1)/\(max(1, pages.count)) 页"
        let percent = Int(viewModel.makeRecord(chapterIndex: currentChapter,
                                               pageIndex: currentPage).percent * 100)
        progressLabel.text = "\(percent)%"
        updateMenuProgress()
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
        let percent = Int(viewModel.makeRecord(chapterIndex: currentChapter,
                                               pageIndex: currentPage).percent * 100)
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
        host.overrideUserInterfaceStyle = settings.typography.themeIndex == 1 ? .dark : .light
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
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.viewModel.typography = self.settings.typography
                    self.viewModel.invalidatePagination()
                    self.applyTheme()
                    self.rebuildPager()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 进度

    private func restoreProgress() {
        if let record = progressStore.load(bookId: viewModel.book.id) {
            currentChapter = min(max(0, record.chapterIndex), max(0, viewModel.chapters.count - 1))
            currentPage = max(0, record.pageIndex)
        }
    }

    private func saveProgress() {
        guard viewModel.chapters.indices.contains(currentChapter) else { return }
        let record = viewModel.makeRecord(chapterIndex: currentChapter, pageIndex: currentPage)
        progressStore.save(record)
    }

    private func jumpToChapter(_ index: Int) {
        guard viewModel.chapters.indices.contains(index) else { return }
        currentChapter = index
        currentPage = 0
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
        rebuildPager()
        updateStatus()
        saveProgress()
    }

    private func presentSettings() {
        let host = UIHostingController(rootView: ReaderSettingsView(settings: settings))
        host.modalPresentationStyle = .pageSheet
        host.overrideUserInterfaceStyle = settings.typography.themeIndex == 1 ? .dark : .light
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

        switch settings.style {
        case .curl:
            setupPageViewController()
        case .cover, .slide:
            setupHorizontal()
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

    private func setupScrollView() {
        let scroll = UIScrollView(frame: readRect)
        scroll.isPagingEnabled = true
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = self
        scroll.backgroundColor = theme.background
        pageContainer.addSubview(scroll)
        scrollView = scroll
        reloadScrollPages()
    }

    private func reloadScrollPages() {
        guard let scroll = scrollView else { return }
        scroll.subviews.forEach { $0.removeFromSuperview() }

        let pages = viewModel.buildPages(forChapter: currentChapter)
        for (i, page) in pages.enumerated() {
            let pageView = ReaderPageView(frame: CGRect(x: 0,
                                                        y: CGFloat(i) * readRect.height,
                                                        width: readRect.width,
                                                        height: readRect.height))
            pageView.backgroundColor = theme.background
            pageView.content = page.content
            scroll.addSubview(pageView)
        }
        scroll.contentSize = CGSize(width: readRect.width,
                                    height: max(readRect.height, CGFloat(pages.count) * readRect.height))
        let target = min(currentPage, max(0, pages.count - 1))
        scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(target) * readRect.height), animated: false)
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
        case .verticalScroll: scrollByPage(+1)
        case .curl:           pageGoNext()
        }
    }

    private func goPrevious() {
        switch settings.style {
        case .cover, .slide:  animatedTurn(forward: false)
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

    private func scrollByPage(_ delta: Int) {
        guard let scroll = scrollView else { return }
        let pages = viewModel.buildPages(forChapter: currentChapter)
        let target = min(max(0, currentPage + delta), max(0, pages.count - 1))
        currentPage = target
        scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(target) * readRect.height), animated: true)
        updateStatus()
        saveProgress()
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
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard readRect.height > 0 else { return }
        currentPage = Int(round(scrollView.contentOffset.y / readRect.height))
        updateStatus()
        saveProgress()
    }
}
