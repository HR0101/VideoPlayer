// ===================================
//  VideoManager.swift
// ===================================
// アルバム、ごみ箱の管理を担当します。

import SwiftUI
import AVFoundation

@MainActor
class VideoManager: ObservableObject {
    @Published var albums: [String] = []
    
    private let rootDirectory: URL
    private let trashDirectory: URL
    // favoritesFileURLを削除

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootDirectory = documentsPath.appendingPathComponent("VideoAlbums")
        trashDirectory = rootDirectory.appendingPathComponent("ごみ箱")
        // favoritesFileURLの初期化を削除
        
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true, attributes: nil)
        
        loadAlbums()
    }

    // MARK: - Album Management
    func loadAlbums() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            self.albums = contents.filter { $0.hasDirectoryPath && $0.lastPathComponent != "ごみ箱" }.map { $0.lastPathComponent }.sorted()
        } catch {
            print("Error loading albums: \(error)")
        }
    }

    func createAlbum(name: String) {
        guard !name.isEmpty, name != "ごみ箱" else { return }
        let albumURL = rootDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: albumURL.path) {
            do {
                try FileManager.default.createDirectory(at: albumURL, withIntermediateDirectories: true, attributes: nil)
                loadAlbums()
            } catch {
                print("Error creating album: \(error)")
            }
        }
    }
    
    func deleteAlbum(name: String) {
        let albumURL = rootDirectory.appendingPathComponent(name)
        // お気に入り情報の削除処理を削除
        
        do {
            try FileManager.default.removeItem(at: albumURL)
            loadAlbums()
        } catch {
            print("Error deleting album: \(error)")
        }
    }

    // MARK: - Video Fetching
    func fetchVideos(for albumType: AlbumType) -> [URL] {
        var videoURLs: [URL] = []
        do {
            switch albumType {
            case .all:
                for albumName in albums {
                    let albumURL = rootDirectory.appendingPathComponent(albumName)
                    videoURLs.append(contentsOf: try FileManager.default.contentsOfDirectory(at: albumURL, includingPropertiesForKeys: nil))
                }
            // .favorites ケースを削除
            case .trash:
                videoURLs = try FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
            case .user(let albumName):
                let albumURL = rootDirectory.appendingPathComponent(albumName)
                videoURLs = try FileManager.default.contentsOfDirectory(at: albumURL, includingPropertiesForKeys: nil)
            }
            return videoURLs.filter { $0.pathExtension.lowercased() == "mov" || $0.pathExtension.lowercased() == "mp4" }
        } catch {
            print("Error fetching videos for \(albumType): \(error)")
            return []
        }
    }

    // MARK: - Video Operations
    func importVideos(from urls: [URL], to albumName: String) async {
        let albumURL = rootDirectory.appendingPathComponent(albumName)
        createAlbum(name: albumName) // アルバムがなければ作成
        
        for url in urls {
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer { if shouldStopAccessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let uniqueFileName = UUID().uuidString + "." + url.pathExtension
                let destinationURL = albumURL.appendingPathComponent(uniqueFileName)
                try FileManager.default.copyItem(at: url, to: destinationURL)
            } catch {
                print("Error importing video: \(error.localizedDescription)")
            }
        }
    }
    
    func moveVideoToTrash(url: URL) {
        do {
            let destinationURL = trashDirectory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destinationURL)
            // お気に入りからの削除処理を削除
        } catch {
            print("Error moving video to trash: \(error)")
        }
    }

    func restoreVideoFromTrash(url: URL) {
        let defaultAlbum = "マイアルバム"
        createAlbum(name: defaultAlbum)
        let destinationURL = rootDirectory.appendingPathComponent(defaultAlbum).appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: destinationURL)
        } catch {
            print("Error restoring video: \(error)")
        }
    }

    func deletePermanently(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Error deleting video permanently: \(error)")
        }
    }

    func emptyTrash() {
        let trashItems = fetchVideos(for: .trash)
        for item in trashItems { deletePermanently(url: item) }
    }

    // MARK: - Favorites Management
    // このセクション全体を削除
}
