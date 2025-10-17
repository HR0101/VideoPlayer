import SwiftUI

// ===================================
//  AlbumListView.swift (修正版)
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

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("ライブラリ")) {
                    ForEach(specialAlbums, id: \.type) { album in
                        NavigationLink(destination: VideoGridView(albumType: album.type, albumName: album.name, videoManager: videoManager)) {
                            HStack {
                                Image(systemName: album.icon)
                                    .foregroundColor(album.type == .trash ? .gray : .accentColor)
                                Text(album.name)
                            }
                        }
                    }
                }
                
                Section(header: Text("マイアルバム")) {
                    ForEach(videoManager.albums, id: \.self) { album in
                        NavigationLink(destination: VideoGridView(albumType: .user(album), albumName: album, videoManager: videoManager)) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.yellow)
                                Text(album)
                            }
                        }
                    }
                    .onDelete(perform: prepareToDeleteAlbum)
                }
                
                if let server = serverManager.server, let address = server.address {
                    Section(header: Text(server.name)) {
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
                    }
                } else {
                    Section(header: Text("Mac サーバー")) {
                        Text("同じWi-Fi内でサーバーが見つかりません")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("アルバム")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isShowingCreateAlbumAlert = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
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
