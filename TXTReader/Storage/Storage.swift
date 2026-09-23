import Foundation
import Combine

/// 轻量持久化：正文存沙盒文件，元数据/章节/进度存 JSON。
/// 生产环境建议替换为 SQLite(GRDB)。
final class Storage {
    let root: URL
    let booksDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("TXTReader", isDirectory: true)
        booksDirectory = root.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
    }

    private var booksFile: URL { root.appendingPathComponent("books.json") }
    private func chaptersFile(bookId: UUID) -> URL { root.appendingPathComponent("chapters-\(bookId.uuidString).json") }
    private func progressFile() -> URL { root.appendingPathComponent("progress.json") }
    private var sourcesFile: URL { root.appendingPathComponent("sources.json") }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Books

    func loadBooks() -> [Book] { read([Book].self, from: booksFile) ?? [] }
    func saveBooks(_ books: [Book]) { write(books, to: booksFile) }

    // MARK: - Chapters

    func loadChapters(bookId: UUID) -> [Chapter] {
        read([Chapter].self, from: chaptersFile(bookId: bookId)) ?? []
    }
    func saveChapters(_ chapters: [Chapter], bookId: UUID) {
        write(chapters, to: chaptersFile(bookId: bookId))
    }

    // MARK: - Progress

    func loadRecords() -> [UUID: ReadingRecord] {
        read([UUID: ReadingRecord].self, from: progressFile()) ?? [:]
    }
    func saveRecords(_ records: [UUID: ReadingRecord]) {
        write(records, to: progressFile())
    }

    // MARK: - Book Sources

    func loadBookSources() -> [BookSource] {
        read([BookSource].self, from: sourcesFile) ?? []
    }
    func saveBookSources(_ sources: [BookSource]) {
        write(sources, to: sourcesFile)
    }

    // MARK: - Files

    func bookFileURL(for id: UUID) -> URL {
        booksDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    func deleteBookFiles(_ book: Book) {
        // 只删除沙盒 Books 目录内的副本，绝不触碰外部源文件
        let path = URL(fileURLWithPath: book.filePath).standardizedFileURL.path
        let booksPath = booksDirectory.standardizedFileURL.path
        if path.hasPrefix(booksPath + "/") {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? FileManager.default.removeItem(at: chaptersFile(bookId: book.id))
        try? FileManager.default.removeItem(at: backupFileURL(for: book))
    }

    // MARK: - Format backup

    func backupFileURL(for book: Book) -> URL {
        URL(fileURLWithPath: book.filePath).appendingPathExtension("bak")
    }
    func hasBackup(for book: Book) -> Bool {
        FileManager.default.fileExists(atPath: backupFileURL(for: book).path)
    }
}

/// 书架数据源
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    let storage = Storage()
    private let progressStore: ReadingProgressStore

    init() {
        progressStore = ReadingProgressStore(storage: storage)
        reload()
    }

    func reload() {
        let records = progressStore.allRecords()
        var loaded = storage.loadBooks()

        // 修复容器路径变化（重装/升级）导致的失效路径
        var repaired = false
        for index in loaded.indices where !FileManager.default.fileExists(atPath: loaded[index].filePath) {
            let candidate = storage.bookFileURL(for: loaded[index].id)
            if FileManager.default.fileExists(atPath: candidate.path) {
                loaded[index].filePath = candidate.path
                repaired = true
            }
        }
        if repaired { storage.saveBooks(loaded) }

        books = loaded.map { book in
            var b = book
            b.progress = records[book.id]?.percent ?? 0
            return b
        }
    }

    func add(_ book: Book) {
        var list = storage.loadBooks()
        list.insert(book, at: 0)
        storage.saveBooks(list)
        reload()
    }

    /// 添加已解析完成的书籍（在线导入）
    func add(_ book: Book, chapters: [Chapter]) {
        storage.saveChapters(chapters, bookId: book.id)
        add(book)
    }

    /// 更新书籍（可选覆盖章节）
    func update(_ book: Book, chapters: [Chapter]? = nil) {
        if let chapters {
            storage.saveChapters(chapters, bookId: book.id)
        }
        var list = storage.loadBooks()
        if let index = list.firstIndex(where: { $0.id == book.id }) {
            list[index] = book
        } else {
            list.insert(book, at: 0)
        }
        storage.saveBooks(list)
        reload()
    }

    /// 后台解析章节，完成后更新书架
    func parseChapters(for book: Book) {
        var parsing = book
        parsing.parseState = .parsing
        update(parsing)

        BookImportService(storage: storage).parse(book) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (updated, chapters)):
                self.update(updated, chapters: chapters)
            case .failure:
                var failed = book
                failed.parseState = .failed
                self.update(failed)
            }
        }
    }

    // MARK: - 格式化

    /// 覆盖保存格式化结果（备份原文件，可撤销）
    @discardableResult
    func overwriteWithFormatted(_ book: Book, text: String) -> Book? {
        let url = URL(fileURLWithPath: book.filePath)
        let backup = storage.backupFileURL(for: book)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        let normalized = EncodingDetector.normalize(text)
        guard let data = normalized.data(using: .utf8) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }

        let chapters = ChapterParser.parse(text: normalized, bookId: book.id,
                                           pattern: book.chapterRule ?? ChapterRule.defaultPattern)
        storage.saveChapters(chapters, bookId: book.id)
        progressStore.clear(bookId: book.id) // 字符偏移已变，清进度避免错位

        var updated = book
        updated.totalChars = (normalized as NSString).length
        updated.chapterCount = chapters.count
        updated.fileSize = Int64(data.count)
        updated.contentHash = BookImportService.fileHash(at: url)
        update(updated)
        return updated
    }

    /// 另存为新的书籍
    @discardableResult
    func saveFormattedAsNew(_ book: Book, text: String) -> Book? {
        do {
            let (newBook, chapters) = try BookImportService(storage: storage)
                .importText(text,
                            title: book.title + "（格式化）",
                            author: book.author,
                            pattern: book.chapterRule ?? ChapterRule.defaultPattern)
            add(newBook, chapters: chapters)
            return newBook
        } catch {
            return nil
        }
    }

    /// 撤销格式化（恢复备份）
    @discardableResult
    func undoFormat(_ book: Book) -> Bool {
        let url = URL(fileURLWithPath: book.filePath)
        let backup = storage.backupFileURL(for: book)
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }

        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.moveItem(at: backup, to: url) } catch { return false }

        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let chapters = ChapterParser.parse(text: text, bookId: book.id,
                                               pattern: book.chapterRule ?? ChapterRule.defaultPattern)
            storage.saveChapters(chapters, bookId: book.id)
            var updated = book
            updated.totalChars = (text as NSString).length
            updated.chapterCount = chapters.count
            updated.contentHash = BookImportService.fileHash(at: url)
            update(updated)
        }
        return true
    }

    func hasFormatBackup(_ book: Book) -> Bool {
        storage.hasBackup(for: book)
    }

    /// 还原阅读记录
    func restoreRecords(_ records: [UUID: ReadingRecord]) {
        progressStore.replaceAll(records)
        reload()
    }

    func remove(at offsets: IndexSet) {
        var list = storage.loadBooks()
        for index in offsets.sorted(by: >) where index < list.count {
            storage.deleteBookFiles(list[index])
            progressStore.clear(bookId: list[index].id)
            list.remove(at: index)
        }
        storage.saveBooks(list)
        reload()
    }

    /// 删除单本书
    func remove(_ book: Book) {
        var list = storage.loadBooks()
        if let index = list.firstIndex(where: { $0.id == book.id }) {
            storage.deleteBookFiles(list[index])
            progressStore.clear(bookId: book.id)
            list.remove(at: index)
        }
        storage.saveBooks(list)
        reload()
    }

    /// 重命名
    func rename(_ book: Book, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = storage.loadBooks()
        if let index = list.firstIndex(where: { $0.id == book.id }) {
            list[index].title = trimmed
        }
        storage.saveBooks(list)
        reload()
    }

    /// 按内容哈希查找是否已存在
    func findDuplicate(hash: String?) -> Book? {
        guard let hash, !hash.isEmpty else { return nil }
        return storage.loadBooks().first { $0.contentHash == hash }
    }

    /// 丢弃未入库的书籍文件
    func discard(_ book: Book) {
        storage.deleteBookFiles(book)
    }

    func chapters(for book: Book) -> [Chapter] {
        storage.loadChapters(bookId: book.id)
    }

    func progressStoreInstance() -> ReadingProgressStore { progressStore }
}
