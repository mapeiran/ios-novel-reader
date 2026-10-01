import Foundation

// MARK: - 句子切分

enum SentenceSplitter {
    static func sentences(in text: String) -> [String] {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "…"]
        let closers: Set<Character> = ["”", "』", "」", "）", "】", "\"", "'"]
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)
            if enders.contains(ch) {
                while i + 1 < chars.count, enders.contains(chars[i + 1]) { i += 1; current.append(chars[i]) }
                while i + 1 < chars.count, closers.contains(chars[i + 1]) { i += 1; current.append(chars[i]) }
                result.append(current)
                current = ""
            } else if ch == "." {
                let prevIsDigit = i > 0 && chars[i - 1].isNumber
                let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
                let atEnd = i + 1 >= chars.count
                let followedBySpace = i + 1 < chars.count && chars[i + 1].isWhitespace
                if !prevIsDigit && !nextIsDigit && (atEnd || followedBySpace) {
                    while i + 1 < chars.count, closers.contains(chars[i + 1]) { i += 1; current.append(chars[i]) }
                    result.append(current)
                    current = ""
                }
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result
    }
}

// MARK: - 标点打分

enum PunctScorer {
    /// 句末断点权重
    static func score(_ sentence: String) -> Int {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return 0 }
        var score = 0
        if "。！？!?".contains(last) {
            score = 60
        } else if last == "…" || trimmed.hasSuffix("...") {
            score = 50
        } else if "；：;:".contains(last) {
            score = 30
        } else if "，,".contains(last) {
            score = 10
        }
        if "”』」）】\"'".contains(last) { score += 20 }
        return score
    }

    static func isDialogueStart(_ sentence: String) -> Bool {
        guard let first = sentence.trimmingCharacters(in: .whitespaces).first else { return false }
        return "“\"『「'".contains(first)
    }
}

// MARK: - 默认实现

/// 自动分段：章节识别 + 句子切分 + 标点/语义校验 + 成段（规则优先，语义可降级）
public final class DefaultTextSegmenter: TextSegmenting, @unchecked Sendable {

    /// 结果版本号：算法/配置升级时递增，用于缓存失效
    public static let segmentVersion = 1

    private let semanticScorer: SemanticScoring?
    private let cache: SegmentCacheProtocol?

    public init(semanticScorer: SemanticScoring? = LexicalSimilarityScorer(),
                cache: SegmentCacheProtocol? = nil) {
        self.semanticScorer = semanticScorer
        self.cache = cache
    }

    // MARK: 单段

    public func segment(text: String, config: SegmentConfig) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            try self.segmentSync(text: text, config: config)
        }.value
    }

    /// 同步版本（供已有同步流程，如格式化引擎调用）
    public func segmentSync(text: String, config: SegmentConfig) throws -> [String] {
        let normalized = EncodingDetector.normalize(text)
        guard normalized.contains(where: { !$0.isWhitespace }) else { throw SegmentError.emptyText }

        let chapterRegex = try? NSRegularExpression(pattern: config.chapterPattern)
        var paragraphs: [String] = []

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isChapterTitle(trimmed, regex: chapterRegex) {
                paragraphs.append(trimmed)
                continue
            }
            let sentences = SentenceSplitter.sentences(in: trimmed)
            paragraphs.append(contentsOf: buildParagraphs(sentences: sentences, config: config))
        }
        return paragraphs
    }

    /// 供格式化/编辑器用：保留原有空行与行结构，只把过长行按规则切分。
    /// 返回切分后的段落数组与切分处数。
    public func segmentLinesPreservingStructure(text: String,
                                                config: SegmentConfig,
                                                detectChapters: Bool = false,
                                                chapterRegex: NSRegularExpression? = nil)
        -> (paragraphs: [String], splitCount: Int) {
        var result: [String] = []
        var splitCount = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append("")
                continue
            }
            if detectChapters, let chapterRegex, isChapterTitle(trimmed, regex: chapterRegex) {
                result.append(trimmed)
                continue
            }
            let sentences = SentenceSplitter.sentences(in: trimmed)
            let pieces = buildParagraphs(sentences: sentences, config: config)
            splitCount += max(0, pieces.count - 1)
            result.append(contentsOf: pieces)
        }
        return (result, splitCount)
    }

    // MARK: 整本

    public func segmentBook(text: String,
                            config: SegmentConfig,
                            progress: ((Double) -> Void)?) async throws -> [SegmentedChapter] {
        let normalized = EncodingDetector.normalize(text)
        guard normalized.contains(where: { !$0.isWhitespace }) else { throw SegmentError.emptyText }

        let chapters = ChapterParser.parse(text: normalized, bookId: UUID(), pattern: config.chapterPattern)
        let ns = normalized as NSString
        var output: [SegmentedChapter] = []
        for (index, chapter) in chapters.enumerated() {
            let length = max(0, chapter.end - chapter.start)
            let chapterText = ns.substring(with: NSRange(location: chapter.start, length: length))
            let paragraphs = (try? segmentSync(text: chapterText, config: config)) ?? []
            output.append(SegmentedChapter(index: index, title: chapter.title, paragraphs: paragraphs))
            progress?(Double(index + 1) / Double(max(1, chapters.count)))
        }
        return output
    }

    /// 带缓存的整本分段
    public func segmentBook(bookId: String, text: String, config: SegmentConfig,
                            progress: ((Double) -> Void)?) async throws -> [SegmentedChapter] {
        if let cached = cache?.load(bookId: bookId, version: Self.segmentVersion) {
            return cached
        }
        let result = try await segmentBook(text: text, config: config, progress: progress)
        cache?.save(bookId: bookId, version: Self.segmentVersion, chapters: result)
        return result
    }

    // MARK: 成段

    private func buildParagraphs(sentences: [String], config: SegmentConfig) -> [String] {
        guard !sentences.isEmpty else { return [] }
        var paragraphs: [String] = []
        var current = sentences[0]

        for sentence in sentences.dropFirst() {
            let currentLength = current.count
            let previousScore = PunctScorer.score(current)
            let dialogueStart = PunctScorer.isDialogueStart(sentence)
            var shouldBreak = false

            if currentLength >= config.maxLength {
                shouldBreak = true
            } else if currentLength >= config.minLength {
                if dialogueStart {
                    shouldBreak = true
                } else if let scorer = semanticScorer, config.enableSemantic {
                    let similarity = scorer.similarity(current, sentence)
                    if previousScore >= 60 {
                        shouldBreak = similarity < config.similarityThreshold
                    } else {
                        shouldBreak = similarity < 0.45
                    }
                } else {
                    // 语义不可用：纯规则，句末强标点即断
                    shouldBreak = previousScore >= 60
                }
            }

            if shouldBreak {
                paragraphs.append(current)
                current = sentence
            } else {
                current += sentence
            }
        }
        paragraphs.append(current)
        return paragraphs
    }

    private func isChapterTitle(_ line: String, regex: NSRegularExpression?) -> Bool {
        guard let regex, !line.isEmpty, line.count <= 50 else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, options: [.anchored], range: range) != nil
    }
}
