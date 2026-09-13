import Foundation

/// 正则分章（整篇一次正则匹配，避免逐行拆分与桥接）
struct ChapterParser {

    static let maxTitleLength = 50

    static func parse(text: String, bookId: UUID, pattern: String) -> [Chapter] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.anchorsMatchLines]) else {
            return singleChapter(text: text, bookId: bookId)
        }

        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var starts: [Int] = []
        var titles: [String] = []

        regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let result else { return }
            // 取匹配所在整行作为标题
            let lineRange = ns.lineRange(for: result.range)
            let line = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.count <= maxTitleLength else { return }
            starts.append(lineRange.location)
            titles.append(normalizeTitle(line))
        }

        guard !starts.isEmpty else {
            return singleChapter(text: text, bookId: bookId)
        }

        let totalLength = ns.length
        var chapters: [Chapter] = []
        var index = 0

        // 章前内容作为「前言」
        if starts[0] > 0 {
            let preface = ns.substring(to: starts[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty {
                chapters.append(Chapter(bookId: bookId, index: index,
                                        title: "前言", start: 0, end: starts[0]))
                index += 1
            }
        }

        for i in 0..<starts.count {
            let start = starts[i]
            let end = (i + 1 < starts.count) ? starts[i + 1] : totalLength
            chapters.append(Chapter(bookId: bookId, index: index,
                                    title: titles[i], start: start, end: end))
            index += 1
        }
        return chapters
    }

    private static func normalizeTitle(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{3000}", with: " ")
    }

    private static func singleChapter(text: String, bookId: UUID) -> [Chapter] {
        [Chapter(bookId: bookId, index: 0, title: "全文",
                 start: 0, end: (text as NSString).length)]
    }
}
