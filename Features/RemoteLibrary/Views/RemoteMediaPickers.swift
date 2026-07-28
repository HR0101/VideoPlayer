import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

struct PickedMediaItem {
    let tempURL: URL
    let originalFilename: String
    let deleteAction: () async throws -> Void
}

struct ServerPhotoPicker: UIViewControllerRepresentable {
    let onMediaPicked: ([PickedMediaItem]) -> Void
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.videos, .images])
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ServerPhotoPicker
        init(_ parent: ServerPhotoPicker) { self.parent = parent }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            
            let group = DispatchGroup()
            var pickedItems: [PickedMediaItem] = []
            let queue = DispatchQueue(label: "pickedItems.queue")
            
            for result in results {
                group.enter()
                let provider = result.itemProvider
                let assetIdentifier = result.assetIdentifier
                
                let handleURL: (URL?) -> Void = { sourceURL in
                    defer { group.leave() }
                    guard let sourceURL = sourceURL else { return }
                    
                    let tempDir = FileManager.default.temporaryDirectory
                    let uniqueDir = tempDir.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)
                        let finalURL = uniqueDir.appendingPathComponent(sourceURL.lastPathComponent)
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                        
                        let deleteAction: () async throws -> Void = {
                            if let id = assetIdentifier {
                                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                                if let asset = assets.firstObject {
                                    try await PHPhotoLibrary.shared().performChanges {
                                        PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                                    }
                                }
                            }
                        }
                        
                        let item = PickedMediaItem(tempURL: finalURL, originalFilename: sourceURL.lastPathComponent, deleteAction: deleteAction)
                        queue.sync { pickedItems.append(item) }
                    } catch {
                        print("Copy error: \(error)")
                    }
                }
                
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in handleURL(url) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in handleURL(url) }
                } else {
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                if !pickedItems.isEmpty {
                    self.parent.onMediaPicked(pickedItems)
                }
            }
        }
    }
}

struct ServerDocumentPicker: UIViewControllerRepresentable {
    let onMediaPicked: ([PickedMediaItem]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .image], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ServerDocumentPicker
        init(_ parent: ServerDocumentPicker) { self.parent = parent }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var pickedItems: [PickedMediaItem] = []
            
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                let tempDir = FileManager.default.temporaryDirectory
                let uniqueDir = tempDir.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)
                    let finalURL = uniqueDir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: finalURL)
                    
                    // セキュリティスコープを維持したまま後で削除できるようにブックマークを作成
                    let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    
                    let deleteAction: () async throws -> Void = {
                        var isStale = false
                        let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                        let access = resolvedURL.startAccessingSecurityScopedResource()
                        defer { if access { resolvedURL.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.removeItem(at: resolvedURL)
                    }
                    
                    let item = PickedMediaItem(tempURL: finalURL, originalFilename: url.lastPathComponent, deleteAction: deleteAction)
                    pickedItems.append(item)
                } catch {
                    print("Document picker copy error: \(error)")
                }
                
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            if !pickedItems.isEmpty {
                parent.onMediaPicked(pickedItems)
            }
        }
    }
}
