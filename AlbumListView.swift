import SwiftUI

// ===================================
//  AlbumListView.swift (プレミアムUI & リスト・カバー表示切り替え対応版)
// ===================================

struct AlbumListView: View {
    @StateObject private var videoManager = VideoManager()
    @EnvironmentObject var serverBrowser: ServerBrowser
    
    @StateObject private var serverManager = ServerManager()
    @ObservedObject private var favorites = FavoritesManager.shared

    @State private var newAlbumName = ""
    @State private var isShowingCreateAlbumAlert = false
    @State private var albumToDelete: String?
    @State private var isShowingDeleteConfirmAlert = false

    @State private var isShowingCreateServerAlbumAlert = false
    @State private var newServerAlbumName = ""
    @State private var newServerAlbumType = "video"
    @State private var isUploadingAction = false

    // ★ サーバーPIN入力
    @State private var isShowingPINPrompt = false
    @State private var pinInput = ""

    // ★ サーバー停止
    @State private var showShutdownConfirm = false
    
    // ★ リストとグリッドの表示切り替えフラグ
    @AppStorage("isAlbumListViewMode") private var isListViewMode = false
    
    private let specialAlbums: [(type: AlbumType, name: String, icon: String)] = [
        (.all, "すべてのビデオ", "square.stack.fill"),
        (.trash, "ごみ箱", "trash.fill")
    ]
    
    // ★ プレミアムカラー定義: 深みのあるミッドナイトブルーとシャンパンゴールド
    private let primaryDarkColor = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accentGlowColor = Color(red: 0.85, green: 0.73, blue: 0.45)

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.10, green: 0.10, blue: 0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                
                ScrollView {
                    VStack(spacing: 32) {
                        localSection
                        serverSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("アルバム")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(primaryDarkColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // ★ 表示切り替えボタン
                        Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isListViewMode.toggle() } }) {
                            Image(systemName: isListViewMode ? "square.grid.2x2" : "list.bullet")
                                .foregroundColor(accentGlowColor)
                        }
                        
