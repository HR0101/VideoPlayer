import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var serverManager: ServerConnectionViewModel
    @EnvironmentObject var serverBrowser: ServerBrowser
    @EnvironmentObject var navState: AppNavigationState

    var body: some View {
        TabView(selection: $navState.selectedTab) {
            // 1. ホームタブ (YouTube風 おすすめ動画)
            HomeTabView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("ホーム")
                }
                .tag(0)

            // 2. ショートタブ
            ShortsTabView()
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text("ショート")
                }
                .tag(1)

            // 3. アルバムタブ (従来のメイン画面)
            AlbumListView()
                .tabItem {
                    Image(systemName: "square.stack.fill")
                    Text("アルバム")
                }
                .tag(2)

            // 4. 設定タブ
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("設定")
                }
                .tag(3)
        }
        .tint(Color.appGold)
        .preferredColorScheme(.dark)
        .onAppear {
            serverBrowser.startBrowsing()
        }
        .onChange(of: serverBrowser.discoveredServers) { _, servers in
            serverManager.updateServer(servers.first)
        }
    }
}
