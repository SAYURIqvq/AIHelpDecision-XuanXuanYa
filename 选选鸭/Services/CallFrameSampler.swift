import AVFoundation
import UIKit

/// 从本地预览会话抽帧，供 Omni Realtime `input_image_buffer.append`（约 1fps）。
/// 所有对 session 的改动都走传入的 `sessionQueue`，避免和开关摄像头并发闪退。
final class CallFrameSampler: NSObject {
    var onJPEG: ((Data) -> Void)?

    private let session: AVCaptureSession
    private let sessionQueue: DispatchQueue
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.xuanxuanya.call-frame-sampler.sample")
    private var lastSentAt: TimeInterval = 0
    private let minInterval: TimeInterval = 1.0
    private var isEnabled = false

    init(session: AVCaptureSession, sessionQueue: DispatchQueue) {
        self.session = session
        self.sessionQueue = sessionQueue
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func start() {
        sessionQueue.async {
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.output), !self.session.outputs.contains(self.output) {
                self.session.addOutput(self.output)
            }
            if let connection = self.output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            self.session.commitConfiguration()
            self.isEnabled = true
            self.lastSentAt = 0
        }
    }

    func stop() {
        sessionQueue.async {
            self.isEnabled = false
            guard self.session.outputs.contains(self.output) else { return }
            self.session.beginConfiguration()
            self.session.removeOutput(self.output)
            self.session.commitConfiguration()
        }
    }

    /// 可等待停止：关摄像头前必须先卸掉 output，再 stopRunning
    func stopAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.isEnabled = false
                if self.session.outputs.contains(self.output) {
                    self.session.beginConfiguration()
                    self.session.removeOutput(self.output)
                    self.session.commitConfiguration()
                }
                continuation.resume()
            }
        }
    }
}

extension CallFrameSampler: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastSentAt >= minInterval else { return }
        lastSentAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage)
        let scaled = Self.scaled(uiImage, maxSide: 640)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.55) else { return }
        onJPEG?(jpeg)
    }

    private static func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
