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
    var typography: Typography
    /// 阅读可视区域（由 ReaderViewController 根据安全区设置）
    var readRect: CGRect = .zero

    private var textCache: String?
    private var pageCache: [Int: [PageModel]] = [:]

    init(book: Book, chapters: [Chapter], typography: Typography) {
        self.book = book
        self.chapters = chapters
        self.typography = typography
    }

    // MARK: - 正文

    /// 预热全文（供后台搜索，避免首次搜索时才读盘）
    func preloadText() {
        _ = fullText()
    }

    /// 全文（带缓存）
    func fullText() -> String {
        if let textCache { return textCache }
        let text = (try? String(contentsOfFile: book.filePath, encoding: .utf8)) ?? ""
        textCache = text
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

    /// 构建某一章的分页（带缓存，不改变当前状态）
    func buildPages(forChapter index: Int) -> [PageModel] {
        if let cached = pageCache[index] { return cached }
        guard readRect.width > 0, readRect.height > 0 else { return [] }

        let text = chapterText(at: index)
        let attributed = typography.attributedString(for: text)
        let ranges = PaginationService.paginate(attributed: attributed, in: readRect)
        let pages = ranges.enumerated().map { i, range -> PageModel in
            let sub = attributed.attributedSubstring(from: range)
            return PageModel(chapterIndex: index,
                             pageIndex: i,
                             totalPages: ranges.count,
                             range: range,
                             content: sub,
                             textHeight: PaginationService.textHeight(attributed: sub,
                                                                       width: readRect.width))
        }
        pageCache[index] = pages
        return pages
    }

    /// 清空分页缓存（排版变化后调用）
    func invalidatePagination() {
        pageCache.removeAll()
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
