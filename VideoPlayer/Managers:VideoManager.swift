import SwiftUI

// MARK: - Video and Album Manager
/// ビデオとアルバムのファイルシステム操作を管理するクラス
class VideoManager: ObservableObject {
    @Published var userAlbums: [String] = []
    
    private let fileManager = FileManager.default
    private let rootDirectory: URL
    private let trashDirectory: URL
    
    let trashAlbumName = "ごみ箱"

    init() {
        // Documentsディレクトリ内にルートフォルダを作成
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("ドキュメントディレクトリにアクセスできません.")
        }
        rootDirectory = documentsURL.appendingPathComponent("VideoAlbums")
        trashDirectory = rootDirectory.appendingPathComponent(trashAlbumName)
        
        createInitialDirectories()
        loadAlbums()
    }
    
    /// 初期ディレクトリ（ルートとごみ箱）を作成する
    private func createInitialDirectories() {
        do {
            if !fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
            }
            if !fileManager.fileExists(atPath: trashDirectory.path) {
                try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            print("初期ディレクトリの作成に失敗しました: \(error)")
        }
    }
    
    /// ユーザーが作成したアルバムのリストを読み込む
    func loadAlbums() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            self.userAlbums = contents
                .filter { $0.hasDirectoryPath }
                .map { $0.lastPathComponent }
                .filter { $0 != trashAlbumName } // ごみ箱は除外
                .sorted()
        } catch {
            print("アルバムの読み込みに失敗しました: \(error)")
            self.userAlbums = []
        }
    }

    /// 新しいアルバム（フォルダ）を作成する
    func createAlbum(name: String) {
        guard !name.isEmpty && name != trashAlbumName else { return }
        let albumURL = rootDirectory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: albumURL.path) {
            do {
                try fileManager.createDirectory(at: albumURL, withIntermediateDirectories: true, attributes: nil)
                loadAlbums() // リストを更新
            } catch {
                print("アルバムの作成に失敗しました: \(error)")
            }
        }
    }

    /// アルバム（フォルダ）を削除する
    func deleteAlbum(name: String) {
        let albumURL = rootDirectory.appendingPathComponent(name)
        do {
            try fileManager.removeItem(at: albumURL)
            loadAlbums() // リストを更新
        } catch {
            print("アルバムの削除に失敗しました: \(error)")
        }
    }
    
    /// 指定されたアルバムタイプのビデオURLリストを取得する
    func fetchVideos(for albumType: AlbumType) -> [URL] {
        let targetURL: URL
        
        switch albumType {
        case .all:
            // すべてのユーザーアルバムからビデオを取得（ごみ箱は除く）
            var allVideos: [URL] = []
            let albumsToScan = userAlbums.map { rootDirectory.appendingPathComponent($0) }
            for albumURL in albumsToScan {
                allVideos.append(contentsOf: getVideos(from: albumURL))
            }
            return allVideos
        case .trash:
            targetURL = trashDirectory
        case .user(let name):
            targetURL = rootDirectory.appendingPathComponent(name)
        }
        
        return getVideos(from: targetURL)
    }

    private func getVideos(from directoryURL: URL) -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { !$0.hasDirectoryPath } // ファイルのみを対象
        } catch {
            print("\(directoryURL.lastPathComponent) からのビデオ取得に失敗: \(error)")
            return []
        }
    }
    
    /// ファイルピッカーで選択されたビデオを指定されたアルバムにインポートする
    func importVideos(from urls: [URL], to albumName: String) {
        let albumURL = rootDirectory.appendingPathComponent(albumName)
        
        for sourceURL in urls {
            // ファイルへのアクセスを開始
            let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let destinationURL = albumURL.appendingPathComponent(sourceURL.lastPathComponent)
                // ファイルが既に存在する場合は、上書きせずにスキップする
                if fileManager.fileExists(atPath: destinationURL.path) {
                    print("\(sourceURL.lastPathComponent) は既に存在します.")
                    continue
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                print("ビデオのインポートに失敗しました (\(sourceURL.lastPathComponent)): \(error)")
            }
        }
        // UIを更新するためにPublishedプロパティを変更する
        // ここでは直接UIを更新するプロパティがないため、ビュー側で再読み込みをトリガーする必要がある
        objectWillChange.send()
    }
    
    /// ビデオをごみ箱フォルダに移動する
    func moveVideosToTrash(urls: [URL]) {
        for url in urls {
            let destinationURL = trashDirectory.appendingPathComponent(url.lastPathComponent)
            moveItem(at: url, to: destinationURL)
        }
    }

    /// ビデオをごみ箱から復元する（最初のユーザーアルバムに戻す）
    func restoreVideosFromTrash(urls: [URL]) {
        guard let defaultAlbumName = userAlbums.first else {
            // 復元先のアルバムがない場合は、新しいアルバムを作成する
            let newAlbumName = "復元されたビデオ"
            createAlbum(name: newAlbumName)
            let destinationAlbumURL = rootDirectory.appendingPathComponent(newAlbumName)
            for url in urls {
                let destinationURL = destinationAlbumURL.appendingPathComponent(url.lastPathComponent)
                moveItem(at: url, to: destinationURL)
            }
            return
        }
        let destinationAlbumURL = rootDirectory.appendingPathComponent(defaultAlbumName)
        for url in urls {
            let destinationURL = destinationAlbumURL.appendingPathComponent(url.lastPathComponent)
            moveItem(at: url, to: destinationURL)
        }
    }

    /// ビデオをファイルシステムから完全に削除する
    func deletePermanently(urls: [URL]) {
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                print("\(url.lastPathComponent) の完全な削除に失敗: \(error)")
            }
        }
    }

    /// ごみ箱を空にする
    func emptyTrash() {
        let videoURLs = getVideos(from: trashDirectory)
        deletePermanently(urls: videoURLs)
    }
    
    private func moveItem(at sourceURL: URL, to destinationURL: URL) {
        do {
            // 同じ名前のファイルが移動先に存在する場合、まずそれを削除する
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            print("\(sourceURL.lastPathComponent) の移動に失敗: \(error)")
        }
    }
}