                        Menu {
                            Button("ローカルに作成") { isShowingCreateAlbumAlert = true }
                            if serverManager.server?.address != nil {
                                Button("サーバーに作成") { isShowingCreateServerAlbumAlert = true }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(accentGlowColor)
                        }
                    }
                }
            }
            .alert("ローカルアルバム", isPresented: $isShowingCreateAlbumAlert) {
                TextField("アルバム名", text: $newAlbumName)
                Button("作成", action: createAlbum)
                Button("キャンセル", role: .cancel) {}
            }
            .alert("サーバーアルバム", isPresented: $isShowingCreateServerAlbumAlert) {
                TextField("アルバム名", text: $newServerAlbumName)
                Button("動画アルバムとして作成") { createServerAlbum(type: "video") }
                Button("画像アルバムとして作成") { createServerAlbum(type: "photo") }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("アルバムを削除", isPresented: $isShowingDeleteConfirmAlert, presenting: albumToDelete) { album in
                Button("削除", role: .destructive) {
                    videoManager.deleteAlbum(name: album)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { album in
                Text("「\(album)」を削除しますか？\nこの操作は取り消せません。")
            }
            .alert("サーバーを停止しますか？", isPresented: $showShutdownConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("停止する", role: .destructive) {
                    if let address = serverManager.server?.address {
                        shutdownServer(serverAddress: address)
                    }
                }
            } message: {
                Text("Mac側のサーバーアプリを終了します。再起動するにはMacを直接操作する必要があります。")
            }
            .alert("サーバーPIN", isPresented: $isShowingPINPrompt) {
                TextField("PIN", text: $pinInput)
                    .keyboardType(.numberPad)
                Button("接続") {
                    serverManager.submitPIN(pinInput.trimmingCharacters(in: .whitespaces))
                    pinInput = ""
                }
                Button("キャンセル", role: .cancel) { pinInput = "" }
            } message: {
                Text("Macのサーバー画面に表示されているPINを入力してください。")
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
    
    // MARK: - Local Section
    @ViewBuilder
    private var localSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "ローカルライブラリ")
            
            if isListViewMode {
                LazyVStack(spacing: 12) {
                    ForEach(specialAlbums, id: \.type) { album in
                        localListRow(type: album.type, name: album.name, icon: album.icon)
                    }
                    ForEach(videoManager.albums, id: \.self) { albumName in
                        localListRow(type: .user(albumName), name: albumName, icon: "folder.fill")
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(specialAlbums, id: \.type) { album in
                        localGridCell(type: album.type, name: album.name, icon: album.icon)
                    }
                    ForEach(videoManager.albums, id: \.self) { albumName in
                        localGridCell(type: .user(albumName), name: albumName, icon: "folder.fill")
                    }
                }
            }
        }
    }
    
    // MARK: - Server Section
    @ViewBuilder
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let server = serverManager.server, let address = server.address {
                serverSectionHeader(title: server.name)

                if serverManager.authRequired {
                    serverLockCard
                } else if serverManager.isLoading {
                    ProgressView().tint(accentGlowColor).frame(maxWidth: .infinity, alignment: .center).padding()
                } else if let errorMessage = serverManager.errorMessage {
                    Text(errorMessage).foregroundColor(.gray).font(.subheadline).padding()
                } else {
                    let libraryAlbums = serverManager.albums.filter { $0.name == "ALL VIDEOS" || $0.name == "ALL PHOTOS" }
                    let videoAlbums = serverManager.albums.filter { ($0.type == "video" || $0.type == nil) && $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS" }
                    let photoAlbums = serverManager.albums.filter { $0.type == "photo" && $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS" }
                    
                    if isListViewMode {
                        LazyVStack(spacing: 12) {
                            virtualListRow(title: "お気に入り", icon: "heart.fill", albumID: "FAVORITES", address: address, count: favorites.ids.count, tint: .pink)
                            virtualListRow(title: "再生履歴", icon: "clock.arrow.circlepath", albumID: "HISTORY", address: address, count: nil, tint: accentGlowColor)
                            ForEach(libraryAlbums) { album in
                                let isPhoto = album.name == "ALL PHOTOS"
                                serverListRow(album: album, address: address, icon: isPhoto ? "photo.on.rectangle.fill" : "film.stack.fill")
                            }
                            ForEach(videoAlbums) { album in
                                serverListRow(album: album, address: address, icon: "folder.fill")
                            }
                            ForEach(photoAlbums) { album in
                                serverListRow(album: album, address: address, icon: "photo.on.rectangle.fill")
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            virtualGridCell(title: "お気に入り", icon: "heart.fill", albumID: "FAVORITES", address: address, count: favorites.ids.count, tint: .pink)
                            virtualGridCell(title: "再生履歴", icon: "clock.arrow.circlepath", albumID: "HISTORY", address: address, count: nil, tint: accentGlowColor)
                            ForEach(libraryAlbums) { album in
                                let isPhoto = album.name == "ALL PHOTOS"
                                serverGridCell(album: album, address: address, icon: isPhoto ? "photo.on.rectangle.fill" : "film.stack.fill")
                            }
                            ForEach(videoAlbums) { album in
                                serverGridCell(album: album, address: address, icon: "folder.fill")
                            }
                            ForEach(photoAlbums) { album in
                                serverGridCell(album: album, address: address, icon: "photo.on.rectangle.fill")
                            }
                        }
                    }
                }
            } else {
                sectionHeader(title: "Mac サーバー")
                HStack {
                    Image(systemName: "wifi.slash")
                    Text("同じWi-Fi内でサーバーが見つかりません")
                }
                .foregroundColor(.white.opacity(0.5))
                .font(.subheadline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
        }
    }
    
    // MARK: - サーバーロックカード (PIN認証要求時)
    private var serverLockCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(accentGlowColor)
            Text("このサーバーは保護されています")
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
            Text("接続するにはPINが必要です。")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
            Button(action: { isShowingPINPrompt = true }) {
                Text("PINを入力")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(primaryDarkColor)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(accentGlowColor)
                    .cornerRadius(14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(accentGlowColor.opacity(0.3), lineWidth: 1))
    }

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundColor(accentGlowColor)
            .tracking(1.0)
            .padding(.bottom, 4)
            .padding(.leading, 4)
    }

    // ★ サーバー名 + 停止ボタンを表示するヘッダー
    private func serverSectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundColor(accentGlowColor)
                .tracking(1.0)
            Spacer()
            Button(action: { showShutdownConfirm = true }) {
                Image(systemName: "power.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red.opacity(0.85))
            }
        }
        .padding(.bottom, 4)
        .padding(.horizontal, 4)
    }
    
    // MARK: - ローカル用コンポーネント
    private func localListRow(type: AlbumType, name: String, icon: String) -> some View {
        NavigationLink(destination: VideoGridView(albumType: type, albumName: name, videoManager: videoManager)) {
            HStack(spacing: 16) {
                LocalAlbumCoverView(albumType: type, videoManager: videoManager, icon: icon, color: type == .trash ? .gray : accentGlowColor)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                
                Text(name)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color.white.opacity(0.3))
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        .contextMenu {
            if case .user(let albumName) = type {
                Button(role: .destructive) {
                    self.albumToDelete = albumName
                    self.isShowingDeleteConfirmAlert = true
                } label: { Label("削除", systemImage: "trash") }
            }
        }
    }
    
    private func localGridCell(type: AlbumType, name: String, icon: String) -> some View {
        NavigationLink(destination: VideoGridView(albumType: type, albumName: name, videoManager: videoManager)) {
            VStack(alignment: .leading, spacing: 10) {
                LocalAlbumCoverView(albumType: type, videoManager: videoManager, icon: icon, color: type == .trash ? .gray : accentGlowColor)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                
                Text(name)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
        .contextMenu {
            if case .user(let albumName) = type {
                Button(role: .destructive) {
                    self.albumToDelete = albumName
                    self.isShowingDeleteConfirmAlert = true
                } label: { Label("削除", systemImage: "trash") }
            }
        }
    }
    
    // MARK: - サーバー用コンポーネント
    private func serverListRow(album: RemoteAlbumInfo, address: String, icon: String) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: address, albumID: album.id, allServerAlbums: serverManager.albums)) {
            HStack(spacing: 16) {
                ServerAlbumCoverView(serverAddress: address, albumID: album.id, icon: icon, color: accentGlowColor)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                    Text("\(album.videoCount) 項目")
                        .font(.caption.weight(.medium))
                        .foregroundColor(accentGlowColor.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color.white.opacity(0.3))
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        .contextMenu {
            if album.name != "ALL VIDEOS" && album.name != "ALL PHOTOS" {
                Button(role: .destructive) {
                    deleteServerAlbum(album: album, address: address)
                } label: { Label("削除", systemImage: "trash") }
            }
        }
    }
    
    private func serverGridCell(album: RemoteAlbumInfo, address: String, icon: String) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: address, albumID: album.id, allServerAlbums: serverManager.albums)) {
            VStack(alignment: .leading, spacing: 10) {
                ServerAlbumCoverView(serverAddress: address, albumID: album.id, icon: icon, color: accentGlowColor)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                
                HStack {
                    Text(album.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Text("\(album.videoCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(primaryDarkColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accentGlowColor)
                        .cornerRadius(6)
                }
                .padding(.horizontal, 4)
            }
        }
        .contextMenu {
            if album.name != "ALL VIDEOS" && album.name != "ALL PHOTOS" {
                Button(role: .destructive) {
                    deleteServerAlbum(album: album, address: address)
                } label: { Label("削除", systemImage: "trash") }
            }
        }
    }

    // MARK: - 仮想アルバム (お気に入り・再生履歴)
    private func virtualGridCell(title: String, icon: String, albumID: String, address: String, count: Int?, tint: Color) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: title, serverAddress: address, albumID: albumID, allServerAlbums: serverManager.albums)) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.35), Color(red: 0.1, green: 0.1, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(tint)
                }
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                HStack {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    if let count = count {
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(primaryDarkColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tint)
                            .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func virtualListRow(title: String, icon: String, albumID: String, address: String, count: Int?, tint: Color) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: title, serverAddress: address, albumID: albumID, allServerAlbums: serverManager.albums)) {
            HStack(spacing: 16) {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.35), Color(red: 0.1, green: 0.1, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundColor(tint)
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                    if let count = count {
                        Text("\(count) 項目")
                            .font(.caption.weight(.medium))
                            .foregroundColor(tint.opacity(0.9))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color.white.opacity(0.3))
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
    }

    // MARK: - Actions
    private func createAlbum() {
        if !newAlbumName.isEmpty {
            videoManager.createAlbum(name: newAlbumName)
            newAlbumName = ""
        }
    }
    private func createServerAlbum(type: String) {
        guard !newServerAlbumName.isEmpty, let address = serverManager.server?.address else { return }
        Task {
            isUploadingAction = true
            _ = try? await ServerAPI.createAlbum(serverAddress: address, name: newServerAlbumName, type: type)
            await serverManager.fetchAlbums(serverAddress: address)
            isUploadingAction = false
            newServerAlbumName = ""
        }
    }
    private func deleteServerAlbum(album: RemoteAlbumInfo, address: String) {
        Task {
            _ = try? await ServerAPI.deleteAlbum(serverAddress: address, albumID: album.id)
            await serverManager.fetchAlbums(serverAddress: address)
        }
    }

    // ★ サーバーを停止する (PIN認証対応)
    private func shutdownServer(serverAddress: String) {
        guard let url = URL(string: "\(serverAddress)/server/shutdown") else { return }
        let req = ServerAuth.request(url, address: serverAddress, method: "POST")
        Task {
            _ = try? await URLSession.shared.data(for: req)
            await MainActor.run {
                serverBrowser.startBrowsing()
            }
        }
    }
}

// MARK: - カバー表示用コンポーネント

struct LocalAlbumCoverView: View {
    let albumType: AlbumType
    let videoManager: VideoManager
    let icon: String
    let color: Color
    
    @State private var coverURL: URL?
    @State private var hasFetched = false
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.1, green: 0.1, blue: 0.14).ignoresSafeArea()
                
                if let url = coverURL {
                    LocalVideoThumbnailView(url: url)
                        .allowsHitTesting(false) // タップ判定を親に譲る
                } else {
                    Image(systemName: icon)
                        .font(.system(size: proxy.size.width * 0.4, weight: .light))
                        .foregroundColor(color.opacity(0.5))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            if !hasFetched {
                hasFetched = true
                Task {
                    let urls = await MainActor.run { videoManager.fetchVideos(for: albumType) }
                    coverURL = urls.first
                }
            }
        }
    }
}

struct ServerAlbumCoverView: View {
    let serverAddress: String
    let albumID: String
    let icon: String
    let color: Color
    
    @State private var coverVideoID: String?
    @State private var hasFetched = false
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.1, green: 0.1, blue: 0.14).ignoresSafeArea()
                
                if let vid = coverVideoID {
                    AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(vid)")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            fallbackIcon(size: proxy.size.width * 0.4)
                        default:
                            ProgressView().tint(color)
                        }
                    }
                } else {
                    fallbackIcon(size: proxy.size.width * 0.4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task {
            if !hasFetched {
                hasFetched = true
                await fetchCoverID()
            }
        }
    }
    
    private func fallbackIcon(size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .light))
            .foregroundColor(color.opacity(0.5))
    }
    
    private func fetchCoverID() async {
        guard let url = URL(string: "\(serverAddress)/albums/\(albumID)/videos") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let videos = try decoder.decode([RemoteVideoInfo].self, from: data)
            if let first = videos.first {
                await MainActor.run {
                    coverVideoID = first.id
                }
            }
        } catch {
            print("Failed to fetch cover for album: \(albumID)")
        }
    }
}
