import Foundation
import SwiftUI
import UserNotifications
import Photos
import UIKit



class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, UNUserNotificationCenterDelegate {
    static let shared = DownloadManager()
    
    @Published var activeDownloads: [URL: Double] = [:]
    @Published var overallProgress: Double = 0.0
    @Published var isDownloading = false
    
    // UI側での表示用プロパティ
    @Published var successMessage: String?
    @Published var errorMessage: String?
    @Published var progress: Double = 0.0 // ★ 10000%問題を解決するため、0.0〜1.0の範囲に修正
    @Published var currentFilename: String = "" // 現在ダウンロード中のファイル名
    
    private var backgroundSession: URLSession!
    private var overlayWindow: UIWindow?
    private var taskToFilename: [Int: String] = [:]
    private var taskToIsPhoto: [Int: Bool] = [:]
    
    override init() {
        super.init()
        
        // アプリを閉じてもiOSがダウンロードを継続してくれるバックグラウンド設定
        let config = URLSessionConfiguration.background(withIdentifier: "com.app.videoServer.backgroundDownload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // アプリ起動中にも通知を表示するためのデリゲート設定
        UNUserNotificationCenter.current().delegate = self
        requestPermissions()
    }
    
    private func requestPermissions() {
        // 通知の許可
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // 写真アプリ（カメラロール）へのアクセス許可
        PHPhotoLibrary.requestAuthorization { _ in }
    }
    
    // アプリを開いている最中でも通知バナーを表示する設定
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
    
    func startDownload(url: URL, filename: String, isPhoto: Bool) {
        let task = backgroundSession.downloadTask(with: url)
        task.taskDescription = filename
        taskToFilename[task.taskIdentifier] = filename
        taskToIsPhoto[task.taskIdentifier] = isPhoto
        task.resume()
        
        DispatchQueue.main.async {
            self.currentFilename = filename // ダウンロード中のファイル名をセット
            self.activeDownloads[url] = 0.0
            self.updateOverallProgress()
            self.showFloatingWindow()
        }
    }
    
    // ダウンロードをキャンセルする機能
    func cancelDownload() {
        backgroundSession.getTasksWithCompletionHandler { _, _, downloadTasks in
            for task in downloadTasks {
                task.cancel()
            }
            DispatchQueue.main.async {
                self.activeDownloads.removeAll()
                self.isDownloading = false
                self.overallProgress = 0.0
                self.progress = 0.0
                self.currentFilename = ""
                self.errorMessage = "ダウンロードをキャンセルしました。"
                self.hideFloatingWindowAfterDelay()
            }
        }
    }
    

    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let originalURL = downloadTask.originalRequest?.url else { return }
        let progressRatio = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        DispatchQueue.main.async {
            self.activeDownloads[originalURL] = progressRatio
            self.updateOverallProgress()
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let originalURL = downloadTask.originalRequest?.url else { return }
        let filename = downloadTask.taskDescription ?? "downloaded_file"
        let isPhoto = taskToIsPhoto[downloadTask.taskIdentifier] ?? false
        
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent(filename)
        
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            
            self.sendNotification(title: "ダウンロード完了", body: "「\(filename)」を写真アプリに保存しました。")
            
            // iOSの写真アプリへ保存
            saveToPhotoLibrary(fileURL: destinationURL, isPhoto: isPhoto, filename: filename, originalURL: originalURL)
            
        } catch {
            print("ファイルの移動エラー: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "ファイルの保存準備中にエラーが発生しました。"
                self.removeDownload(url: originalURL)
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let originalURL = task.originalRequest?.url else { return }
        
        if let error = error {
            let nsError = error as NSError
            // キャンセルされた場合はエラーとして扱わずに処理を終了する
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                DispatchQueue.main.async {
                    self.removeDownload(url: originalURL)
                }
                return
            }
            
            print("ダウンロードエラー: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "ダウンロードに失敗しました: \(error.localizedDescription)"
                self.removeDownload(url: originalURL)
            }
        }
    }
    

    
    private func saveToPhotoLibrary(fileURL: URL, isPhoto: Bool, filename: String, originalURL: URL) {

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        
        PHPhotoLibrary.shared().performChanges({
            if isPhoto {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
        }) { success, error in
            try? FileManager.default.removeItem(at: fileURL)
            
            DispatchQueue.main.async {
                if success {
                    self.successMessage = "「\(filename)」を写真アプリに保存しました。"
                } else {
                    self.errorMessage = "写真アプリへの保存に失敗しました。"
                    self.sendNotification(title: "保存失敗", body: "「\(filename)」の写真アプリへの保存に失敗しました。")
                }
                self.removeDownload(url: originalURL)
                
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
    }
    

    
    private func removeDownload(url: URL) {
        activeDownloads.removeValue(forKey: url)
        updateOverallProgress()
        if activeDownloads.isEmpty {
            hideFloatingWindowAfterDelay()
        }
    }
    
    private func updateOverallProgress() {
        if activeDownloads.isEmpty {
            overallProgress = 1.0
            progress = 1.0
            isDownloading = false
            currentFilename = ""
        } else {
            let total = activeDownloads.values.reduce(0, +)
            overallProgress = total / Double(activeDownloads.count)
            progress = overallProgress
            isDownloading = true
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("通知の送信エラー: \(error)")
            }
        }
    }
    

    
    private func showFloatingWindow() {
        guard overlayWindow == nil else { return }
        
 
        guard let windowScene = UIApplication.shared.connectedScenes
                .filter({ $0.activationState == .foregroundActive })
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }
        
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        
        let hostingController = UIHostingController(rootView: IOSDynamicIslandProgressView(manager: self))
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.isHidden = false
        
        self.overlayWindow = window
    }
    
    private func hideFloatingWindowAfterDelay() {
        // 完了後、2秒待ってからフェードアウトする
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.activeDownloads.isEmpty {
                UIView.animate(withDuration: 0.5, animations: {
                    self.overlayWindow?.alpha = 0.0
                }) { _ in
                    self.overlayWindow?.isHidden = true
                    self.overlayWindow = nil
                }
            }
        }
    }
}



struct IOSDynamicIslandProgressView: View {
    @ObservedObject var manager: DownloadManager
    @State private var showCheckmark = false
    
    var body: some View {
        VStack {
            HStack(spacing: 12) {
                if manager.isDownloading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                        .onAppear {
                            withAnimation(.spring()) { showCheckmark = true }
                        }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.isDownloading ? "ダウンロード中..." : "保存完了")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                            Capsule()
                                .fill(manager.isDownloading ? Color.white : Color.green)
                                .frame(width: geo.size.width * max(0.05, manager.overallProgress))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.9))
                    .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
            )
            .frame(width: 240)
            // iPhoneのノッチやダイナミックアイランドのすぐ下に配置されるように調整
            .padding(.top, safeAreaTop() + 5)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: manager.overallProgress)
            .animation(.easeInOut, value: manager.isDownloading)
            
            Spacer()
        }
        .ignoresSafeArea()
    }
    
    private func safeAreaTop() -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first
        return window?.safeAreaInsets.top ?? 47
    }
}
