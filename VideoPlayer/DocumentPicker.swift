// ===================================
//  DocumentPicker.swift
// ===================================
// ファイルアプリを開くためのUIViewControllerRepresentableです。

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    let albumName: String
    let videoManager: VideoManager
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task {
                await parent.videoManager.importVideos(from: urls, to: parent.albumName)
                parent.onDismiss()
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
             parent.onDismiss()
        }
    }
}
