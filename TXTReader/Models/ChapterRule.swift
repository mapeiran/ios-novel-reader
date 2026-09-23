import Foundation

/// 分章规则
struct ChapterRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var pattern: String
    var isBuiltin: Bool = false

    static let builtin: [ChapterRule] = [
        ChapterRule(name: "中文章节（第X章/番外）",
                    pattern: #"^[ \t\u3000]*(?:第[ \t\u3000]*[0-9一二三四五六七八九十百千万零〇两]+[ \t\u3000]*[章节回卷篇部]|番外|外传|序幕|序章|序言|楔子|引子|尾声|终章|后记|尾章)"#,
                    isBuiltin: true),
        ChapterRule(name: "数字章节",
                    pattern: #"^[ \t\u3000]*第?[ \t\u3000]*\d+[ \t\u3000]*[章节回卷]"#,
                    isBuiltin: true),
        ChapterRule(name: "序号章节",
                    pattern: #"^[ \t\u3000]*[（(【\[]?\d{1,5}[）)】\]]?[ \t\u3000]*[、.．:：]?"#,
                    isBuiltin: true),
    ]

    static var defaultPattern: String { builtin[0].pattern }
}
