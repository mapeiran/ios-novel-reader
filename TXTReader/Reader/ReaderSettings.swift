import Foundation
import Combine

/// 翻页方式 / 动画
enum PageTurnStyle: String, CaseIterable, Identifiable {
    case curl = "仿真"
    case cover = "覆盖"
    case slide = "平移"
    case verticalScroll = "滚动"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .curl:           return "仿真翻页"
        case .cover:          return "覆盖翻页"
        case .slide:          return "平移翻页"
        case .verticalScroll: return "上下滚动"
        }
    }

    var isHorizontal: Bool { self != .verticalScroll }
}

/// 阅读设置（可被 SwiftUI 设置页与 UIKit 阅读器共享）
/// 使用 UserDefaults 持久化，下次打开自动恢复（含夜间 / 护眼模式）
final class ReaderSettings: ObservableObject {

    @Published var typography: Typography { didSet { persist() } }
    @Published var style: PageTurnStyle { didSet { persist() } }
    /// 常亮（阅读时屏幕不息屏）
    @Published var keepScreenOn: Bool { didSet { persist() } }
    /// 跟随系统深色模式
    @Published var followSystemTheme: Bool { didSet { persist() } }

    private let defaults: UserDefaults

    private enum Keys {
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let paragraphSpacing = "reader.paragraphSpacing"
        static let letterSpacing = "reader.letterSpacing"
        static let margin = "reader.margin"
        static let themeIndex = "reader.themeIndex"
        static let style = "reader.style"
        static let keepScreenOn = "reader.keepScreenOn"
        static let followSystemTheme = "reader.followSystemTheme"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var typography = Typography()
        if defaults.object(forKey: Keys.fontSize) != nil {
            typography.fontSize = CGFloat(defaults.double(forKey: Keys.fontSize))
        }
        if defaults.object(forKey: Keys.lineSpacing) != nil {
            typography.lineSpacing = CGFloat(defaults.double(forKey: Keys.lineSpacing))
        }
        if defaults.object(forKey: Keys.paragraphSpacing) != nil {
            typography.paragraphSpacing = CGFloat(defaults.double(forKey: Keys.paragraphSpacing))
        }
        if defaults.object(forKey: Keys.letterSpacing) != nil {
            typography.letterSpacing = CGFloat(defaults.double(forKey: Keys.letterSpacing))
        }
        if defaults.object(forKey: Keys.margin) != nil {
            typography.margin = CGFloat(defaults.double(forKey: Keys.margin))
        }
        if defaults.object(forKey: Keys.themeIndex) != nil {
            typography.themeIndex = defaults.integer(forKey: Keys.themeIndex)
        }
        self.typography = typography

        if let raw = defaults.string(forKey: Keys.style),
           let style = PageTurnStyle(rawValue: raw) {
            self.style = style
        } else {
            self.style = .curl
        }

        self.keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        self.followSystemTheme = defaults.bool(forKey: Keys.followSystemTheme)
    }

    private func persist() {
        defaults.set(Double(typography.fontSize), forKey: Keys.fontSize)
        defaults.set(Double(typography.lineSpacing), forKey: Keys.lineSpacing)
        defaults.set(Double(typography.paragraphSpacing), forKey: Keys.paragraphSpacing)
        defaults.set(Double(typography.letterSpacing), forKey: Keys.letterSpacing)
        defaults.set(Double(typography.margin), forKey: Keys.margin)
        defaults.set(typography.themeIndex, forKey: Keys.themeIndex)
        defaults.set(style.rawValue, forKey: Keys.style)
        defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
        defaults.set(followSystemTheme, forKey: Keys.followSystemTheme)
    }
}
