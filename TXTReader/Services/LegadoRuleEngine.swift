import Foundation
import JavaScriptCore

// MARK: - 极简 HTML DOM（用于 Legado 选择器）

final class LegadoHTMLNode {
    let tag: String
    var attributes: [String: String]
    private(set) var children: [LegadoHTMLNode] = []
    private var textChunks: [String] = []
    weak var parent: LegadoHTMLNode?

    init(tag: String, attributes: [String: String] = [:]) {
        self.tag = tag.lowercased()
        self.attributes = attributes
    }

    func appendChild(_ node: LegadoHTMLNode) {
        node.parent = self
        children.append(node)
    }
    func appendText(_ text: String) { textChunks.append(text) }

    var ownText: String { textChunks.joined() }
    var allText: String { (textChunks + children.map(\.allText)).joined() }

    func attr(_ name: String) -> String? {
        let key = name.lowercased()
        if let v = attributes[key] { return v }
        for (k, v) in attributes where k.lowercased() == key { return v }
        return nil
    }

    var classList: [String] {
        (attr("class") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    func descendants() -> [LegadoHTMLNode] {
        var out: [LegadoHTMLNode] = []
        for child in children {
            out.append(child)
            out.append(contentsOf: child.descendants())
        }
        return out
    }
}

enum LegadoHTMLParser {
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img",
                                                 "input", "link", "meta", "param", "source", "track", "wbr"]

    static func parse(_ html: String) -> LegadoHTMLNode {
        let root = LegadoHTMLNode(tag: "#root")
        var stack: [LegadoHTMLNode] = [root]
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                stack.last?.appendText(decodeEntities(String(html[index..<next])))
                index = next
                continue
            }
            if html[index...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: index..<html.endIndex) {
                    index = end.upperBound
                } else { break }
                continue
            }
            if html[index...].hasPrefix("<!") {
                if let gt = html[index...].firstIndex(of: ">") { index = html.index(after: gt) } else { break }
                continue
            }
            guard let gt = html[index...].firstIndex(of: ">") else { break }
            var content = String(html[html.index(after: index)..<gt]).trimmingCharacters(in: .whitespacesAndNewlines)
            index = html.index(after: gt)

            if content.hasPrefix("/") {
                let name = content.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                if let pos = stack.lastIndex(where: { $0.tag == name }), pos > 0 {
                    stack.removeSubrange(pos..<stack.count)
                }
                continue
            }

            let selfClosing = content.hasSuffix("/")
            if selfClosing { content = String(content.dropLast()) }
            let (tag, attrs) = parseTag(content)
            guard !tag.isEmpty else { continue }
            let node = LegadoHTMLNode(tag: tag, attributes: attrs)
            stack.last?.appendChild(node)

            if tag == "script" || tag == "style" {
                let close = "</" + tag
                if let range = html.range(of: close, options: .caseInsensitive, range: index..<html.endIndex) {
                    node.appendText(String(html[index..<range.lowerBound]))
                    if let end = html[range.lowerBound...].firstIndex(of: ">") {
                        index = html.index(after: end)
                    } else { index = html.endIndex }
                } else { index = html.endIndex }
                continue
            }
            if !selfClosing && !voidTags.contains(tag) {
                stack.append(node)
            }
        }
        return root
    }

    private static func parseTag(_ content: String) -> (String, [String: String]) {
        var tag = ""
        var rest = Substring(content)
        while let c = rest.first, !c.isWhitespace && c != "/" {
            tag.append(c)
            rest = rest.dropFirst()
        }
        var attrs: [String: String] = [:]
        var s = rest
        while !s.isEmpty {
            while let c = s.first, c.isWhitespace { s = s.dropFirst() }
            if s.isEmpty { break }
            var name = ""
            while let c = s.first, c != "=" && !c.isWhitespace { name.append(c); s = s.dropFirst() }
            while let c = s.first, c.isWhitespace { s = s.dropFirst() }
            if s.first == "=" {
                s = s.dropFirst()
                while let c = s.first, c.isWhitespace { s = s.dropFirst() }
                var value = ""
                if let quote = s.first, quote == "\"" || quote == "'" {
                    s = s.dropFirst()
                    while let c = s.first, c != quote { value.append(c); s = s.dropFirst() }
                    if s.first == quote { s = s.dropFirst() }
                } else {
                    while let c = s.first, !c.isWhitespace { value.append(c); s = s.dropFirst() }
                }
                attrs[name.lowercased()] = decodeEntities(value)
            } else if !name.isEmpty {
                attrs[name.lowercased()] = ""
            }
        }
        return (tag.lowercased(), attrs)
    }

    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let named = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
                     "apos": "'", "ldquo": "“", "rdquo": "”", "hellip": "…", "mdash": "—"]
        var result = ""
        var i = string.startIndex
        while i < string.endIndex {
            guard string[i] == "&", let semi = string[i...].firstIndex(of: ";"),
                  string.distance(from: i, to: semi) <= 12 else {
                result.append(string[i]); i = string.index(after: i); continue
            }
            let body = String(string[string.index(after: i)..<semi])
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let v = UInt32(body.dropFirst(2), radix: 16) { decoded = String(UnicodeScalar(v) ?? " ") }
            } else if body.hasPrefix("#") {
                if let v = UInt32(body.dropFirst()) { decoded = String(UnicodeScalar(v) ?? " ") }
            } else if let v = named[body.lowercased()] {
                decoded = v
            }
            if let decoded {
                result.append(decoded)
                i = string.index(after: semi)
            } else {
                result.append(string[i]); i = string.index(after: i)
            }
        }
        return result
    }
}

