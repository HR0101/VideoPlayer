//
//  Representables:DocumentPicker..swift
//  VideoPlayer
//
//  Created by hara ryuto   on 2025/06/20.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: DocumentPicker
/// UIDocumentPickerViewControllerをSwiftUIで利用するためのラッパー
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // ビデオファイルタイプを許可
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie, UTType.video], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
    }
}
