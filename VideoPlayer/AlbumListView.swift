import SwiftUI

// ===================================
//  AlbumListView.swift (完全分割表示版)
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
    
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1)
    private let accentGlowColor = Color.cyan

    var body: some View {
        NavigationStack {
            List {
                localSections
                serverSections
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(primaryDarkColor.ignoresSafeArea())
            .navigationTitle("アルバム")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(primaryDarkColor, for: .navigationBar)
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
    
    // MARK: - View Builders
    
    @ViewBuilder
    private var localSections: some View {
        Section {
            ForEach(specialAlbums, id: \.type) { album in
                NavigationLink(destination: VideoGridView(albumType: album.type, albumName: album.name, videoManager: videoManager)) {
                    HStack {
                        Image(systemName: album.icon)
                            .foregroundColor(album.type == .trash ? .gray.opacity(0.7) : accentGlowColor)
                            .font(.title3)
                        Text(album.name)
                            .fontWeight(.medium)
                    }
                }
            }
        } header: {
            Text("ローカルライブラリ")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
        }
        
        Section {
            ForEach(videoManager.albums, id: \.self) { album in
                NavigationLink(destination: VideoGridView(albumType: .user(album), albumName: album, videoManager: videoManager)) {
                    HStack {
                        Image(systemName: "folder.fill")
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
    }
    
    @ViewBuilder
    private var serverSections: some View {
        if let server = serverManager.server, let address = server.address {
            if serverManager.isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } header: {
                    serverHeader(name: server.name)
                }
            } else if let errorMessage = serverManager.errorMessage {
                Section {
                    Text(errorMessage).foregroundColor(.secondary)
                } header: {
                    serverHeader(name: server.name)
                }
            } else {
                serverLoadedContent(serverName: server.name, address: address)
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
    
    @ViewBuilder
    private func serverLoadedContent(serverName: String, address: String) -> some View {
        // ★ 1. ライブラリ (ALL VIDEOS と ALL PHOTOS)
        let libraryAlbums = serverManager.albums.filter { $0.name == "ALL VIDEOS" || $0.name == "ALL PHOTOS" }
        
        if !libraryAlbums.isEmpty {
            Section {
                ForEach(libraryAlbums) { album in
                    let isPhoto = album.name == "ALL PHOTOS"
                    serverAlbumRow(
                        album: album,
                        address: address,
                        icon: isPhoto ? "photo.on.rectangle.fill" : "film.stack.fill",
                        color: isPhoto ? .orange : .yellow
                    )
                }
            } header: {
                serverHeader(name: "\(serverName) ライブラリ")
            }
        }
        
        // ★ 2. 動画アルバム (ユーザー作成)
        // 条件: タイプがvideo(またはnil) かつ システムアルバムでない
        let videoAlbums = serverManager.albums.filter {
            ($0.type == "video" || $0.type == nil) &&
            $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS"
        }
        
        if !videoAlbums.isEmpty {
            Section {
                ForEach(videoAlbums) { album in
                    serverAlbumRow(album: album, address: address, icon: "folder.fill", color: .cyan)
                }
            } header: {
                Text("動画アルバム")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
        }
        
        // ★ 3. 画像アルバム (ユーザー作成)
        // 条件: タイプがphoto かつ システムアルバムでない
        let photoAlbums = serverManager.albums.filter {
            $0.type == "photo" &&
            $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS"
        }
        
        if !photoAlbums.isEmpty {
            Section {
                ForEach(photoAlbums) { album in
                    serverAlbumRow(album: album, address: address, icon: "photo.on.rectangle.fill", color: .orange)
                }
            } header: {
                Text("画像アルバム")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
        }
        
        if libraryAlbums.isEmpty && videoAlbums.isEmpty && photoAlbums.isEmpty {
            Section {
                Text("アルバムがありません")
                    .foregroundColor(.secondary)
            } header: {
                serverHeader(name: serverName)
            }
        }
    }
    
    private func serverHeader(name: String) -> some View {
        Text(name)
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(accentGlowColor)
    }
    
    private func serverAlbumRow(album: RemoteAlbumInfo, address: String, icon: String, color: Color) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: address, albumID: album.id)) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                    .frame(width: 30)
                Text(album.name)
                Spacer()
                Text("\(album.videoCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
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
