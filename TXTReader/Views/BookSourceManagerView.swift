import SwiftUI
import UIKit

struct BookSourceManagerView: View {
    @EnvironmentObject var sources: BookSourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var showJSONInput = false
    @State private var json = ""
    @State private var showLinkInput = false
    @State private var linkInput = ""
    @State private var message: String?
    @State private var testingIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if sources.sources.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "books.vertical").font(.system(size: 44)).foregroundColor(.secondary)
                        Text("还没有书源").font(.headline)
                        Text("点击右上角 + 导入书源 JSON").font(.footnote).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sources.orderedSources) { source in
                            sourceRow(source)
                        }
                    }
                }
            }
            .navigationTitle("书源管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { json = ""; showJSONInput = true } label: { Label("粘贴 JSON", systemImage: "doc.on.clipboard") }
                        Button { importFromClipboard() } label: { Label("从剪贴板导入", systemImage: "clipboard") }
                        Button { linkInput = ""; showLinkInput = true } label: { Label("从链接导入", systemImage: "link") }
                        Button { json = Self.templateJSON; showJSONInput = true } label: { Label("填入示例模板", systemImage: "doc.text") }
                        Divider()
                        Button { sources.checkForUpdate() } label: {
                            Label(sources.isUpdating ? "正在更新…" : "检查更新（整体替换）", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(sources.isUpdating)
                        Divider()
                        Button {
                            UIPasteboard.general.string = sources.exportJSON()
                            message = "已复制全部书源到剪贴板"
                        } label: { Label("导出到剪贴板", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showJSONInput) { jsonInputSheet }
            .alert("从链接导入", isPresented: $showLinkInput) {
                TextField("书源 JSON 链接", text: $linkInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("导入") { importFromLink() }
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .alert("书源更新", isPresented: Binding(
                get: { sources.updateMessage != nil },
                set: { if !$0 { sources.updateMessage = nil } })) {
                Button("好", role: .cancel) { sources.updateMessage = nil }
            } message: {
                Text(sources.updateMessage ?? "")
            }
        }
    }

    // MARK: - 行

    private func sourceRow(_ source: BookSource) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if source.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundColor(.orange)
                    }
                    Text(source.name).font(.body).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let group = source.group, !group.isEmpty {
                        Text(group)
                    }
                    healthText(source)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if testingIDs.contains(source.id) {
                ProgressView().scaleEffect(0.7)
            } else {
                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: { _ in sources.toggle(source) }))
                    .labelsHidden()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                sources.remove(source)
            } label: { Label("删除", systemImage: "trash") }
            Button {
                sources.setPinned(source, !source.isPinned)
            } label: {
                Label(source.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button { testSource(source) } label: { Label("测速", systemImage: "bolt") }
            Button {
                sources.setPinned(source, !source.isPinned)
            } label: { Label(source.isPinned ? "取消置顶" : "置顶", systemImage: "pin") }
            Button(role: .destructive) {
                sources.remove(source)
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func healthText(_ source: BookSource) -> some View {
        if let ok = source.lastOK {
            if ok {
                Text("可用 \(Int((source.lastLatency ?? 0) * 1000))ms").foregroundColor(.green)
            } else {
                Text("失效").foregroundColor(.red)
            }
        } else {
            Text("未测速")
        }
    }

    // MARK: - 导入

    private var jsonInputSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $json)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 260)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("书源 JSON（支持单个对象或数组）")
                } footer: {
                    Text("字段：name / baseURL / searchURL / searchListRule / searchNameRule / searchDetailRule / chapterListRule / chapterNameRule / chapterURLRule / contentRule")
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showJSONInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { doImport(json) }
                        .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func doImport(_ text: String) {
        do {
            let count = try sources.importJSON(text)
            message = "成功导入 \(count) 个书源"
            showJSONInput = false
            json = ""
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "剪贴板为空"
            return
        }
        doImport(text)
    }

    private func importFromLink() {
        guard let url = URL(string: linkInput.trimmingCharacters(in: .whitespaces)) else {
            message = "链接无效"
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { doImport(text) }
            } catch {
                await MainActor.run { message = "下载失败：\(error.localizedDescription)" }
            }
        }
    }

    private func testSource(_ source: BookSource) {
        testingIDs.insert(source.id)
        Task {
            let health = await BookSourceService().test(source)
            await MainActor.run {
                sources.setHealth(source, ok: health.ok, latency: health.latency)
                testingIDs.remove(source.id)
            }
        }
    }

    static var templateJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let data = try? encoder.encode(BookSource.template),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }
}
