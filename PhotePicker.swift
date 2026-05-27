import SwiftUI
import PhotosUI

// ===================================
//  PhotoPicker.swift
// ===================================
// 写真アプリを開き、ビデオを選択するためのUIViewControllerRepresentableです。
struct PhotoPicker: UIViewControllerRepresentable {
    let albumName: String
    let videoManager: VideoManager
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 0
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                parent.onDismiss()
                return
            }
            
            var urlsToImport: [URL] = []
            let group = DispatchGroup()

            for result in results {
                group.enter()
                let itemProvider = result.itemProvider
                
                if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                        defer { group.leave() }
                        
                        if let error = error {
                            print("Photo Picker Error: Failed to load file representation: \(error)")
                            return
                        }
                        
                        guard let sourceURL = url else {
                            print("Photo Picker Error: Source URL is nil.")
                            return
                        }
                        
                        let tempDirectory = FileManager.default.temporaryDirectory
                        let destinationURL = tempDirectory.appendingPathComponent(sourceURL.lastPathComponent)

                        do {
                            if FileManager.default.fileExists(atPath: destinationURL.path) {
                                try FileManager.default.removeItem(at: destinationURL)
                            }
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                            urlsToImport.append(destinationURL)
                        } catch {
                            print("Photo Picker Error: Failed to copy temporary file: \(error)")
                        }
                    }
                } else {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                guard !urlsToImport.isEmpty else {
                    self.parent.onDismiss()
                    return
                }
                
                Task {
                    await self.parent.videoManager.importVideos(from: urlsToImport, to: self.parent.albumName)
                    self.parent.onDismiss()
                }
            }
        }
    }
}