// MARK: - 选择器

enum LegadoSelector {
    struct Simple {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attributes: [(String, String?)] = []
        var containsText: String?
        var index: Int?
    }

    /// 把 Legado 默认写法 class.x / id.x / tag.x 以及 CSS 复合选择器解析为 Simple
    static func parse(_ raw: String) -> Simple {
        var selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var simple = Simple()

        // 末尾 .N 作为索引
        if !selector.contains("["), let dot = selector.lastIndex(of: ".") {
            let tail = String(selector[selector.index(after: dot)...])
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber }), selector[dot...] != "." {
                // 避免把 class. 的名字误判：仅当点后全是数字
                if let n = Int(tail) {
                    simple.index = n
                    selector = String(selector[..<dot])
                }
            }
        }

        if selector.hasPrefix("class.") {
            selector = "." + selector.dropFirst("class.".count)
        } else if selector.hasPrefix("id.") {
            selector = "#" + selector.dropFirst("id.".count)
        } else if selector.hasPrefix("tag.") {
            selector = String(selector.dropFirst("tag.".count))
        } else if selector.hasPrefix("text.") {
            simple.containsText = String(selector.dropFirst("text.".count))
            return simple
        }

        var token = Substring(selector)
        // 前导 tag
        if let first = token.first, first != "." && first != "#" && first != "[" {
            var name = ""
            while let c = token.first, c != "." && c != "#" && c != "[" {
                name.append(c); token = token.dropFirst()
            }
            if !name.isEmpty { simple.tag = name.lowercased() }
        }
        while let first = token.first {
            if first == "." {
                token = token.dropFirst()
                var name = ""
                while let c = token.first, c != "." && c != "#" && c != "[" {
                    name.append(c); token = token.dropFirst()
                }
                if !name.isEmpty { simple.classes.append(name) }
            } else if first == "#" {
                token = token.dropFirst()
                var name = ""
                while let c = token.first, c != "." && c != "#" && c != "[" {
                    name.append(c); token = token.dropFirst()
                }
                simple.id = name
            } else if first == "[" {
                guard let close = token.firstIndex(of: "]") else { break }
                let body = String(token[token.index(after: token.startIndex)..<close])
                token = token[token.index(after: close)...]
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
                    var value = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    simple.attributes.append((key.lowercased(), value))
                } else {
                    simple.attributes.append((body.trimmingCharacters(in: .whitespaces).lowercased(), nil))
                }
            } else {
                token = token.dropFirst()
            }
        }
        return simple
    }

    static func matches(_ node: LegadoHTMLNode, _ simple: Simple) -> Bool {
        if let tag = simple.tag, node.tag != tag { return false }
        if let id = simple.id, node.attr("id") != id { return false }
        for cls in simple.classes where !node.classList.contains(cls) { return false }
        for (key, value) in simple.attributes {
            guard let actual = node.attr(key) else { return false }
            if let value, actual != value { return false }
        }
        if let text = simple.containsText, !node.allText.contains(text) { return false }
        return true
    }

    /// 在给定节点的后代中查找（不含节点自身）
    static func select(_ selector: String, in nodes: [LegadoHTMLNode]) -> [LegadoHTMLNode] {
        let simple = parse(selector)
        var matched: [LegadoHTMLNode] = []
        for node in nodes {
            for d in node.descendants() where matches(d, simple) {
                matched.append(d)
            }
        }
        if let index = simple.index {
            if index >= 0 {
                return index < matched.count ? [matched[index]] : []
            }
            let back = matched.count + index
            return back >= 0 && back < matched.count ? [matched[back]] : []
        }
        return matched
    }
}
