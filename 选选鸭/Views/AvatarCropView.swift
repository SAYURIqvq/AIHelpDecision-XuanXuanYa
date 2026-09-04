import SwiftUI
import UIKit

/// 圆形头像裁剪。缩放只用 scaleEffect，不改 frame，避免顶栏文字被撑出屏幕。
struct AvatarCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onCropped: (UIImage) -> Void

    @State private var source: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let cropDiameter: CGFloat = 280

    private var workingImage: UIImage { source ?? image }

    private var imagePixelSize: CGSize {
        if let cg = workingImage.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return workingImage.size
    }

    /// 缩放=1 时 cover 圆框的显示尺寸（点）
    private var baseDisplaySize: CGSize {
        let pixel = imagePixelSize
        guard pixel.width > 0, pixel.height > 0 else {
            return CGSize(width: cropDiameter, height: cropDiameter)
        }
        let cover = max(cropDiameter / pixel.width, cropDiameter / pixel.height)
        return CGSize(width: pixel.width * cover, height: pixel.height * cover)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .zIndex(2)

            Text("拖动、双指缩放，圆框内为最终头像")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .zIndex(2)

            cropStage
                .zIndex(1)

            PrimaryDuckButton(title: "使用这张头像", systemImage: "checkmark.circle.fill") {
                confirmCrop()
            }
            .padding(20)
            .zIndex(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        // 整页禁止被放大手势带着走
        .defersSystemGestures(on: .all)
        .onAppear {
            source = image.fixedOrientation()
            resetTransform()
        }
    }

    private var topBar: some View {
        HStack {
            Button("取消", action: onCancel)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 64, alignment: .leading)

            Spacer(minLength: 0)

            Text("调整头像")
                .font(.headline.weight(.heavy))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Button("完成") { confirmCrop() }
                .font(.body.weight(.bold))
                .foregroundStyle(DuckTheme.warmYellow)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var cropStage: some View {
        // 用固定尺寸容器 + overlay 放图：图片再大也不参与外层 layout，顶栏不会被撑飞
        Color.black
            .frame(maxWidth: .infinity)
            .frame(height: cropDiameter + 56)
            .overlay {
                Image(uiImage: workingImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: baseDisplaySize.width, height: baseDisplaySize.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(dragGesture)
                    .simultaneousGesture(magnifyGesture)
            }
            .overlay {
                Circle()
                    .stroke(DuckTheme.warmYellow, lineWidth: 3)
                    .frame(width: cropDiameter, height: cropDiameter)
                    .allowsHitTesting(false)
            }
            .overlay {
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .mask(
                        ZStack {
                            Rectangle().fill(.white)
                            Circle()
                                .frame(width: cropDiameter, height: cropDiameter)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                clampOffset()
                lastOffset = offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(5, max(1, lastScale * value))
                clampOffset()
            }
            .onEnded { _ in
                lastScale = scale
                clampOffset()
                lastOffset = offset
            }
    }

    private func resetTransform() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func clampOffset() {
        let shown = CGSize(
            width: baseDisplaySize.width * scale,
            height: baseDisplaySize.height * scale
        )
        let maxX = max(0, (shown.width - cropDiameter) / 2)
        let maxY = max(0, (shown.height - cropDiameter) / 2)
        offset = CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height))
        )
    }

    private func confirmCrop() {
        let pixel = imagePixelSize
        guard pixel.width > 0, pixel.height > 0, let cgImage = workingImage.cgImage else {
            onCropped(workingImage)
            return
        }

        let shown = CGSize(
            width: baseDisplaySize.width * scale,
            height: baseDisplaySize.height * scale
        )
        let d = cropDiameter
        let left = (shown.width - d) / 2 - offset.width
        let top = (shown.height - d) / 2 - offset.height

        let scaleX = pixel.width / shown.width
        let scaleY = pixel.height / shown.height
        var cropRect = CGRect(
            x: left * scaleX,
            y: top * scaleY,
            width: d * scaleX,
            height: d * scaleY
        )
        cropRect = cropRect.integral.intersection(CGRect(origin: .zero, size: pixel))
        guard !cropRect.isNull, cropRect.width > 2, cropRect.height > 2,
              let croppedCG = cgImage.cropping(to: cropRect) else {
            onCropped(workingImage)
            return
        }

        let cropped = UIImage(cgImage: croppedCG, scale: 1, orientation: .up)
        let output = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { _ in
            cropped.draw(in: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        onCropped(output)
    }
}

struct ProfileAvatarView: View {
    let profile: UserProfile?
    var size: CGFloat = 86
    var strokeColor: Color = .white
    var strokeWidth: CGFloat = 3

    private var refreshID: String {
        let path = profile?.avatarRelativePath ?? ""
        let stamp = profile?.updatedAt.timeIntervalSince1970 ?? 0
        return "\(path)-\(stamp)"
    }

    var body: some View {
        Group {
            if let ui = profile?.avatarUIImage {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Image("UserAvatar")
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(strokeColor, lineWidth: strokeWidth))
        .id(refreshID)
    }
}

private extension UIImage {
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
