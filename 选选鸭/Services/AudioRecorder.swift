import AVFoundation
import Foundation
import Speech

/// 按住/点击录音：实时转文字，写入聊天输入框；不产生音频附件。
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var errorMessage: String?

    /// 开始录音前输入框里已有的文字，转写结果会接在后面。
    private(set) var draftPrefix = ""

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        ?? SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// 供 UI 直接写入输入框：前缀 + 实时转写。
    var composedDraft: String {
        let live = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = draftPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return live }
        if live.isEmpty { return base }
        return base + live
    }

    func toggleRecording(currentDraft: String) async {
        if isRecording {
            stop()
        } else {
            await start(currentDraft: currentDraft)
        }
    }

    private func start(currentDraft: String) async {
        errorMessage = nil
        liveTranscript = ""
        draftPrefix = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draftPrefix.isEmpty, !draftPrefix.hasSuffix("\n") {
            draftPrefix += " "
        }

        guard let speechRecognizer else {
            errorMessage = "这台设备不支持语音转文字鸭～"
            return
        }
        guard speechRecognizer.isAvailable else {
            errorMessage = "语音识别暂时不可用，稍后再试鸭～"
            return
        }

        let micOK = await requestMicrophonePermission()
        guard micOK else {
            errorMessage = "需要麦克风权限才能语音输入。"
            return
        }
        let speechOK = await requestSpeechPermission()
        guard speechOK else {
            errorMessage = "需要语音识别权限，才能把说话变成文字。"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionTask?.cancel()
            recognitionTask = nil

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.liveTranscript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        // 用户主动 stop 时也会走到这里；保持已转写文字即可
                        if self.isRecording, error != nil {
                            self.errorMessage = error?.localizedDescription
                            self.stop()
                        }
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            cleanupEngine()
            errorMessage = error.localizedDescription
            isRecording = false
        }
    }

    func stop() {
        guard isRecording || audioEngine.isRunning else {
            cleanupEngine()
            isRecording = false
            return
        }
        recognitionRequest?.endAudio()
        cleanupEngine()
        isRecording = false
    }

    private func cleanupEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        // 彻底让出音频会话，避免之后首次开摄像头/通话卡住
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
