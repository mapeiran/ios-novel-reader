import UIKit

/// 一页
struct PageModel: Identifiable {
    let id = UUID()
    var chapterIndex: Int
    var pageIndex: Int
    var totalPages: Int
    var range: NSRange
    var content: NSAttributedString
    var textHeight: CGFloat
}
