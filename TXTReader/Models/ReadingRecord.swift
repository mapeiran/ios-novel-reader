import Foundation

/// 阅读记录：用于退出后恢复到上次位置
struct ReadingRecord: Codable {
    var bookId: UUID
    var chapterIndex: Int
    var pageIndex: Int
    /// 整本文本的字符偏移，重排后优先用它定位
    var charOffset: Int
    var percent: Double
    var updatedAt: Date = Date()
}
