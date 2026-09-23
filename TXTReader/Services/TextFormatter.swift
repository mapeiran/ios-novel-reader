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

/// TXT 智能格式化引擎（纯函数，便于测试）
enum TextFormatter {

    private static let blankSet = CharacterSet(charactersIn: " \t\u{3000}")
    private static let garbageRegex = try? NSRegularExpression(
        pattern: "[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\uFFFD\\u200B-\\u200F\\uFEFF]")

    /// 常见网文广告行
    private static let adPatterns: [String] = [
        "本章未完.*?(请|点击).*?页",
        "请记住本站.*",
        ".*本书首发.*",
        ".*(最新章节|更新最快).*",
        ".*(手机版|手机阅读|阅读网址).*",
        ".*https?://\\S+.*",
        ".*www\\.[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}.*",
        ".*[a-zA-Z0-9-]+\\.(com|cn|net|org)\\b.*",
        ".*(求收藏|求推荐|求月票|求订阅).*",
        ".*(加入书签|加入书架|方便阅读).*",
        ".*(天才一秒记住|一秒记住).*",
        ".*(笔趣|顶点|燃文|无弹窗).*",
        ".*(本站首发|首发地址).*",
    ]

    // MARK: - 入口

    static func format(_ raw: String, options: FormatOptions) -> FormatResult {
        var stats = FormatStats()

        // 1. 规范化换行 + 去 BOM
        var text = EncodingDetector.normalize(raw)
        stats.originalChars = (text as NSString).length

        // 2. 广告清理
        if options.cleanAds {
            let (cleaned, count) = removeAds(text)
            text = cleaned
            stats.adsRemoved = count
            if count > 0 { stats.log.append("清理广告行 \(count) 行") }
        }

        // 3. 逐行清洗
        var lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for (index, original) in lines.enumerated() {
            var line = original

            if options.trimWhitespace {
                line = line.trimmingCharacters(in: blankSet)
            }
            if options.cleanGarbage {
                line = removeGarbage(line)
            }
            if options.removeExtraSpaces {
                line = line.replacingOccurrences(of: "[ \t\u{3000}]{2,}", with: " ",
                                                 options: .regularExpression)
            }

            // 空行
            if line.isEmpty {
                if options.normalizeBlankLines {
                    if out.last != nil, out.last != "" {
                        out.append("")
                    } else {
                        stats.blankLinesRemoved += 1
                    }
                } else {
                    out.append("")
                }
                continue
            }

            let isTitle = options.detectChapters && isChapterTitle(line)

            if isTitle {
                if out.last != "" { out.append("") }   // 标题前空行
                out.append(line)
                continue
            }

            // 合并被切割的段落
            if options.mergeBrokenParagraphs,
               let last = out.last, !last.isEmpty,
               !(options.detectChapters && isChapterTitle(last)),
               !endsWithSentencePunctuation(last) {
                out[out.count - 1] = last + line
                stats.paragraphsMerged += 1
            } else {
                out.append(line)
            }
            _ = index
        }

        var body = out.joined(separator: "\n")

        // 4. 标点标准化
        if options.normalizePunctuation {
            body = normalizePunctuation(body)
            stats.log.append("标点标准化已应用")
        }

        // 5. 段落缩进
        if options.indentParagraphs {
            body = indent(body, options: options)
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
        var count = 0
        var lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        kept.reserveCapacity(lines.count)

        let regexes = adPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: blankSet)
            var isAd = false
            if !trimmed.isEmpty {
                let range = NSRange(location: 0, length: (trimmed as NSString).length)
                for regex in regexes where regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    isAd = true
                    break
                }
            }
            if isAd {
                count += 1
            } else {
                kept.append(line)
            }
        }
        lines = kept
        return (lines.joined(separator: "\n"), count)
    }

    private static func removeGarbage(_ line: String) -> String {
        guard let regex = garbageRegex else { return line }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
    }

    static func isChapterTitle(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: blankSet)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { return false }
        guard let regex = try? NSRegularExpression(pattern: ChapterRule.defaultPattern) else { return false }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        return regex.firstMatch(in: trimmed, options: [.anchored], range: range) != nil
    }

    private static func endsWithSentencePunctuation(_ line: String) -> Bool {
        guard let last = line.trimmingCharacters(in: blankSet).last else { return true }
        let endings = "。！？…\"”』」）】.!?"
        return endings.contains(last)
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

    private static func indent(_ text: String, options: FormatOptions) -> String {
        let indentStr = "\u{3000}\u{3000}"
        return text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: blankSet)
            if trimmed.isEmpty { return "" }
            if options.detectChapters && isChapterTitle(trimmed) { return trimmed }
            if trimmed.hasPrefix(indentStr) { return trimmed }
            return indentStr + trimmed
        }.joined(separator: "\n")
    }
}
