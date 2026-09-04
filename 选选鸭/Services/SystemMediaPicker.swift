import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum SystemMediaPickerMode: String, Identifiable {
    case cameraPhoto
    case cameraVideo
    case libraryPhoto
    case libraryVideo

    var id: String { rawValue }
}

struct SystemMediaPicker: UIViewControllerRepresentable {
    let mode: SystemMediaPickerMode
    var onPicked: (URL, AttachmentKind) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false

        switch mode {
        case .cameraPhoto:
            picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            picker.mediaTypes = [UTType.image.identifier]
            picker.cameraCaptureMode = .photo
        case .cameraVideo:
            picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoMaximumDuration = 60
            picker.videoQuality = .typeMedium
        case .libraryPhoto:
            picker.sourceType = .photoLibrary
            picker.mediaTypes = [UTType.image.identifier]
        case .libraryVideo:
            picker.sourceType = .photoLibrary
            picker.mediaTypes = [UTType.movie.identifier]
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemMediaPicker

        init(parent: SystemMediaPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let mediaType = info[.mediaType] as? String

            if mediaType == UTType.movie.identifier, let url = info[.mediaURL] as? URL {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("duck-\(UUID().uuidString).mov")
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: url, to: dest)
                parent.onPicked(dest, .video)
                return
            }

            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.86) {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("duck-\(UUID().uuidString).jpg")
                try? data.write(to: dest)
                parent.onPicked(dest, .image)
                return
            }

            parent.onCancel()
        }
    }
}
