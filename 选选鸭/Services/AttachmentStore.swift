import AVFoundation
import Foundation
import UIKit

enum AttachmentStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把临时文件持久化到 App Documents，返回相对路径（Attachments/xxx.jpg）。
    static func persist(tempURL: URL, preferredName: String? = nil) throws -> String {
        let ext = tempURL.pathExtension.isEmpty ? "jpg" : tempURL.pathExtension
        let name = preferredName ?? "duck-\(UUID().uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: tempURL, to: dest)
        return "Attachments/\(name)"
    }

    /// 将 UIImage 存成 JPEG，返回相对路径。
    static func persistJPEG(_ image: UIImage, preferredName: String? = nil, quality: CGFloat = 0.9) throws -> String {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw NSError(domain: "AttachmentStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "头像编码失败"])
        }
        let name = preferredName ?? "avatar-\(UUID().uuidString).jpg"
        let dest = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try data.write(to: dest, options: .atomic)
        return "Attachments/\(name)"
    }

    static func fileURL(relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func loadImage(relativePath: String?) -> UIImage? {
        guard let url = fileURL(relativePath: relativePath) else { return nil }
        if let image = UIImage(contentsOfFile: url.path) { return image }
        return videoThumbnail(url: url)
    }

    static func loadImage(fileURL: URL?) -> UIImage? {
        guard let fileURL else { return nil }
        if let image = UIImage(contentsOfFile: fileURL.path) { return image }
        return videoThumbnail(url: fileURL)
    }

    static func jpegDataForVision(relativePath: String?, maxDimension: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        guard let image = loadImage(relativePath: relativePath) else { return nil }
        let resized = resize(image, maxDimension: maxDimension)
        return resized.jpegData(compressionQuality: quality)
    }

    static func jpegDatasForVision(relativePaths: [String], maxDimension: CGFloat = 1280, quality: CGFloat = 0.72) -> [Data] {
        relativePaths.compactMap { jpegDataForVision(relativePath: $0, maxDimension: maxDimension, quality: quality) }
    }

    static func videoThumbnail(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

enum DuckTextSanitizer {
    /// 去掉 markdown 星号/标题/行内代码，避免界面出现 *** ***。
    static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\*\*\*([^*]+)\*\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "***", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「鸭鸭眼中的你」展示/落库：只要分析正文，去掉专属风格、【】标题行。
    static func duckEyeSummary(from text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }

        if let range = body.range(of: "【鸭鸭分析】") {
            body = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let dropPrefixes = [
            "【专属风格】", "【结果】", "【标签】", "【鸭鸭分析】",
            "专属风格：", "专属风格:", "结果：", "结果:", "标签：", "标签:"
        ]
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            if dropPrefixes.contains(where: { t.hasPrefix($0) }) { return true }
            // 单独一行的短【标题】也丢掉
            if t.hasPrefix("【"), t.hasSuffix("】"), t.count <= 16 { return true }
            return false
        }
        body = lines.joined(separator: "\n")
        body = body.replacingOccurrences(of: #"【[^】\n]{1,20}】"#, with: "", options: .regularExpression)
        return plain(body)
    }
}
