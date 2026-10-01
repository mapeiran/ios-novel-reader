import Foundation
import JavaScriptCore

extension LegadoHTMLNode {
    /// 还原 innerHTML（用于 @html 抽取）
    var innerHTML: String {
        var out = ownText
        for child in children { out += child.outerHTML }
        return out
    }
    var outerHTML: String {
        var s = "<" + tag
        for (k, v) in attributes {
            if v.isEmpty { s += " \(k)" } else { s += " \(k)=\"\(v)\"" }
        }
        s += ">" + innerHTML + "</" + tag + ">"
        return s
    }
}

// MARK: - JSONPath（够用子集：$.a.b[*].c / $..c / $.a[0]）

enum LegadoJSON {
    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private enum Step {
        case key(String)
        case index(Int)
        case wildcard
        case recursive(String)
    }

    private static func tokenize(_ path: String) -> [Step] {
        var steps: [Step] = []
        var chars = Array(path)
        var i = 0
        func readName() -> String {
            var s = ""
            while i < chars.count, chars[i] != ".", chars[i] != "[" {
                s.append(chars[i]); i += 1
            }
            return s
        }
        while i < chars.count {
            if chars[i] == "." {
                if i + 1 < chars.count, chars[i + 1] == "." {
                    i += 2
                    let name = readName()
                    steps.append(.recursive(name))
                } else {
                    i += 1
                    let name = readName()
                    if name == "*" { steps.append(.wildcard) }
                    else if !name.isEmpty { steps.append(.key(name)) }
                }
            } else if chars[i] == "[" {
                var body = ""
                i += 1
                while i < chars.count, chars[i] != "]" { body.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
                if body == "*" { steps.append(.wildcard) }
                else if let n = Int(body) { steps.append(.index(n)) }
                else { steps.append(.key(body.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))) }
            } else {
                let name = readName()
                if name == "*" { steps.append(.wildcard) }
                else if !name.isEmpty { steps.append(.key(name)) }
            }
        }
        return steps
    }

    static func query(_ path: String, in json: Any) -> [Any] {
        var p = path
        if p.hasPrefix("$") { p.removeFirst() }
        let steps = tokenize(p)
        var current: [Any] = [json]
        for step in steps {
            var next: [Any] = []
            switch step {
            case .key(let k):
                for v in current { if let d = v as? [String: Any], let x = d[k] { next.append(x) } }
            case .index(let idx):
                for v in current { if let a = v as? [Any], idx >= 0, idx < a.count { next.append(a[idx]) } }
            case .wildcard:
                for v in current {
                    if let a = v as? [Any] { next.append(contentsOf: a) }
                    else if let d = v as? [String: Any] { next.append(contentsOf: d.values) }
                }
            case .recursive(let k):
                for v in current { next.append(contentsOf: recursiveFind(k, in: v)) }
            }
            current = next
        }
        return current
    }

    private static func recursiveFind(_ key: String, in value: Any) -> [Any] {
        var out: [Any] = []
        if let d = value as? [String: Any] {
            if let v = d[key] { out.append(v) }
            for (_, v) in d { out.append(contentsOf: recursiveFind(key, in: v)) }
        } else if let a = value as? [Any] {
            for v in a { out.append(contentsOf: recursiveFind(key, in: v)) }
        }
        return out
    }

    static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let a = value as? [Any], let first = a.first { return stringify(first) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return nil
    }
}

// MARK: - Legado 规则引擎

final class LegadoRuleEngine {

    private let raw: [String: Any]
    let baseURL: String

    init?(sourceJSON: String) {
        guard let data = sourceJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.raw = obj
        self.baseURL = (obj["bookSourceUrl"] as? String) ?? ""
    }

    init(raw: [String: Any]) {
        self.raw = raw
        self.baseURL = (raw["bookSourceUrl"] as? String) ?? ""
    }

    var name: String { (raw["bookSourceName"] as? String) ?? "未命名" }

    private func rule(_ section: String, _ key: String) -> String? {
        guard let dict = raw[section] as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    private var headers: [String: String] {
        var result: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        if let header = raw["header"] as? String, !header.isEmpty {
            let wrapped = "{" + header + "}"
            if let data = wrapped.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (k, v) in obj { if let s = v as? String { result[k] = s } }
            }
        }
        return result
    }

    // MARK: 公共入口

    func search(keyword: String, page: Int = 1) async throws -> [OnlineSearchResult] {
        let listRule = rule("ruleSearch", "bookList")
        let searchURLRule = (raw["searchUrl"] as? String) ?? ""
        let urlString = try resolveURL(searchURLRule, key: keyword, page: page)
        let html = try await fetch(urlString)

        let items = selectNodes(listRule, html: html)
        guard !items.isEmpty else { throw BookSourceError.noResult }

        var results: [OnlineSearchResult] = []
        for item in items {
            let itemHTML = item.outerHTML
            let name = decode(resolveString(rule("ruleSearch", "name"), html: itemHTML) ?? "")
            let author = decode(resolveString(rule("ruleSearch", "author"), html: itemHTML) ?? "")
            let cover = resolveString(rule("ruleSearch", "coverUrl"), html: itemHTML)
                .map { absolute($0, base: urlString) }
            guard let detail = resolveString(rule("ruleSearch", "bookUrl"), html: itemHTML),
                  !detail.isEmpty else { continue }
            results.append(OnlineSearchResult(name: name.isEmpty ? "未知" : name,
                                              author: author,
                                              cover: cover,
                                              detailURL: absolute(detail, base: urlString)))
        }
        guard !results.isEmpty else { throw BookSourceError.noResult }
        return results
    }

