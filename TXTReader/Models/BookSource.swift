import Foundation

/// 在线书源（基于正则规则，可自行添加/导入）
struct BookSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var enabled: Bool = true
    /// 网页编码：utf-8 / gbk
    var charset: String = "utf-8"

    // 搜索
    /// 搜索地址，支持 {key} 与 {page} 占位
    var searchURL: String
    /// 搜索结果列表项正则（捕获组 1 = 单条结果 HTML）
    var searchListRule: String
    var searchNameRule: String
    var searchAuthorRule: String?
    var searchCoverRule: String?
    /// 详情页链接正则
    var searchDetailRule: String

    // 详情 / 目录
    /// 章节列表项正则（捕获组 1 = 单章 HTML）
    var chapterListRule: String
    var chapterNameRule: String
    var chapterURLRule: String

    // 正文
    /// 正文正则（捕获组 1 = 正文 HTML）
    var contentRule: String

    /// 示例模板（需替换为真实规则后使用）
    static var template: BookSource {
        BookSource(name: "示例书源",
                   baseURL: "https://example.com",
                   searchURL: "https://example.com/search?q={key}&page={page}",
                   searchListRule: #"<div class="result-item">([\s\S]*?)</div>"#,
                   searchNameRule: #"<a[^>]*>([^<]+)</a>"#,
                   searchAuthorRule: #"作者[:：]\s*([^<\s]+)"#,
                   searchCoverRule: #"<img[^>]*src="([^"]+)""#,
                   searchDetailRule: #"<a[^>]*href="([^"]+)""#,
                   chapterListRule: #"<li[^>]*>([\s\S]*?)</li>"#,
                   chapterNameRule: #"<a[^>]*>([^<]+)</a>"#,
                   chapterURLRule: #"href="([^"]+)""#,
                   contentRule: #"<div[^>]*id="content"[^>]*>([\s\S]*?)</div>"#)
    }
}
