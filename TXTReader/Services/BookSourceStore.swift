import Foundation
import Combine

/// 书源管理
final class BookSourceStore: ObservableObject {
    @Published private(set) var sources: [BookSource] = []
    @Published var isUpdating = false
    @Published var updateMessage: String?
    private let storage: Storage

    init(storage: Storage = Storage()) {
        self.storage = storage
        sources = storage.loadBookSources()
        loadBundledDefaultsIfNeeded()
    }

    /// 首次启动（无任何书源）时，从 App 内置的「书源.json」加载默认书源
    private func loadBundledDefaultsIfNeeded() {
        guard sources.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for name in ["书源", "default-sources"] {
                guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                      let data = try? Data(contentsOf: url),
                      let list = BookSourceStore.makeLegadoSources(from: data),
                      !list.isEmpty else { continue }
                DispatchQueue.main.async {
                    guard self.sources.isEmpty else { return }
                    self.replaceAll(with: list)
                }
                return
            }
        }
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
        // 1) 「阅读/Legado」格式（数组，元素含 bookSourceName）
        if let legado = BookSourceStore.makeLegadoSources(from: data) {
            legado.forEach { add($0) }
            return legado.count
        }
        // 2) App 自定义正则格式
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

    /// 整体替换所有书源（用于「检查更新」）
    func replaceAll(with list: [BookSource]) {
        sources = list
        save()
    }

    /// 从 GitHub 拉取最新「书源.json」并整体替换
    func checkForUpdate() {
        guard !isUpdating else { return }
        isUpdating = true
        updateMessage = nil
        Task {
            do {
                let list = try await BookSourceUpdater.fetch()
                await MainActor.run {
                    self.replaceAll(with: list)
                    self.isUpdating = false
                    self.updateMessage = "已更新 \(list.count) 个书源"
                }
            } catch {
                await MainActor.run {
                    self.isUpdating = false
                    self.updateMessage = "更新失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 把「阅读/Legado」书源数组转换为 App 模型（原始 JSON 保存在 legadoJSON 中）
    static func makeLegadoSources(from data: Data) -> [BookSource]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !array.isEmpty else { return nil }
        var result: [BookSource] = []
        for object in array {
            guard let name = object["bookSourceName"] as? String, !name.isEmpty,
                  let jsonData = try? JSONSerialization.data(withJSONObject: object),
                  let jsonText = String(data: jsonData, encoding: .utf8) else { continue }
            let source = BookSource(name: name,
                                    baseURL: (object["bookSourceUrl"] as? String) ?? "",
                                    enabled: (object["enabled"] as? Bool) ?? true,
                                    group: object["bookSourceGroup"] as? String,
                                    searchURL: "",
                                    searchListRule: "",
                                    searchNameRule: "",
                                    searchDetailRule: "",
                                    chapterListRule: "",
                                    chapterNameRule: "",
                                    chapterURLRule: "",
                                    contentRule: "",
                                    legadoJSON: jsonText)
            result.append(source)
        }
        return result.isEmpty ? nil : result
    }

    private func save() {
        storage.saveBookSources(sources)
    }
}
