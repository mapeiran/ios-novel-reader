import Foundation

extension Notification.Name {
    /// 在线缓存进度更新（userInfo: bookId / chapters / cached / total / done）
    static let onlineBookCacheUpdated = Notification.Name("onlineBookCacheUpdated")
}

/// 在线阅读：先抓目录、第一章落盘即可打开，其余章节后台逐章抓取并追加到本地文件
final class OnlineReadingService {
    static let shared = OnlineReadingService()

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let lock = NSLock()

    struct Catalog: Codable {
        var source: BookSource
        var chapters: [OnlineChapter]
        var cached: Int
    }

    private func catalogURL(bookId: UUID, storage: Storage) -> URL {
        storage.root.appendingPathComponent("online-\(bookId.uuidString).json")
    }

    func saveCatalog(_ catalog: Catalog, bookId: UUID, storage: Storage) {
        if let data = try? JSONEncoder().encode(catalog) {
            try? data.write(to: catalogURL(bookId: bookId, storage: storage), options: .atomic)
        }
    }

    func loadCatalog(bookId: UUID, storage: Storage) -> Catalog? {
        guard let data = try? Data(contentsOf: catalogURL(bookId: bookId, storage: storage)) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// 开始在线阅读：抓目录 + 第一章落盘，返回可立即打开的 Book
    func start(source: BookSource, title: String, author: String?, cover: String?, detailURL: String,
               storage: Storage, library: LibraryStore) async throws -> Book {
        let service = BookSourceService()
        let catalog = try await service.chapters(detailURL: detailURL, source: source)
        guard !catalog.isEmpty else { throw BookSourceError.noResult }

        let bookId = UUID()
        let fileURL = storage.bookFileURL(for: bookId)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let first = catalog[0]
        let firstContent = (try? await service.content(chapterURL: first.url, source: source)) ?? ""
        let firstPiece = first.name + "\n" + firstContent + "\n\n"
        try? Data(firstPiece.utf8).write(to: fileURL)

        let firstLength = (firstPiece as NSString).length
        let chapters = [Chapter(bookId: bookId, index: 0, title: first.name, start: 0, end: firstLength)]
        let book = Book(id: bookId, title: title, author: author, filePath: fileURL.path,
                        encoding: "UTF-8", fileSize: Int64(firstPiece.utf8.count),
                        totalChars: firstLength, chapterCount: catalog.count,
                        chapterRule: ChapterRule.defaultPattern, addedAt: Date(), lastReadAt: nil,
                        parseState: .done, contentHash: nil, folder: nil,
                        cacheState: .caching, cachedChapterCount: 1,
                        sourceName: source.name, coverURL: cover)
        library.add(book, chapters: chapters)
        saveCatalog(Catalog(source: source, chapters: catalog, cached: 1), bookId: bookId, storage: storage)
        run(book: book, source: source, catalog: catalog, startIndex: 1, storage: storage, library: library)
        return book
    }

    /// App 重启后继续未完成的缓存
    func resumeIfNeeded(book: Book, storage: Storage, library: LibraryStore) {
        guard book.isCaching else { return }
        lock.lock()
        let running = tasks[book.id] != nil
        lock.unlock()
        guard !running else { return }
        guard let catalog = loadCatalog(bookId: book.id, storage: storage) else { return }
        run(book: book, source: catalog.source, catalog: catalog.chapters,
            startIndex: catalog.cached, storage: storage, library: library)
    }

    func isCaching(_ bookId: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks[bookId] != nil
    }

    private func run(book: Book, source: BookSource, catalog: [OnlineChapter], startIndex: Int,
                     storage: Storage, library: LibraryStore) {
        guard startIndex < catalog.count else { return }
        let bookId = book.id
        let fileURL = URL(fileURLWithPath: book.filePath)
        let pattern = book.chapterRule ?? ChapterRule.defaultPattern

        let task = Task.detached(priority: .utility) { [weak self] in
            let service = BookSourceService()
            var fullText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            var chapters = ChapterParser.parse(text: fullText, bookId: bookId, pattern: pattern)

            for index in startIndex..<catalog.count {
                if Task.isCancelled { return }
                let item = catalog[index]
                let content = (try? await service.content(chapterURL: item.url, source: source)) ?? ""
                let piece = item.name + "\n" + content + "\n\n"
                let start = (fullText as NSString).length
                fullText += piece
                let end = (fullText as NSString).length

                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(piece.utf8))
                    try? handle.close()
                }
                chapters.append(Chapter(bookId: bookId, index: chapters.count, title: item.name, start: start, end: end))

                let cached = index + 1
                let isLast = index == catalog.count - 1
                if isLast || cached % 10 == 0 {
                    // 以文件全文重新分章，保证章节区间与文件严格一致
                    chapters = ChapterParser.parse(text: fullText, bookId: bookId, pattern: pattern)
                }
                let snapshotChapters = chapters
                let snapshotOffset = end
                let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0

                await MainActor.run {
                    if isLast || cached % 10 == 0 {
                        var updated = book
                        updated.totalChars = snapshotOffset
                        updated.fileSize = fileSize
                        updated.cachedChapterCount = cached
                        updated.cacheState = isLast ? .done : .caching
                        library.update(updated, chapters: snapshotChapters)
                        self?.saveCatalog(Catalog(source: source, chapters: catalog, cached: cached),
                                          bookId: bookId, storage: storage)
                    }
                    NotificationCenter.default.post(name: .onlineBookCacheUpdated, object: nil,
                                                    userInfo: ["bookId": bookId, "text": piece, "offset": start,
                                                               "chapters": snapshotChapters,
                                                               "cached": cached,
                                                               "total": catalog.count,
                                                               "done": isLast])
                }
            }

            // 缓存完成后按默认规则自动格式化一次（清洗 + 自动分段 + 繁转简）
            let formatted = TextFormatter.format(fullText, options: FormatOptions())
            if let data = formatted.text.data(using: .utf8) {
                try? data.write(to: fileURL, options: .atomic)
                let reformatted = ChapterParser.parse(text: formatted.text, bookId: bookId, pattern: pattern)
                let length = (formatted.text as NSString).length
                await MainActor.run {
                    var updated = book
                    updated.totalChars = length
                    updated.fileSize = Int64(data.count)
                    updated.cachedChapterCount = catalog.count
                    updated.cacheState = .done
                    library.update(updated, chapters: reformatted)
                    self?.saveCatalog(Catalog(source: source, chapters: catalog, cached: catalog.count),
                                      bookId: bookId, storage: storage)
                    NotificationCenter.default.post(name: .onlineBookCacheUpdated, object: nil,
                                                    userInfo: ["bookId": bookId,
                                                               "chapters": reformatted,
                                                               "cached": catalog.count,
                                                               "total": catalog.count,
                                                               "done": true,
                                                               "reformatted": true])
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.lock.lock(); self.tasks.removeValue(forKey: bookId); self.lock.unlock()
            }
        }
        lock.lock(); tasks[bookId] = task; lock.unlock()
    }
}