    func chapters(detailURL: String) async throws -> [OnlineChapter] {
        let html = try await fetch(detailURL)
        let items = selectNodes(rule("ruleToc", "chapterList"), html: html)
        var chapters: [OnlineChapter] = []
        for item in items {
            let itemHTML = item.outerHTML
            guard let name = resolveString(rule("ruleToc", "chapterName"), html: itemHTML),
                  let link = resolveString(rule("ruleToc", "chapterUrl"), html: itemHTML) else { continue }
            chapters.append(OnlineChapter(name: decode(name), url: absolute(link, base: detailURL)))
        }
        guard !chapters.isEmpty else { throw BookSourceError.noResult }
        return chapters
    }

    func content(chapterURL: String) async throws -> String {
        let html = try await fetch(chapterURL)
        let contentRule = rule("ruleContent", "content") ?? ""
        if contentRule.isEmpty { return stripHTML(html) }
        let extracted = resolveString(contentRule, html: html) ?? ""
        return stripHTML(extracted)
    }

    // MARK: URL

    private func resolveURL(_ rule: String, key: String, page: Int) throws -> String {
        if rule.hasPrefix("@js:") {
            let script = String(rule.dropFirst(4))
            let value = evaluateJS(script, result: "", key: key, page: page)
            guard let url = value?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                throw BookSourceError.badURL
            }
            return url
        }
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        var url = rule.replacingOccurrences(of: "{{key}}", with: encoded)
            .replacingOccurrences(of: "{{page}}", with: String(page))
            .replacingOccurrences(of: "{key}", with: encoded)
            .replacingOccurrences(of: "{page}", with: String(page))
        if url.hasPrefix("//") { url = "https:" + url }
        if !url.lowercased().hasPrefix("http") { url = absolute(url, base: baseURL) }
        return url
    }

    // MARK: 规则解析

    private enum TerminalKind { case text, ownText, html, attribute(String) }

    private func terminal(_ part: String) -> TerminalKind? {
        switch part.lowercased() {
        case "text", "all", "textnodes":        return .text
        case "owntext":                         return .ownText
        case "html":                            return .html
        default:
            // 纯标识符视为属性名
            if part.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil {
                return .attribute(part)
            }
            return nil
        }
    }

    /// 解析字符串规则
    func resolveString(_ rule: String?, html: String) -> String? {
        guard var rule, !rule.isEmpty else { return nil }
        rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)

        // 多规则备选
        if rule.contains("||") {
            for alt in rule.components(separatedBy: "||") {
                if let v = resolveString(alt, html: html), !v.isEmpty { return v }
            }
            return nil
        }

        // ## 正则替换
        var postRegex: String?
        var postReplacement = ""
        if rule.contains("##") {
            let parts = rule.components(separatedBy: "##")
            rule = parts[0]
            if parts.count > 1 { postRegex = parts[1] }
            if parts.count > 2 { postReplacement = parts[2] }
        }

        var result: String?
        if rule.hasPrefix("@js:") {
            result = evaluateJS(String(rule.dropFirst(4)), result: html, key: "", page: 1)
        } else if rule.hasPrefix("$") {
            if let json = LegadoJSON.parse(html) {
                result = LegadoJSON.stringify(LegadoJSON.query(rule, in: json))
            }
        } else {
            result = selectAndExtract(rule, html: html)
        }

        if let postRegex, let value = result, !postRegex.isEmpty {
            if let regex = try? NSRegularExpression(pattern: postRegex) {
                let range = NSRange(location: 0, length: (value as NSString).length)
                result = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: postReplacement)
            }
        }
        return result?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectAndExtract(_ rule: String, html: String) -> String? {
        let parts = rule.components(separatedBy: "@")
        var current: [LegadoHTMLNode] = [LegadoHTMLParser.parse(html)]
        var index: Int?
        var sawSelector = false

        for (i, rawPart) in parts.enumerated() {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if i > 0, let n = Int(part) { index = n; continue }
            if i > 0, let kind = terminal(part) {
                return apply(kind, to: current, index: index)
            }
            current = LegadoSelect(nodeList: current, selector: part)
            sawSelector = true
        }
        if sawSelector || !current.isEmpty {
            return apply(.text, to: current, index: index)
        }
        return nil
    }

    private func LegadoSelect(nodeList: [LegadoHTMLNode], selector: String) -> [LegadoHTMLNode] {
        var sel = selector
        if sel.hasPrefix("@css:") { sel = String(sel.dropFirst(5)) }
        if sel.hasPrefix("//") { sel = xpathToSelector(sel) }
        return LegadoSelector.select(sel, in: nodeList)
    }

    private func apply(_ kind: TerminalKind, to nodes: [LegadoHTMLNode], index: Int?) -> String? {
        var list = nodes
        if let index, index >= 0, index < list.count { list = [list[index]] }
        let values: [String] = list.compactMap { node in
            switch kind {
            case .text:              return node.allText
            case .ownText:           return node.ownText
            case .html:              return node.innerHTML
            case .attribute(let a):
                if a.lowercased() == "content" { return node.allText }
                return node.attr(a)
            }
        }
        let joined = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// 选择节点（bookList / chapterList）
    func selectNodes(_ rule: String?, html: String) -> [LegadoHTMLNode] {
        guard var rule, !rule.isEmpty else { return [] }
        rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.contains("||") {
            for alt in rule.components(separatedBy: "||") {
                let nodes = selectNodes(alt, html: html)
                if !nodes.isEmpty { return nodes }
            }
            return []
        }
        var current: [LegadoHTMLNode] = [LegadoHTMLParser.parse(html)]
        var index: Int?
        for (i, rawPart) in rule.components(separatedBy: "@").enumerated() {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if i > 0, let n = Int(part) { index = n; continue }
            if i > 0, terminal(part) != nil { continue }
            current = LegadoSelect(nodeList: current, selector: part)
        }
        if let index, index >= 0, index < current.count { return [current[index]] }
        return current
    }

    private func xpathToSelector(_ xpath: String) -> String {
        // 极简 XPath：//tag / //tag[@attr="v"] / //*[@id="v"] / //tag/child
        var path = xpath
        var parts: [String] = []
        for seg in path.components(separatedBy: "/") where !seg.isEmpty {
            var selector = ""
            var tag = "."
            if let bracket = seg.firstIndex(of: "[") {
                let tagPart = String(seg[..<bracket])
                let predPart = String(seg[bracket...])
                if !tagPart.isEmpty, tagPart != "*" { tag = tagPart }
                if let eq = predPart.firstIndex(of: "=") {
                    let key = predPart[predPart.index(after: predPart.startIndex)..<eq]
                        .replacingOccurrences(of: "@", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                    var value = String(predPart[predPart.index(after: eq)...])
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]"))
                    selector = (tag == "." ? "" : tag) + "[\(key)=\"\(value)\"]"
                } else {
                    selector = tag
                }
            } else {
                selector = (seg == "*" ? "" : seg)
            }
            if !selector.isEmpty { parts.append(selector) }
        }
        path = parts.isEmpty ? "*" : parts.joined(separator: " ")
        return path
    }

    // MARK: JS

    private func evaluateJS(_ script: String, result: String, key: String, page: Int) -> String? {
        guard let context = JSContext() else { return nil }
        var logs: [String] = []
        let fetchSync: (String, String?) -> String? = { [weak self] url, _ in
            self?.fetchSync(url)
        }
        LegadoJS.install(context: context, source: raw, baseURL: baseURL, fetchSync: fetchSync, log: { logs.append($0) })
        context.setObject(result, forKeyedSubscript: "result" as NSString)
        context.setObject(key, forKeyedSubscript: "key" as NSString)
        context.setObject(page, forKeyedSubscript: "page" as NSString)
        context.setObject(baseURL, forKeyedSubscript: "baseUrl" as NSString)
        context.exception = nil
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            LegadoLog.shared.append("[JS] \(exception.toString() ?? "unknown")")
            return nil
        }
        if value?.isString == true { return value?.toString() }
        if value?.isNumber == true { return value?.toString() }
        return value?.toString()
    }

    // MARK: 网络

    func fetch(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw BookSourceError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let text = String(data: data, encoding: .utf8) { return text }
            if let text = String(data: data, encoding: EncodingDetector.gb18030) { return text }
            throw BookSourceError.network("解码失败")
        } catch let error as BookSourceError {
            throw error
        } catch {
            throw BookSourceError.network(error.localizedDescription)
        }
    }

    func fetchSync(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        var output: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data {
                output = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: EncodingDetector.gb18030)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return output
    }

    // MARK: 工具

    func absolute(_ link: String, base: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("data:") { return trimmed }
        guard let baseURL = URL(string: base) else { return trimmed }
        if trimmed.hasPrefix("/") {
            return "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(trimmed)"
        }
        return baseURL.deletingLastPathComponent().appendingPathComponent(trimmed).absoluteString
    }

    func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = LegadoHTMLParser.decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decode(_ string: String) -> String { LegadoHTMLParser.decodeEntities(string) }
}

// MARK: - 运行日志（便于排查规则问题）

final class LegadoLog {
    static let shared = LegadoLog()
    private let lock = NSLock()
    private(set) var lines: [String] = []
    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        lock.unlock()
    }
    func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}
