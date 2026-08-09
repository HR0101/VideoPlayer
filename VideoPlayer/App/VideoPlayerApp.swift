import SwiftUI
import AVFoundation

@main
struct VideoPlayerApp: App {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var serverBrowser = ServerBrowser()
    @StateObject private var serverManager = ServerConnectionViewModel()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var navState = AppNavigationState()
    @StateObject private var remoteControlViewModel = RemoteControlViewModel()

    init() {
        // 動画アプリとして、端末のサイレント（消音）スイッチに関係なく音声を再生する。
        // これを設定しないと既定が .soloAmbient になり、消音モード時にアプリ全体で音が出なくなる。
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession の設定に失敗: \(error)")
        }

        // サムネイルを AsyncImage（共有URLSession）で大量に読むため、既定では小さい
        // URLCache を拡大する。サーバー側の Cache-Control と合わせて再取得を防ぐ。
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                MainTabView()
                    .environmentObject(appSettings)
                    .environmentObject(serverBrowser)
                    .environmentObject(serverManager)
                    .environmentObject(downloadManager)
                    .environmentObject(navState)
                    .environmentObject(remoteControlViewModel)

                if downloadManager.isDownloading || downloadManager.successMessage != nil || downloadManager.errorMessage != nil {
                    DownloadStatusOverlay()
                        .environmentObject(downloadManager)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(100)
                }
            }
        }
    }
}
