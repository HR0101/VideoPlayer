import SwiftUI

// MARK: - App Entry Point
@main
struct VideoPlayerApp: App {
    // アプリケーション全体で共有されるインスタンス
    @StateObject private var videoManager = VideoManager()
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup {
            // メインビューに環境オブジェクトとしてインスタンスを渡す
            AlbumListView()
                .environmentObject(videoManager)
                .environmentObject(appSettings)
        }
    }
}
