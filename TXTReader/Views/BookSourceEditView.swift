import SwiftUI

struct BookSourceEditView: View {
    @EnvironmentObject var sources: BookSourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var json = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $json)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 260)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("粘贴书源 JSON")
                } footer: {
                    Text("字段：name / baseURL / searchURL / searchListRule / searchNameRule / searchDetailRule / chapterListRule / chapterNameRule / chapterURLRule / contentRule（正则捕获组 1 为结果）")
                }

                Section {
                    Button("填入示例模板") { json = Self.templateJSON }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundColor(.red).font(.footnote)
                    }
                }

                if !sources.sources.isEmpty {
                    Section("已有书源") {
                        ForEach(sources.sources) { source in
                            HStack {
                                Text(source.name)
                                Spacer()
                                Button(role: .destructive) {
                                    sources.remove(source)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("书源管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            _ = try sources.addFromJSON(json)
            json = ""
            errorText = nil
        } catch {
            errorText = "JSON 解析失败：\(error.localizedDescription)"
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
