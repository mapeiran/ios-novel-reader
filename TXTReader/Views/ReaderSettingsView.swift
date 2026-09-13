import SwiftUI

struct ReaderSettingsView: View {
    @ObservedObject var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    HStack {
                        Text("A").font(.system(size: 13))
                        Slider(value: $settings.typography.fontSize, in: 12...30, step: 1)
                        Text("A").font(.system(size: 22))
                    }
                }

                Section("行距") {
                    Slider(value: $settings.typography.lineSpacing, in: 0...20, step: 1)
                }

                Section("段距") {
                    Slider(value: $settings.typography.paragraphSpacing, in: 0...30, step: 1)
                }

                Section("主题") {
                    Picker("主题", selection: $settings.typography.themeIndex) {
                        ForEach(ReaderTheme.themes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("翻页方式") {
                    Picker("翻页方式", selection: $settings.style) {
                        ForEach(PageTurnStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
