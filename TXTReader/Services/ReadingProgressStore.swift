import Foundation

/// 阅读进度存储
final class ReadingProgressStore {
    private let storage: Storage
    private var cache: [UUID: ReadingRecord]

    init(storage: Storage) {
        self.storage = storage
        self.cache = storage.loadRecords()
    }

    func save(_ record: ReadingRecord) {
        cache[record.bookId] = record
        storage.saveRecords(cache)
    }

    func load(bookId: UUID) -> ReadingRecord? {
        cache[bookId]
    }

    func allRecords() -> [UUID: ReadingRecord] { cache }

    func clear(bookId: UUID) {
        cache[bookId] = nil
        storage.saveRecords(cache)
    }

    func clearAll() {
        cache.removeAll()
        storage.saveRecords(cache)
    }
}
