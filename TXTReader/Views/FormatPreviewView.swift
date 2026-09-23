import SwiftUI

struct FormatPreviewView: View {
    let book: Book
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var options = FormatOptions()
    @State private var result: FormatResult?
    @State private var rawText = ""
    @State private var processing = false
    @State private var message: String?
    @State private var showOverwriteConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section("清洗规则") {
                    Toggle("空行规整", isOn: $options.normalizeBlankLines)
                    Toggle("去除首尾空白 / TAB", isOn: $options.trimWhitespace)
                    Toggle("清洗乱码字符", isOn: $options.cleanGarbage)
                    Toggle("合并被切割段落", isOn: $options.mergeBrokenParagraphs)
                    Toggle("章节智能识别", isOn: $options.detectChapters)
                    Toggle("广告文本清理", isOn: $options.cleanAds)
                }
                Section("高级（可选）") {
                    Toggle("标点标准化", isOn: $options.normalizePunctuation)
                    Toggle("首行缩进 2 字符", isOn: $options.indentParagraphs)
                    Toggle("去除多余空格", isOn: $options.removeExtraSpaces)
                    Picker("繁简转换", selection: $options.scriptConversion) {
                        ForEach(ScriptConversion.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                if let result {
                    Section("处理结果") {
                        statRow("字符数", "\(result.stats.originalChars) → \(result.stats.formattedChars)")
                        statRow("识别章节", "\(result.stats.chapters) 章")
                        statRow("清理广告", "\(result.stats.adsRemoved) 行")
                        statRow("合并断行", "\(result.stats.paragraphsMerged) 处")
                        statRow("清洗异常", "\(result.stats.garbageLines) 行")
                        statRow("删除空行", "\(result.stats.blankLinesRemoved) 行")
                    }
                    Section("预览（前 80 行）") {
                        Text(previewText(result.text))
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(80)
                    }
                }
            }
            .navigationTitle("TXT 格式化")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if processing {
                    ProgressView("处理中…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if library.hasFormatBackup(book) {
                        Button("撤销上次") { undo() }
                    }
                    Spacer()
                    Button("另存为") { saveAsNew() }
                        .disabled(result == nil)
                    Button("覆盖原文件") { showOverwriteConfirm = true }
                        .disabled(result == nil)
                }
            }
            .onAppear { loadAndFormat() }
            .onChange(of: options) { _ in format() }
            .alert("覆盖原文件？", isPresented: $showOverwriteConfirm) {
                Button("取消", role: .cancel) {}
                Button("覆盖", role: .destructive) { overwrite() }
            } message: {
                Text("将先备份原文件，可撤销。")
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func previewText(_ text: String) -> String {
        text.components(separatedBy: "\n").prefix(80).joined(separator: "\n")
    }

    // MARK: - 动作

    private func loadAndFormat() {
        guard rawText.isEmpty else { return }
        processing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? String(contentsOfFile: book.filePath, encoding: .utf8)) ?? ""
            DispatchQueue.main.async {
                rawText = text
                processing = false
                format()
            }
        }
    }

    private func format() {
        guard !rawText.isEmpty else { return }
        processing = true
        let opts = options
        let raw = rawText
        DispatchQueue.global(qos: .userInitiated).async {
            let formatted = TextFormatter.format(raw, options: opts)
            DispatchQueue.main.async {
                result = formatted
                processing = false
            }
        }
    }

    private func saveAsNew() {
        guard let result else { return }
        if library.saveFormattedAsNew(book, text: result.text) != nil {
            dismiss()
        } else {
            message = "另存失败"
        }
    }

    private func overwrite() {
        guard let result else { return }
        if library.overwriteWithFormatted(book, text: result.text) != nil {
            dismiss()
        } else {
            message = "覆盖失败"
        }
    }

    private func undo() {
        if library.undoFormat(book) {
            rawText = ""
            message = "已撤销，恢复到格式化前"
            loadAndFormat()
        } else {
            message = "没有可撤销的备份"
        }
    }
}
