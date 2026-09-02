import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var lastRecordingURL: URL?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?

    func toggleRecording() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    private func start() async {
        let session = AVAudioSession.sharedInstance()
        do {
            let granted = await requestRecordPermission(session: session)
            if !granted {
                errorMessage = "需要麦克风权限才能录音。"
                return
            }
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("duck-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            lastRecordingURL = url
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
    }

    private func requestRecordPermission(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
