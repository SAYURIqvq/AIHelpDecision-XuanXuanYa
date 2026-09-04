import AVFoundation
import Foundation

/// 采集 16kHz 单声道 PCM16（上行），播放 24kHz 单声道 PCM16（下行）。
@MainActor
final class RealtimePCMEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isDuckSpeaking = false

    var onCapturedPCM: ((Data) -> Void)?
    var onPlaybackQueueEmpty: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let targetInputSampleRate: Double = 16_000
    private let outputSampleRate: Double = 24_000
    private var muted = false
    private var scheduledBuffers = 0

    func start() throws {
        stop()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        // 尽量打开系统回声消除，减轻鸭鸭声音被麦二次采到
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(
                domain: "RealtimePCM",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "麦克风不可用"]
            )
        }
        inputFormat = hwFormat

        guard let mono16k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetInputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "RealtimePCM",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 16k 音频格式"]
            )
        }
        converter = AVAudioConverter(from: hwFormat, to: mono16k)

        engine.attach(player)
        guard let playFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "RealtimePCM",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建播放格式"]
            )
        }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let bufferSize: AVAudioFrameCount = 2_048
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }
        converter = nil
        inputFormat = nil
        scheduledBuffers = 0
        isRunning = false
        isDuckSpeaking = false
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    func enqueuePlaybackPCM16(_ data: Data) {
        guard isRunning, !data.isEmpty else { return }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0]
        else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                channel[i] = Float(src[i]) / Float(Int16.max)
            }
        }

        isDuckSpeaking = true
        scheduledBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                if self.scheduledBuffers == 0 {
                    self.isDuckSpeaking = false
                    self.onPlaybackQueueEmpty?()
                }
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func clearPlayback() {
        player.stop()
        player.reset()
        scheduledBuffers = 0
        isDuckSpeaking = false
        onPlaybackQueueEmpty?()
        if isRunning {
            player.play()
        }
    }

    // MARK: - Capture

    nonisolated private func handleInput(buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            guard let converter = self.converter else { return }
            let ratio = self.targetInputSampleRate / buffer.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: self.targetInputSampleRate,
                channels: 1,
                interleaved: false
            ),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
            else { return }

            var error: NSError?
            var consumed = false
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil, outBuffer.frameLength > 0,
                  let floats = outBuffer.floatChannelData?[0] else { return }

            let frameCount = Int(outBuffer.frameLength)
            var pcm = Data(count: frameCount * MemoryLayout<Int16>.size)
            // 静音时仍上行全 0 帧，否则服务端 VAD 收不到「说完」，会一直停在听你说
            if !self.muted {
                pcm.withUnsafeMutableBytes { raw in
                    guard let dst = raw.bindMemory(to: Int16.self).baseAddress else { return }
                    for i in 0..<frameCount {
                        let clipped = max(-1.0, min(1.0, floats[i]))
                        dst[i] = Int16(clipped * Float(Int16.max))
                    }
                }
            }
            self.onCapturedPCM?(pcm)
        }
    }
}
