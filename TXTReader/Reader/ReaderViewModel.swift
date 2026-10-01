import UIKit

/// 全文搜索结果
struct SearchResult: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
    let offset: Int
}

/// 阅读逻辑：加载章节文本、分页、跨章导航、全文搜索
final class ReaderViewModel {

    let book: Book
    private(set) var chapters: [Chapter]

    private var _typography: Typography
    private var _readRect: CGRect = .zero

    /// 排版参数（加锁读写，后台预取会并发访问）
    var typography: Typography {
        get { lock.lock(); defer { lock.unlock() }; return _typography }
        set { lock.lock(); _typography = newValue; lock.unlock() }
    }

    /// 阅读可视区域（由 ReaderViewController 根据安全区设置，加锁读写）
    var readRect: CGRect {
        get { lock.lock(); defer { lock.unlock() }; return _readRect }
        set { lock.lock(); _readRect = newValue; lock.unlock() }
    }

    private var textCache: String?
    private var pageCache: [Int: [PageModel]] = [:]

    /// 分页缓存与后台预取可能跨线程访问，统一加锁保护
    private let lock = NSLock()
    private let paginationQueue = DispatchQueue(label: "com.mapeiran.TXTReader.pagination",
                                                qos: .utility)
    /// 排版版本号：重排后自增，避免后台预取把旧排版结果写回缓存
    private var paginationGeneration = 0

    init(book: Book, chapters: [Chapter], typography: Typography) {
        self.book = book
        self.chapters = chapters
        self._typography = typography
    }

    // MARK: - 正文

    /// 预热全文（供后台搜索，避免首次搜索时才读盘）
    func preloadText() {
        _ = fullText()
    }

    /// 全文（带缓存）
    func fullText() -> String {
        lock.lock()
        if let textCache {
            lock.unlock()
            return textCache
        }
        lock.unlock()

        let text = (try? String(contentsOfFile: book.filePath, encoding: .utf8)) ?? ""

        lock.lock()
        if let existing = textCache {
            lock.unlock()
            return existing
        }
        textCache = text
        lock.unlock()
        return text
    }

    // MARK: - 全文搜索

    /// 全局搜索（在后台线程调用），返回结果与字符偏移
    func search(_ query: String, limit: Int = 300) -> [SearchResult] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }

        let ns = fullText() as NSString
        guard ns.length > 0 else { return [] }

        var results: [SearchResult] = []
        var searchRange = NSRange(location: 0, length: ns.length)

        while results.count < limit {
            let found = ns.range(of: keyword, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound { break }

            let chapter = chapterIndex(forCharOffset: found.location)
            let start = max(0, found.location - 20)
            let end = min(ns.length, found.location + found.length + 40)
            let snippet = ns.substring(with: NSRange(location: start, length: end - start))
                .replacingOccurrences(of: "\n", with: " ")

            results.append(SearchResult(chapterIndex: chapter,
                                        chapterTitle: chapters[chapter].title,
                                        snippet: snippet,
                                        offset: found.location))

            let next = found.location + max(1, found.length)
            if next >= ns.length { break }
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return results
    }

    func chapterText(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        let chapter = chapters[index]
        let ns = fullText() as NSString
        let start = min(max(0, chapter.start), ns.length)
        let end = min(max(start, chapter.end), ns.length)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - 分页

    /// 构建某一章的分页（带缓存，不改变当前状态；线程安全，可在后台预取）
    func buildPages(forChapter index: Int) -> [PageModel] {
        lock.lock()
        if let cached = pageCache[index] {
            lock.unlock()
            return cached
        }
        let generation = paginationGeneration
        let typography = _typography
        let rect = _readRect
        lock.unlock()

        guard rect.width > 0, rect.height > 0 else { return [] }

        let text = chapterText(at: index)
        let attributed = typography.attributedString(for: text)
        let ranges = PaginationService.paginate(attributed: attributed, in: rect)
        let pages = ranges.enumerated().map { i, range -> PageModel in
            let sub = attributed.attributedSubstring(from: range)
            return PageModel(chapterIndex: index,
                             pageIndex: i,
                             totalPages: ranges.count,
                             range: range,
                             content: sub,
                             textHeight: PaginationService.textHeight(attributed: sub,
                                                                       width: rect.width))
        }

        lock.lock()
        if generation == paginationGeneration {
            if let cached = pageCache[index] {
                lock.unlock()
                return cached
            }
            pageCache[index] = pages
            lock.unlock()
            return pages
        }
        lock.unlock()
        return pages
    }

    /// 在线缓存过程中更新章节列表（追加章节）
    func setChapters(_ list: [Chapter]) {
        lock.lock()
        chapters = list
        lock.unlock()
    }

    /// 后台缓存追加正文；返回缓存是否仍与文件一致（false 表示需重新读取文件）
    @discardableResult
    func appendText(_ text: String, at offset: Int) -> Bool {
        guard !text.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard let cached = textCache else { return true }
        if offset < 0 || (cached as NSString).length == offset {
            textCache = cached + text
            return true
        }
        // 偏移对不上（漏通知等）：丢弃缓存，下次 fullText 从文件重读自愈
        textCache = nil
        return false
    }

    /// 正文文件被追加内容后，清掉文本缓存以便重新读取
    func reloadText() {
        lock.lock()
        textCache = nil
        lock.unlock()
    }

    /// 清空分页缓存（排版变化后调用）
    func invalidatePagination() {
        lock.lock()
        paginationGeneration += 1
        pageCache.removeAll()
        lock.unlock()
    }

    /// 后台预取某一章分页：当前页显示后提前算好前后章，跨章时不再现算卡顿
    func prefetch(chapterIndex: Int) {
        guard chapters.indices.contains(chapterIndex) else { return }
        paginationQueue.async { [weak self] in
            _ = self?.buildPages(forChapter: chapterIndex)
        }
    }

    /// 按字符偏移定位页
    func pageIndex(forCharOffset offset: Int, chapterIndex: Int) -> Int {
        let pages = buildPages(forChapter: chapterIndex)
        let localOffset = max(0, offset - chapters[chapterIndex].start)
        return PaginationService.pageIndex(for: localOffset, in: pages.map(\.range))
    }

    /// 按整本字符偏移定位章节
    func chapterIndex(forCharOffset offset: Int) -> Int {
        guard !chapters.isEmpty else { return 0 }
        var result = 0
        for (i, chapter) in chapters.enumerated() {
            if offset >= chapter.start {
                result = i
            } else {
                break
            }
        }
        return result
    }

    // MARK: - 进度

    func makeRecord(chapterIndex: Int, pageIndex: Int) -> ReadingRecord {
        let pages = buildPages(forChapter: chapterIndex)
        let chapter = chapters[chapterIndex]
        let pageRange = pages.indices.contains(pageIndex) ? pages[pageIndex].range : NSRange(location: 0, length: 0)
        let charOffset = chapter.start + pageRange.location
        let total = max(1, book.totalChars)
        let percent = min(1.0, Double(charOffset) / Double(total))
        return ReadingRecord(bookId: book.id,
                             chapterIndex: chapterIndex,
                             pageIndex: pageIndex,
                             charOffset: charOffset,
                             percent: percent)
    }
}
