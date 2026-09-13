import Foundation

/// 由正则从正文切分出的章节片段
struct Chapter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var bookId: UUID
    /// 从 0 开始
    var index: Int
    var title: String
    /// 整本文本中的 UTF-16 起始偏移
    var start: Int
    /// 整本文本中的 UTF-16 结束偏移（不含）
    var end: Int

    var charCount: Int { max(0, end - start) }
}
