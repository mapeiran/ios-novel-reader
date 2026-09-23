import Foundation

/// 书籍解析状态
enum ParseState: String, Codable {
    case pending
    case parsing
    case done
    case failed
}

/// 一本书 = 一个导入的 TXT 文件
struct Book: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var author: String?
    /// 沙盒内正文文件（解析后统一存为 UTF-8）
    var filePath: String
    /// 原始识别到的编码名（仅作记录）
    var encoding: String
    var fileSize: Int64
    var totalChars: Int
    var chapterCount: Int
    /// 绑定的分章正则
    var chapterRule: String?
    var addedAt: Date = Date()
    var lastReadAt: Date?
    /// 阅读进度百分比（0~1）
    var progress: Double = 0
    /// 解析状态（nil 视为已完成，兼容旧数据）
    var parseState: ParseState?
    /// 内容哈希（用于重复导入检测）
    var contentHash: String?
    /// 所属分类文件夹（nil = 未分类）
    var folder: String?

    var isParsing: Bool {
        parseState == .pending || parseState == .parsing
    }
}
