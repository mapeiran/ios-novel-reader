import Foundation

// MARK: - 对外模型与协议（TextSegmentation 模块入口）

/// 分段后的一章
public struct SegmentedChapter: Codable, Hashable, Sendable {
    public let index: Int
    public let title: String
    public let paragraphs: [String]

    public init(index: Int, title: String, paragraphs: [String]) {
        self.index = index
        self.title = title
        self.paragraphs = paragraphs
    }
}

/// 分段密度预设
public enum SegmentDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case loose

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact:  return "紧凑"
        case .standard: return "标准"
        case .loose:    return "松散"
        }
    }

    public var minLength: Int {
        switch self {
        case .compact:  return 150
        case .standard: return 100
        case .loose:    return 60
        }
    }

    public var maxLength: Int {
        switch self {
        case .compact:  return 600
        case .standard: return 400
        case .loose:    return 250
        }
    }

    public var similarityThreshold: Double {
        switch self {
        case .compact:  return 0.70
        case .standard: return 0.60
        case .loose:    return 0.50
        }
    }
}

/// 分段配置
public struct SegmentConfig: Codable, Equatable, Sendable {
    public var density: SegmentDensity = .standard
    public var enableSemantic: Bool = true
    public var minLength: Int = 100
    public var maxLength: Int = 400
    public var similarityThreshold: Double = 0.60
    public var chapterPattern: String = SegmentConfig.defaultChapterPattern

    public init() {}

    public static let `default` = SegmentConfig()

    public static let defaultChapterPattern =
        #"^(第[一二三四五六七八九十百千万0-9]+[章节回卷部篇]|Chapter [0-9]+|Part [0-9]+).{0,40}$"#

    /// 应用密度预设（同时覆盖 min/max/阈值）
    public mutating func applyDensity(_ density: SegmentDensity) {
        self.density = density
        minLength = density.minLength
        maxLength = density.maxLength
        similarityThreshold = density.similarityThreshold
    }
}

/// 语义相似度打分（可插拔；默认用字符 bigram 相似度，Core ML 模型可替换）
public protocol SemanticScoring: Sendable {
    /// 返回 0~1 的相似度
    func similarity(_ a: String, _ b: String) -> Double
}

/// 分段缓存（可选注入）
public protocol SegmentCacheProtocol: AnyObject, Sendable {
    func load(bookId: String, version: Int) -> [SegmentedChapter]?
    func save(bookId: String, version: Int, chapters: [SegmentedChapter])
    func clear(bookId: String)
}

/// 分段错误
public enum SegmentError: LocalizedError {
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .emptyText: return "文本为空，无法分段。"
        }
    }
}

/// 模块唯一入口协议
public protocol TextSegmenting: Sendable {
    func segment(text: String, config: SegmentConfig) async throws -> [String]
    func segmentBook(text: String,
                     config: SegmentConfig,
                     progress: ((Double) -> Void)?) async throws -> [SegmentedChapter]
}

// MARK: - 默认语义实现（无需模型，自动降级）

/// 字符二元组 Jaccard 相似度：无需模型，速度很快
public struct LexicalSimilarityScorer: SemanticScoring {
    public init() {}

    public func similarity(_ a: String, _ b: String) -> Double {
        let sa = bigrams(a)
        let sb = bigrams(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private func bigrams(_ text: String) -> Set<String> {
        let chars = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let array = Array(chars)
        guard array.count >= 2 else { return Set(array.map(String.init)) }
        var set = Set<String>()
        for i in 0..<(array.count - 1) {
            set.insert(String(array[i...i + 1]))
        }
        return set
    }
}

// MARK: - JSON 文件缓存

/// 默认缓存实现：按 bookId + 版本号落 JSON（可在主 App 中替换为数据库适配）
public final class JSONSegmentCache: SegmentCacheProtocol, @unchecked Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(bookId: String, version: Int) -> URL {
        directory.appendingPathComponent("segments-" + bookId + "-v" + String(version) + ".json")
    }

    public func load(bookId: String, version: Int) -> [SegmentedChapter]? {
        guard let data = try? Data(contentsOf: fileURL(bookId: bookId, version: version)) else { return nil }
        return try? JSONDecoder().decode([SegmentedChapter].self, from: data)
    }

    public func save(bookId: String, version: Int, chapters: [SegmentedChapter]) {
        guard let data = try? JSONEncoder().encode(chapters) else { return }
        try? data.write(to: fileURL(bookId: bookId, version: version), options: .atomic)
    }

    public func clear(bookId: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("segments-" + bookId + "-") {
            try? fm.removeItem(at: file)
        }
    }
}
