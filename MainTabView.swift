import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var serverManager: ServerManager
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
        .onAppear {
            serverBrowser.startBrowsing()
        }
        .onChange(of: serverBrowser.discoveredServers) { _, servers in
            serverManager.updateServer(servers.first)
        }
    }
}

// MARK: - ホームタブ
struct HomeTabView: View {
    @EnvironmentObject var serverManager: ServerManager
    
    var body: some View {
        if let server = serverManager.server, let address = server.address {
            NavigationStack {
                RemoteVideoListView(
                    serverName: "ホーム",
                    serverAddress: address,
                    albumID: "HOME", // "HOME" ID for randomized feed
                    allServerAlbums: serverManager.albums
                )
            }
        } else {
            ServerConnectingView(title: "ホーム")
        }
    }
}

// MARK: - ショートタブ
struct ShortsTabView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var navState: AppNavigationState
    
    var body: some View {
        if let server = serverManager.server, let address = server.address {
            NavigationStack {
                RemoteVideoListView(
                    serverName: "ショート",
                    serverAddress: address,
                    albumID: "SHORTS",
                    allServerAlbums: serverManager.albums,
                    initialVideoToPlay: navState.targetShortsVideo
                )
            }
            .onChange(of: navState.targetShortsVideo) { _, _ in
                // Target shorts video changed, RemoteVideoListView will handle if we pass it, but wait:
                // If it's already rendered, RemoteVideoListView's task won't rerun unless id changes.
                // We can use .id to force recreation if needed, but it might reset the whole list.
            }
        } else {
            ServerConnectingView(title: "ショート")
        }
    }
}

// MARK: - サーバー接続中のローディング画面
struct ServerConnectingView: View {
    let title: String
    @State private var showNotFound = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if showNotFound {
                    VStack(spacing: 20) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 60))
                            .foregroundStyle(.gray)
                        Text("サーバーに接続されていません")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("「アルバム」タブからサーバーに接続してください")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                } else {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(Color.appGold.opacity(0.2), lineWidth: 3)
                                .frame(width: 56, height: 56)
                            ProgressView().scaleEffect(1.4).tint(Color.appGold)
                        }
                        Text("サーバーを探しています...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation { showNotFound = true }
            }
        }
    }
}
