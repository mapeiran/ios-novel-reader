import Foundation

/// 在线搜索结果
struct OnlineSearchResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let author: String
    let cover: String?
    let detailURL: String
}

/// 在线章节
struct OnlineChapter: Identifiable, Codable, Hashable {
    let id = UUID()
    let name: String
    let url: String
}

enum BookSourceError: LocalizedError {
    case badURL
    case network(String)
    case noResult
    case ruleMissing

    var errorDescription: String? {
        switch self {
        case .badURL:       return "书源地址无效。"
        case .network(let m): return "网络错误：\(m)"
        case .noResult:     return "未找到结果。"
        case .ruleMissing:  return "书源规则缺失或不匹配。"
        }
    }
}

/// 书源抓取服务（正则规则）
final class BookSourceService {

    // MARK: - 搜索

    func search(keyword: String, source: BookSource) async throws -> [OnlineSearchResult] {
        if let legadoJSON = source.legadoJSON, let engine = LegadoRuleEngine(sourceJSON: legadoJSON) {
            return try await engine.search(keyword: keyword)
        }
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw BookSourceError.badURL
        }
        let urlString = source.searchURL
            .replacingOccurrences(of: "{key}", with: encoded)
            .replacingOccurrences(of: "{page}", with: "1")
        let html = try await fetch(urlString, charset: source.charset)

        let items = captures(source.searchListRule, in: html)
        guard !items.isEmpty else { throw BookSourceError.noResult }

