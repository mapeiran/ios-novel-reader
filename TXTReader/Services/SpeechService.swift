import Foundation
import AVFoundation

/// 语音朗读（系统 TTS）
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    /// 当前朗读到的字符范围（相对传入文本）
    @Published private(set) var currentRange: NSRange?

    /// 语速（0.0~1.0，默认系统值）
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// 语音标识（nil 用中文默认）
    @Published var voiceIdentifier: String?

    /// 一段读完后的回调（用于自动翻页续读）
    var onFinishUtterance: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        configureSession()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// 中文语音列表
    static var chineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        configureSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        isSpeaking = true
        isPaused = false
        synthesizer.speak(utterance)
    }

    func pause() {
        guard synthesizer.isSpeaking else { return }
        if synthesizer.pauseSpeaking(at: .word) { isPaused = true }
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        if synthesizer.continueSpeaking() { isPaused = false }
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
        currentRange = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        currentRange = characterRange
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        isPaused = false
        currentRange = nil
        onFinishUtterance?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        isPaused = false
        currentRange = nil
    }
}
