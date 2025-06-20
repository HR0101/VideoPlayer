// ===================================
//  VideoPlayerApp.swift
// ===================================
// アプリケーションのエントリーポイントです。

import SwiftUI

@main
struct VideoPlayerApp: App {
    // アプリ全体で共有する設定オブジェクトを作成します。
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup {
            AlbumListView()
                // すべてのビューで設定を使えるようにします。
                .environmentObject(appSettings)
        }
    }
}
