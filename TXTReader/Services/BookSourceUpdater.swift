import Foundation

/// 可更新书源：从本项目 GitHub 仓库拉取「书源.json」并整体替换
enum BookSourceUpdater {

    /// 本项目 GitHub 仓库中 书源.json 的 raw 地址（master 分支根目录）。
    /// 可用 UserDefaults key "bookSource.updateURL" 覆盖。
    static let defaultUpdateURL = "https://raw.githubusercontent.com/mapeiran/ios-novel-reader/master/%E4%B9%A6%E6%BA%90.json"

    static var updateURL: String {
        UserDefaults.standard.string(forKey: "bookSource.updateURL") ?? defaultUpdateURL
    }

    /// 下载最新书源（Legado 数组）并转换为 App 模型
    static func fetch() async throws -> [BookSource] {
        guard let url = URL(string: updateURL), url.scheme != nil else {
            throw BookSourceError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let list = BookSourceStore.makeLegadoSources(from: data), !list.isEmpty else {
            throw BookSourceError.noResult
        }
        return list
    }
}
