import SwiftUI

struct ReaderSettingsView: View {
    @ObservedObject var settings: ReaderSettings
    @ObservedObject var speech: SpeechService
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

                Section("字间距") {
                    Slider(value: $settings.typography.letterSpacing, in: 0...5, step: 0.5)
                }

                Section("页边距") {
                    Slider(value: $settings.typography.margin, in: 0...40, step: 1)
                }

                Section("主题") {
                    Picker("主题", selection: $settings.typography.themeIndex) {
                        ForEach(ReaderTheme.themes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("跟随系统深色模式", isOn: $settings.followSystemTheme)
                }

                Section("屏幕") {
                    Toggle("阅读时常亮", isOn: $settings.keepScreenOn)
                }

                Section("翻页方式") {
                    Picker("翻页方式", selection: $settings.style) {
                        ForEach(PageTurnStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Section("朗读") {
                    HStack {
                        Text("慢")
                        Slider(value: $speech.rate, in: 0.3...0.7)
                        Text("快")
                    }
                    Picker("音色", selection: Binding(
                        get: { speech.voiceIdentifier ?? "" },
                        set: { speech.voiceIdentifier = $0.isEmpty ? nil : $0 })) {
                        Text("默认").tag("")
                        ForEach(SpeechService.chineseVoices, id: \.identifier) { voice in
                            Text(voice.name).tag(voice.identifier)
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
