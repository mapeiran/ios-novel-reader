import UIKit
import CoreText

/// 基于 CoreText 的分页
enum PaginationService {

    /// 将富文本按可视区域切分为页的 range 数组
    static func paginate(attributed: NSAttributedString, in rect: CGRect) -> [NSRange] {
        guard attributed.length > 0, rect.width > 0, rect.height > 0 else { return [] }

        var ranges: [NSRange] = []
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)

        var offset = 0
        let total = attributed.length
        while offset < total {
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRangeMake(offset, 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break } // 防止死循环
            ranges.append(NSRange(location: offset, length: visible.length))
            offset += visible.length
        }
        return ranges
    }

    /// 富文本在给定宽度下的高度（供滚动模式行高使用）
    static func textHeight(attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil)
        return ceil(size.height)
    }

    /// 重排后按字符偏移定位到新页
    static func pageIndex(for offset: Int, in pages: [NSRange]) -> Int {
        pages.firstIndex { offset < $0.location + $0.length } ?? 0
    }
}
