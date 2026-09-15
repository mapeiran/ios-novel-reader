import Foundation
import Combine

/// 书源管理
final class BookSourceStore: ObservableObject {
    @Published private(set) var sources: [BookSource] = []
    private let storage: Storage

    init(storage: Storage = Storage()) {
        self.storage = storage
        sources = storage.loadBookSources()
    }

    func add(_ source: BookSource) {
        sources.append(source)
        storage.saveBookSources(sources)
    }

    func update(_ source: BookSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
            storage.saveBookSources(sources)
        }
    }

    func remove(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        storage.saveBookSources(sources)
    }

    @discardableResult
    func addFromJSON(_ json: String) throws -> BookSource {
        let data = Data(json.utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        add(source)
        return source
    }
}
