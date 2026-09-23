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

    /// 展示顺序：置顶优先，其次分组名，再次名称
    var orderedSources: [BookSource] {
        sources.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            let ga = a.group ?? "", gb = b.group ?? ""
            if ga != gb { return ga < gb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var enabledSources: [BookSource] { sources.filter { $0.enabled } }

    func add(_ source: BookSource) {
        sources.append(source)
        save()
    }

    func update(_ source: BookSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
            save()
        }
    }

    func remove(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    func remove(at offsets: IndexSet, in list: [BookSource]) {
        let ids = offsets.map { list[$0].id }
        sources.removeAll { ids.contains($0.id) }
        save()
    }

    func toggle(_ source: BookSource) {
        var s = source
        s.enabled.toggle()
        update(s)
    }

    func setPinned(_ source: BookSource, _ pinned: Bool) {
        var s = source
        s.pinned = pinned
        update(s)
    }

    func setHealth(_ source: BookSource, ok: Bool, latency: Double) {
        var s = source
        s.lastOK = ok
        s.lastLatency = latency
        update(s)
    }

    /// 合并导入（按 id 去重），返回新增数量
    @discardableResult
    func merge(_ list: [BookSource]) -> Int {
        var added = 0
        for source in list where !sources.contains(where: { $0.id == source.id }) {
            sources.append(source)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// 导入书源 JSON（支持单个对象或数组），返回导入数量
    @discardableResult
    func importJSON(_ json: String) throws -> Int {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([BookSource].self, from: data) {
            array.forEach { add($0) }
            return array.count
        }
        let single = try decoder.decode(BookSource.self, from: data)
        add(single)
        return 1
    }

    @discardableResult
    func addFromJSON(_ json: String) throws -> BookSource {
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        add(source)
        return source
    }

    /// 导出全部书源为 JSON
    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let data = try? encoder.encode(sources), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "[]"
    }

    private func save() {
        storage.saveBookSources(sources)
    }
}
