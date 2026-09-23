import Foundation

/// 格式化选项
struct FormatOptions: Codable, Equatable {
    /// 空行规整（连续空行合并为单空行、去首尾空白）
    var normalizeBlankLines = true
    /// 去除行首尾空白 / 制表符
    var trimWhitespace = true
    /// 清洗乱码 / 无效字符
    var cleanGarbage = true
    /// 合并被切割的段落
    var mergeBrokenParagraphs = true
    /// 章节智能识别（标题独立成行 + 目录）
    var detectChapters = true
    /// 广告垃圾文本清理
    var cleanAds = true
    /// 中英文标点标准化（可选）
    var normalizePunctuation = false
    /// 段落首行缩进 2 字符（可选）
    var indentParagraphs = false
    /// 去除多余空格 / TAB
    var removeExtraSpaces = true

    var chapterPattern: String = ChapterRule.defaultPattern
}

/// 格式化统计
struct FormatStats {
    var originalChars = 0
    var formattedChars = 0
    var blankLinesRemoved = 0
    var paragraphsMerged = 0
    var adsRemoved = 0
    var garbageLines = 0
    var chapters = 0
    var log: [String] = []
}

struct FormatResult {
    var text: String
    var stats: FormatStats
}

/// TXT 智能格式化引擎（预编译正则，纯函数，便于测试）
enum TextFormatter {

    private static let blankSet = CharacterSet(charactersIn: " \t\u{3000}")

    private static let garbageRegex = try? NSRegularExpression(
        pattern: "[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\uFFFD\\u200B-\\u200F\\uFEFF]")

    private static let spaceRegex = try? NSRegularExpression(pattern: "[ \t\u{3000}]{2,}")

    /// 合并为单个广告正则（一次匹配/行，避免逐条正则）
    private static let adRegex: NSRegularExpression? = {
        let keywords = [
            "本章未完", "请记住本站", "本书首发", "最新章节", "更新最快",
            "手机版", "手机阅读", "阅读网址", "加入书签", "加入书架",
            "方便阅读", "天才一秒记住", "一秒记住", "笔趣", "顶点", "燃文", "无弹窗",
            "求收藏", "求推荐", "求月票", "求订阅", "本站首发", "首发地址",
            "https?://", "www\\.[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
            "[a-zA-Z0-9-]+\\.(com|cn|net|org)",
        ]
        return try? NSRegularExpression(pattern: keywords.joined(separator: "|"),
                                        options: [.caseInsensitive])
    }()

    // MARK: - 入口

    static func format(_ raw: String, options: FormatOptions) -> FormatResult {
        var stats = FormatStats()

        // 1. 规范化换行 + 去 BOM
        var text = EncodingDetector.normalize(raw)
        stats.originalChars = (text as NSString).length

        let chapterRegex = try? NSRegularExpression(pattern: options.chapterPattern)

        // 2. 广告清理
        if options.cleanAds {
            let (cleaned, count) = removeAds(text)
            text = cleaned
            stats.adsRemoved = count
            if count > 0 { stats.log.append("清理广告行 \(count) 行") }
        }

        // 3. 逐行清洗 + 段落合并
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for original in lines {
            var line = original

            if options.trimWhitespace {
                line = line.trimmingCharacters(in: blankSet)
            }
            if options.cleanGarbage, let regex = garbageRegex {
                let range = NSRange(location: 0, length: (line as NSString).length)
                line = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
            }
            if options.removeExtraSpaces, let regex = spaceRegex {
                let range = NSRange(location: 0, length: (line as NSString).length)
                line = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: " ")
            }

            // 空行
            if line.isEmpty {
                if options.normalizeBlankLines {
                    if let last = out.last, !last.isEmpty {
                        out.append("")
                    } else {
                        stats.blankLinesRemoved += 1
                    }
                } else {
                    out.append("")
                }
                continue
            }

            let isTitle = options.detectChapters && isChapterTitle(line, regex: chapterRegex)

            if isTitle {
                if out.last != "" { out.append("") }
                out.append(line)
                continue
            }

            // 合并被切割的段落
            if options.mergeBrokenParagraphs,
               let last = out.last, !last.isEmpty,
               !(options.detectChapters && isChapterTitle(last, regex: chapterRegex)),
               !endsWithSentencePunctuation(last) {
                out[out.count - 1] = last + line
                stats.paragraphsMerged += 1
            } else {
                out.append(line)
            }
        }

        var body = out.joined(separator: "\n")

        // 4. 标点标准化
        if options.normalizePunctuation {
            body = normalizePunctuation(body)
            stats.log.append("标点标准化已应用")
        }

        // 5. 段落缩进
        if options.indentParagraphs {
            body = indent(body, options: options, chapterRegex: chapterRegex)
            stats.log.append("首行缩进已应用")
        }

        // 6. 章节统计
        let chapters = ChapterParser.parse(text: body, bookId: UUID(), pattern: options.chapterPattern)
        stats.chapters = chapters.count
        stats.formattedChars = (body as NSString).length
        if stats.paragraphsMerged > 0 { stats.log.append("合并断行 \(stats.paragraphsMerged) 处") }
        if stats.garbageLines > 0 { stats.log.append("清洗异常字符 \(stats.garbageLines) 行") }
        stats.log.append("识别章节 \(stats.chapters) 章")

        return FormatResult(text: body, stats: stats)
    }

    // MARK: - 规则实现

    private static func removeAds(_ text: String) -> (String, Int) {
        guard let regex = adRegex else { return (text, 0) }
        var count = 0
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: blankSet)
            if !trimmed.isEmpty {
                let range = NSRange(location: 0, length: (trimmed as NSString).length)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    count += 1
                    continue
                }
            }
            kept.append(line)
        }
        return (kept.joined(separator: "\n"), count)
    }

    static func isChapterTitle(_ line: String) -> Bool {
        isChapterTitle(line, regex: try? NSRegularExpression(pattern: ChapterRule.defaultPattern))
    }

    private static func isChapterTitle(_ line: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        guard !line.isEmpty, line.count <= 50 else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, options: [.anchored], range: range) != nil
    }

    private static func endsWithSentencePunctuation(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return "。！？…\"”』」）】.!?".contains(last)
    }

    private static func normalizePunctuation(_ text: String) -> String {
        var result = text
        let map: [(String, String)] = [
            (",", "，"), ("\\.", "。"), ("!", "！"), ("\\?", "？"),
            (":", "："), (";", "；"),
        ]
        for (ascii, full) in map {
            let pattern = "(?<=[\\u4e00-\\u9fff])\(ascii)(?=[\\u4e00-\\u9fff])"
            result = result.replacingOccurrences(of: pattern, with: full, options: .regularExpression)
        }
        return result
    }

    private static func indent(_ text: String, options: FormatOptions, chapterRegex: NSRegularExpression?) -> String {
        let indentStr = "\u{3000}\u{3000}"
        return text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: blankSet)
            if trimmed.isEmpty { return "" }
            if options.detectChapters && isChapterTitle(trimmed, regex: chapterRegex) { return trimmed }
            if trimmed.hasPrefix(indentStr) { return trimmed }
            return indentStr + trimmed
        }.joined(separator: "\n")
    }
}
