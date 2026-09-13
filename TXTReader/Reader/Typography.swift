import UIKit

/// 阅读主题
struct ReaderTheme: Identifiable, Hashable {
    let id: Int
    let name: String
    let background: UIColor
    let textColor: UIColor

    static let themes: [ReaderTheme] = [
        ReaderTheme(id: 0, name: "日间",
                    background: .white,
                    textColor: UIColor(white: 0.10, alpha: 1)),
        ReaderTheme(id: 1, name: "夜间",
                    background: UIColor(white: 0.07, alpha: 1),
                    textColor: UIColor(white: 0.72, alpha: 1)),
        ReaderTheme(id: 2, name: "护眼",
                    background: UIColor(red: 0.80, green: 0.87, blue: 0.74, alpha: 1),
                    textColor: UIColor(white: 0.14, alpha: 1)),
    ]

    static func theme(at index: Int) -> ReaderTheme {
        themes.indices.contains(index) ? themes[index] : themes[0]
    }
}

/// 排版参数
struct Typography: Equatable {
    var fontName: String = "PingFangSC-Regular"
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 7
    var paragraphSpacing: CGFloat = 15
    var themeIndex: Int = 0

    func attributedString(for text: String) -> NSAttributedString {
        let font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.alignment = .justified

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: ReaderTheme.theme(at: themeIndex).textColor,
        ])
    }
}

/// 阅读区域计算
enum ReaderLayout {
    static func readRect(in bounds: CGRect, safeTop: CGFloat, safeBottom: CGFloat) -> CGRect {
        let horizontalInset: CGFloat = 15
        let topInset: CGFloat = safeTop + 35
        let bottomInset: CGFloat = safeBottom + 60
        return CGRect(x: horizontalInset,
                      y: topInset,
                      width: max(0, bounds.width - horizontalInset * 2),
                      height: max(0, bounds.height - topInset - bottomInset))
    }
}
