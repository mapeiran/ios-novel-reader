import UIKit
import CoreText

/// 用 CoreText 绘制单页富文本
final class ReaderPageView: UIView {

    var content: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
    }

    override func draw(_ rect: CGRect) {
        guard let content, content.length > 0,
              let context = UIGraphicsGetCurrentContext() else { return }

        // 翻转坐标系（CoreText 左下原点）
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let path = CGPath(rect: bounds, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRangeMake(0, content.length), path, nil)
        CTFrameDraw(frame, context)
    }
}
