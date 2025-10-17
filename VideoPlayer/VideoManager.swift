import Foundation
import SwiftUI

// ===================================
//  VideoManager.swift
// ===================================
// アルバム、ごみ箱の管理を担当します。
@MainActor
class VideoManager: ObservableObject {
    @Published var albums: [String] = []
    
    private let rootDirectory: URL
    private let trashDirectory: URL
    private let originalAlbumAttributeKey = "jp.co.yourapp.originalAlbum"

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootDirectory = documentsPath.appendingPathComponent("VideoAlbums")
        trashDirectory = rootDirectory.appendingPathComponent("ごみ箱")
        
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
            case .trash:
                videoURLs = try FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
            case .user(let albumName):
                let albumURL = rootDirectory.appendingPathComponent(albumName)
                videoURLs = try FileManager.default.contentsOfDirectory(at: albumURL, includingPropertiesForKeys: nil)
            }
            return videoURLs.filter { url in
                let pathExtension = url.pathExtension.lowercased()
                return (pathExtension == "mov" || pathExtension == "mp4") && !url.lastPathComponent.hasPrefix(".")
            }
        } catch {
            print("Error fetching videos for \(albumType): \(error)")
            return []
        }
    }

    // MARK: - Video Operations
    func importVideos(from urls: [URL], to albumName: String) async {
        let albumURL = rootDirectory.appendingPathComponent(albumName)
        createAlbum(name: albumName)
        
        for url in urls {
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer { if shouldStopAccessing { url.stopAccessingSecurityScopedResource() } }
            
            do {
                let originalFileName = url.lastPathComponent
                var destinationURL = albumURL.appendingPathComponent(originalFileName)
                var counter = 2
                
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    let fileNameWithoutExtension = url.deletingPathExtension().lastPathComponent
                    let fileExtension = url.pathExtension
                    let newFileName = "\(fileNameWithoutExtension) (\(counter)).\(fileExtension)"
                    destinationURL = albumURL.appendingPathComponent(newFileName)
                    counter += 1
                }
                
                try FileManager.default.copyItem(at: url, to: destinationURL)
                
            } catch {
                print("Error importing video: \(error.localizedDescription)")
            }
        }
    }

    func moveVideoToTrash(url: URL) {
        do {
            let originalAlbum = url.deletingLastPathComponent().lastPathComponent
            if originalAlbum != "ごみ箱" {
                try setExtendedAttribute(at: url, name: originalAlbumAttributeKey, value: originalAlbum)
            }
            
            let destinationURL = trashDirectory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destinationURL)
        } catch {
            print("Error moving video to trash: \(error)")
        }
    }

    func restoreVideoFromTrash(url: URL) {
        do {
            let originalAlbum = try getExtendedAttribute(at: url, name: originalAlbumAttributeKey)
            let destinationAlbumName = originalAlbum ?? "マイアルバム"
            createAlbum(name: destinationAlbumName)
            
            let destinationURL = rootDirectory.appendingPathComponent(destinationAlbumName).appendingPathComponent(url.lastPathComponent)
            
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

    // MARK: - Extended Attribute Helpers
    private func setExtendedAttribute(at url: URL, name: String, value: String) throws {
        guard let valueData = value.data(using: .utf8) else { return }
        let result = valueData.withUnsafeBytes {
            setxattr(url.path, name, $0.baseAddress, valueData.count, 0, 0)
        }
        if result == -1 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to set extended attribute."])
        }
    }

    private func getExtendedAttribute(at url: URL, name: String) throws -> String? {
        let bufferSize = 256
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let readBytes = getxattr(url.path, name, &buffer, bufferSize, 0, 0)

        if readBytes > 0 {
            return String(cString: buffer)
        }
        
        if readBytes == -1 && errno == ENOATTR {
            return nil
        }
        
        if readBytes == -1 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to get extended attribute."])
        }
        
        return nil
    }
}
