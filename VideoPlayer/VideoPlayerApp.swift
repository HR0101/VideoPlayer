import SwiftUI

@main
struct VideoPlayerApp: App {
    @StateObject private var appSettings = AppSettings()
    // ★ 追加：ServerBrowserのインスタンスを作成
    @StateObject private var serverBrowser = ServerBrowser()

    var body: some Scene {
        WindowGroup {
            AlbumListView()
                .environmentObject(appSettings)
                // ★ 追加：ServerBrowserを全てのViewで使えるようにする
                .environmentObject(serverBrowser)
        }
    }
}
