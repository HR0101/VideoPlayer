import Foundation
import Combine
import Photos
import UIKit

// ===================================
//  DownloadManager.swift
// ===================================
// 動画のダウンロード進捗を管理し、写真アプリへの保存を行うクラス

@MainActor
class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0.0
    @Published var isDownloading = false
    @Published var currentFilename: String = ""
    @Published var errorMessage: String?
    @Published var successMessage: String?
    
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var isPhoto = false
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        // 動画ダウンロード用にタイムアウトを長く設定 (1時間)
        config.timeoutIntervalForResource = 3600
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }
    
    func startDownload(url: URL, filename: String, isPhoto: Bool) {
        guard !isDownloading else { return }
        
        self.isDownloading = true
        self.progress = 0.0
        self.currentFilename = filename
        self.errorMessage = nil
        self.successMessage = nil
        self.isPhoto = isPhoto
        
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        resetState()
    }
    
    private func resetState() {
        isDownloading = false
        progress = 0.0
        currentFilename = ""
        downloadTask = nil
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            self.progress = p
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // レスポンスコードを確認 (200番台以外はエラーとする)
        guard let httpResponse = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            self.errorMessage = "ダウンロードエラー: サーバー応答 \(status)"
            self.isDownloading = false
            return
        }
        
        // locationにあるファイルはメソッド終了後に消えるため、一時ディレクトリに移動させる
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent(currentFilename)
        
        do {
            // 同名の古い一時ファイルがあれば削除
            if FileManager.default.fileExists(atPath: tempFileURL.path) {
                try FileManager.default.removeItem(at: tempFileURL)
            }
            // ファイルを移動
            try FileManager.default.moveItem(at: location, to: tempFileURL)
            
            // 写真ライブラリへ保存
            saveToPhotoLibrary(from: tempFileURL)
            
        } catch {
            self.errorMessage = "ファイル処理エラー: \(error.localizedDescription)"
            self.isDownloading = false
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // キャンセル時はエラーメッセージを出さない
            if (error as NSError).code == NSURLErrorCancelled {
                self.isDownloading = false
            } else {
                self.errorMessage = "通信エラー: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }
    
    private func saveToPhotoLibrary(from localURL: URL) {
        let filename = currentFilename
        let saveAsPhoto = isPhoto
        PHPhotoLibrary.shared().performChanges({
            if saveAsPhoto {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: localURL)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)
            }
        }) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? FileManager.default.removeItem(at: localURL)
                self.isDownloading = false
                if success {
                    self.successMessage = "「\(filename)」を保存しました"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.successMessage = nil
                } else {
                    self.errorMessage = "写真アプリへの保存に失敗しました: \(error?.localizedDescription ?? "不明なエラー")"
                }
            }
        }
    }
}
