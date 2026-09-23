import SwiftUI
import UIKit

/// 备份数据
struct BackupPayload: Codable {
    var version: Int
    var sources: [BookSource]
    var records: [String: ReadingRecord]
}

struct AppSettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sources: BookSourceStore

    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section("数据管理") {
                    Button {
                        library.progressStoreInstance().clearAll()
                        library.reload()
                        message = "已清空全部阅读进度"
                    } label: {
                        Label("清空阅读进度", systemImage: "clock.arrow.circlepath")
                    }

                    Button {
                        clearTemp()
                    } label: {
                        Label("清理临时缓存", systemImage: "trash")
                    }

                    Button {
                        exportData()
                    } label: {
                        Label("导出数据到剪贴板", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        importData()
                    } label: {
                        Label("从剪贴板导入数据", systemImage: "square.and.arrow.down")
                    }
                }

                Section("权限") {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("打开系统设置（文件 / 本地网络）", systemImage: "gear")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("书籍数量", value: "\(library.books.count)")
                    LabeledContent("书源数量", value: "\(sources.sources.count)")
                    LabeledContent("本地优先", value: "无广告 · 无推送")
                }
            }
            .navigationTitle("设置")
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: - 动作

    private func clearTemp() {
        let tmp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: tmp,
                                                                   includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        message = "已清理临时缓存"
    }

    private func exportData() {
        let records = library.storage.loadRecords()
        let payload = BackupPayload(
            version: 1,
            sources: sources.sources,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) }))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(payload),
           let text = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = text
            message = "已复制数据到剪贴板（书源 + 阅读进度）"
        } else {
            message = "导出失败"
        }
    }

    private func importData() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8) else {
            message = "剪贴板为空"
            return
        }
        do {
            let payload = try JSONDecoder().decode(BackupPayload.self, from: data)
            let addedSources = sources.merge(payload.sources)
            let records = Dictionary(uniqueKeysWithValues: payload.records.compactMap { key, value -> (UUID, ReadingRecord)? in
                guard let uuid = UUID(uuidString: key) else { return nil }
                return (uuid, value)
            })
            library.restoreRecords(records)
            message = "导入完成：新增书源 \(addedSources) 个，阅读进度 \(records.count) 条"
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
