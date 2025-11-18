import SwiftUI

// ===================================
//  AlbumListView.swift (デザイン修正版)
// ===================================

struct AlbumListView: View {
    @StateObject private var videoManager = VideoManager()
    @EnvironmentObject var serverBrowser: ServerBrowser
    
    @StateObject private var serverManager = ServerManager()
    
    @State private var newAlbumName = ""
    @State private var isShowingCreateAlbumAlert = false
    @State private var albumToDelete: String?
    @State private var isShowingDeleteConfirmAlert = false

    private let specialAlbums: [(type: AlbumType, name: String, icon: String)] = [
        (.all, "すべてのビデオ", "square.stack.fill"),
        (.trash, "ごみ箱", "trash.fill")
    ]
    
    // ★ 追加: カスタムカラー定義
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1) // 濃いダーク背景
    private let accentGlowColor = Color.cyan // 鮮やかなアクセント

    var body: some View {
        // ★ 修正: NavigationViewをNavigationStackに変更し、カスタムカラーを適用
        NavigationStack {
            List {
                Section {
                    ForEach(specialAlbums, id: \.type) { album in
                        NavigationLink(destination: VideoGridView(albumType: album.type, albumName: album.name, videoManager: videoManager)) {
                            HStack {
                                Image(systemName: album.icon)
                                    // ★ 修正: アイコンカラーを鮮やかに
                                    .foregroundColor(album.type == .trash ? .gray.opacity(0.7) : accentGlowColor)
                                    .font(.title3) // アイコンを少し大きく
                                Text(album.name)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                } header: {
                    Text("ライブラリ")
                        .font(.caption) // ヘッダーを控えめに
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    ForEach(videoManager.albums, id: \.self) { album in
                        NavigationLink(destination: VideoGridView(albumType: .user(album), albumName: album, videoManager: videoManager)) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    // ★ 修正: アイコンを鮮やかな色に
                                    .foregroundColor(.orange)
                                Text(album)
                            }
                        }
                    }
                    .onDelete(perform: prepareToDeleteAlbum)
                } header: {
                    Text("マイアルバム")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                }
                
                if let server = serverManager.server, let address = server.address {
                    Section {
                        if serverManager.isLoading {
                            ProgressView()
                        } else if let errorMessage = serverManager.errorMessage {
                            Text(errorMessage).foregroundColor(.secondary)
                        } else {
                            ForEach(serverManager.albums) { album in
                                NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: address, albumID: album.id)) {
                                    HStack {
                                        Image(systemName: "folder.fill")
                                            .foregroundColor(.yellow)
                                        Text(album.name)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(server.name)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(accentGlowColor) // サーバー名をアクセントカラーに
                    }
                } else {
                    Section {
                        Text("同じWi-Fi内でサーバーが見つかりません")
                            .foregroundColor(.secondary)
                    } header: {
                        Text("Mac サーバー")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                    }
                }
            }
            // ★ 修正: リストのスタイルと背景色を設定
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden) // 背景色をカスタムするために隠す
            .background(primaryDarkColor.ignoresSafeArea()) // 濃いダーク背景色

            .navigationTitle("アルバム")
            // ★ 修正: ナビゲーションバーのカスタム
            .toolbarColorScheme(.dark, for: .navigationBar) // ツールバーをダークに
            .toolbarBackground(primaryDarkColor, for: .navigationBar) // ツールバーの背景色
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isShowingCreateAlbumAlert = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(accentGlowColor)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                        .foregroundColor(accentGlowColor)
                }
            }
            .alert("新しいアルバム", isPresented: $isShowingCreateAlbumAlert) {
                TextField("アルバム名", text: $newAlbumName)
                Button("作成", action: createAlbum)
                Button("キャンセル", role: .cancel) {}
            }
            .alert("アルバムを削除", isPresented: $isShowingDeleteConfirmAlert, presenting: albumToDelete) { album in
                Button("削除", role: .destructive) {
                    videoManager.deleteAlbum(name: album)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { album in
                Text("「\(album)」を削除しますか？\nこのアルバム内のすべてのビデオが完全に削除され、この操作は取り消せません。")
            }
            .onAppear {
                videoManager.loadAlbums()
                serverBrowser.startBrowsing()
            }
            .onDisappear {
                serverBrowser.stopBrowsing()
            }
            .onChange(of: serverBrowser.discoveredServers) { servers in
                serverManager.updateServer(servers.first)
            }
        }
    }
    
    private func createAlbum() {
        if !newAlbumName.isEmpty {
            videoManager.createAlbum(name: newAlbumName)
            newAlbumName = ""
        }
    }

    private func prepareToDeleteAlbum(at offsets: IndexSet) {
        if let index = offsets.first {
            self.albumToDelete = videoManager.albums[index]
            self.isShowingDeleteConfirmAlert = true
        }
    }
}