        var results: [OnlineSearchResult] = []
        for item in items {
            let name = decode(capture(source.searchNameRule, in: item) ?? "")
            let author = decode(capture(source.searchAuthorRule ?? "", in: item) ?? "")
            let cover = capture(source.searchCoverRule ?? "", in: item).map { absolute($0, base: source.baseURL) }
            guard let detail = capture(source.searchDetailRule, in: item) else { continue }
            results.append(OnlineSearchResult(name: name.isEmpty ? "未知" : name,
                                              author: author,
                                              cover: cover,
                                              detailURL: absolute(detail, base: source.baseURL)))
        }
        guard !results.isEmpty else { throw BookSourceError.noResult }
        return results
    }

    // MARK: - 多源聚合搜索

    struct AggregatedResult: Identifiable {
        let id = UUID()
        let sourceID: UUID
        let sourceName: String
        let result: OnlineSearchResult
    }

    /// 并发查询多个书源，聚合结果
    func searchAll(keyword: String, sources: [BookSource]) async -> [AggregatedResult] {
        await withTaskGroup(of: (BookSource, [OnlineSearchResult]).self) { group in
            for source in sources {
                group.addTask {
                    let results = (try? await self.search(keyword: keyword, source: source)) ?? []
                    return (source, results)
                }
            }
            var aggregated: [AggregatedResult] = []
            for await (source, results) in group {
                for result in results {
                    aggregated.append(AggregatedResult(sourceID: source.id,
                                                       sourceName: source.name,
                                                       result: result))
                }
            }
            return aggregated.sorted { lhs, rhs in
                let ls = Self.relevanceScore(name: lhs.result.name,
                                             author: lhs.result.author,
                                             keyword: keyword)
                let rs = Self.relevanceScore(name: rhs.result.name,
                                             author: rhs.result.author,
                                             keyword: keyword)
                if ls != rs { return ls > rs }
                return lhs.result.name.localizedStandardCompare(rhs.result.name) == .orderedAscending
            }
        }
    }

    /// 与搜索词的相关度评分：书名精确 > 前缀 > 包含 > 作者匹配 > 字符覆盖；越短、匹配越靠前分越高
    static func relevanceScore(name: String, author: String, keyword: String) -> Double {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return 0 }
        let title = name.lowercased()
        let writer = author.lowercased()

        if title == kw { return 1000 }

        var score: Double = 0
        if title.hasPrefix(kw) {
            score += 600
        } else if title.contains(kw) {
            score += 400
        } else if writer == kw {
            score += 350
        } else if writer.contains(kw) {
            score += 150
        }

        // 关键词字符在书名中的覆盖率
        let chars = Array(kw)
        if !chars.isEmpty {
            let covered = chars.filter { title.contains($0) }.count
            score += Double(covered) / Double(chars.count) * 100
        }
        // 匹配位置越靠前越相关
        if let range = title.range(of: kw) {
            let position = title.distance(from: title.startIndex, to: range.lowerBound)
            score -= Double(position) * 3
        }
        // 书名越短越相关
        score -= Double(title.count) * 0.5
        return score
    }

    // MARK: - 书源测速

    struct SourceHealth {
        let ok: Bool
        let latency: Double
        let message: String?
    }

    func test(_ source: BookSource) async -> SourceHealth {
        let start = Date()
        if let legadoJSON = source.legadoJSON, let engine = LegadoRuleEngine(sourceJSON: legadoJSON) {
            do {
                _ = try await engine.search(keyword: "测试")
                return SourceHealth(ok: true, latency: Date().timeIntervalSince(start), message: nil)
            } catch {
                return SourceHealth(ok: false, latency: Date().timeIntervalSince(start),
                                    message: error.localizedDescription)
            }
        }
        do {
            let urlString = source.searchURL
                .replacingOccurrences(of: "{key}", with: "测试")
                .replacingOccurrences(of: "{page}", with: "1")
            let html = try await fetch(urlString, charset: source.charset)
            let latency = Date().timeIntervalSince(start)
            let ok = !html.isEmpty
            return SourceHealth(ok: ok, latency: latency, message: ok ? nil : "空响应")
        } catch {
            return SourceHealth(ok: false, latency: Date().timeIntervalSince(start),
                                message: error.localizedDescription)
        }
    }

    // MARK: - 目录

    func chapters(detailURL: String, source: BookSource) async throws -> [OnlineChapter] {
        if let legadoJSON = source.legadoJSON, let engine = LegadoRuleEngine(sourceJSON: legadoJSON) {
            return try await engine.chapters(detailURL: detailURL)
        }
        let html = try await fetch(detailURL, charset: source.charset)
        let items = captures(source.chapterListRule, in: html)
        var chapters: [OnlineChapter] = []
        for item in items {
            guard let name = capture(source.chapterNameRule, in: item),
                  let link = capture(source.chapterURLRule, in: item) else { continue }
            chapters.append(OnlineChapter(name: decode(name),
                                          url: absolute(link, base: detailURL)))
        }
        guard !chapters.isEmpty else { throw BookSourceError.noResult }
        return chapters
    }

    // MARK: - 正文

    func content(chapterURL: String, source: BookSource) async throws -> String {
        if let legadoJSON = source.legadoJSON, let engine = LegadoRuleEngine(sourceJSON: legadoJSON) {
            return try await engine.content(chapterURL: chapterURL)
        }
        let html = try await fetch(chapterURL, charset: source.charset)
        let raw = capture(source.contentRule, in: html) ?? html
        return stripHTML(raw)
    }

    // MARK: - 网络

    private func fetch(_ urlString: String, charset: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw BookSourceError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let encoding: String.Encoding = charset.lowercased().contains("gb") ? EncodingDetector.gb18030 : .utf8
            if let text = String(data: data, encoding: encoding) {
                return text
            }
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            throw BookSourceError.network("解码失败")
        } catch {
            throw BookSourceError.network(error.localizedDescription)
        }
    }

    // MARK: - 正则

    private func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              group < match.numberOfRanges,
              let r = Range(match.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    private func captures(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard group < match.numberOfRanges,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    private func absolute(_ link: String, base: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        guard let baseURL = URL(string: base) else { return trimmed }
        if trimmed.hasPrefix("/") {
            return "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(trimmed)"
        }
        return baseURL.deletingLastPathComponent().appendingPathComponent(trimmed).absoluteString
    }

    // MARK: - HTML 处理

    func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decode(text)
        // 规范空白与空行
        text = text.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decode(_ string: String) -> String {
        var result = string
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { result = result.replacingOccurrences(of: k, with: v) }
        return result
    }
}
