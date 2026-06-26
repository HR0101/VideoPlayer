import SwiftUI
import MediaServerKit

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

    @State private var isShowingPINPrompt = false
    @State private var pinInput = ""

    @State private var showShutdownConfirm = false

    /// ローカルアルバムの動画本数キャッシュ（カバー取得時に更新）
    @State private var localCounts: [String: Int] = [:]

    @AppStorage("isListViewMode") private var isListViewMode = false

    private let specialAlbums: [(type: AlbumType, name: String, icon: String)] = [
        (.all, "すべてのビデオ", "square.stack.fill"),
        (.trash, "ごみ箱", "trash.fill")
    ]

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private func albumColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if horizontalSizeClass == .regular {
            if width > 1100 { count = 5 }
            else if width > 800 { count = 4 }
            else { count = 3 }
        } else {
            count = 2
        }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                GeometryReader { geo in
                    ScrollView {
                        VStack(spacing: 36) {
                            localSection(width: geo.size.width)
                            serverSection(width: geo.size.width)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 24)
                    }
                }
            }
            .navigationTitle("アルバム")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button(action: {
                            Haptics.light()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isListViewMode.toggle() }
                        }) {
                            Image(systemName: isListViewMode ? "square.grid.2x2" : "list.bullet")
                                .foregroundStyle(Color.appGold)
                                .contentTransition(.symbolEffect(.replace))
                        }

                        Menu {
                            Button("ローカルに作成") { isShowingCreateAlbumAlert = true }
                            if serverManager.server?.address != nil {
                                Button("サーバーに作成") { isShowingCreateServerAlbumAlert = true }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.appGold)
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
            .onChange(of: serverBrowser.discoveredServers) { _, servers in
                serverManager.updateServer(servers.first)
            }
        }
    }

    // MARK: - Local Section
    @ViewBuilder
    private func localSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "ローカルライブラリ", icon: "iphone")

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
                LazyVGrid(columns: albumColumns(for: width), spacing: 16) {
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
    private func serverSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let server = serverManager.server, let address = server.address {
                SectionHeaderView(
                    title: server.name,
                    icon: "macmini.fill",
                    accessory: AnyView(
                        HStack(spacing: 14) {
                            if !serverManager.authRequired { LiveIndicator() }
                            Button(action: { showShutdownConfirm = true }) {
                                Image(systemName: "power.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                        }
                    )
                )

                if serverManager.authRequired {
                    serverLockCard
                } else if serverManager.isLoading {
                    loadingSkeleton(width: width)
                } else if let errorMessage = serverManager.errorMessage {
                    statusCard(icon: "exclamationmark.triangle.fill", title: "接続エラー", message: errorMessage)
                } else {
                    let libraryAlbums = serverManager.albums.filter { $0.name == "ALL VIDEOS" || $0.name == "ALL PHOTOS" }
                    let videoAlbums = serverManager.albums.filter { ($0.type == "video" || $0.type == nil) && $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS" }
                    let photoAlbums = serverManager.albums.filter { $0.type == "photo" && $0.name != "ALL VIDEOS" && $0.name != "ALL PHOTOS" }

                    if isListViewMode {
                        LazyVStack(spacing: 12) {
                            virtualListRow(title: "お気に入り", icon: "heart.fill", albumID: "FAVORITES", address: address, count: favorites.ids.count, tint: .pink)
                            virtualListRow(title: "再生履歴", icon: "clock.arrow.circlepath", albumID: "HISTORY", address: address, count: nil, tint: .appGold)
                            virtualListRow(title: "ショート動画", icon: "flame.fill", albumID: "SHORTS", address: address, count: nil, tint: .cyan)
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
                        LazyVGrid(columns: albumColumns(for: width), spacing: 16) {
                            virtualGridCell(title: "お気に入り", icon: "heart.fill", albumID: "FAVORITES", address: address, count: favorites.ids.count, tint: .pink)
                            virtualGridCell(title: "再生履歴", icon: "clock.arrow.circlepath", albumID: "HISTORY", address: address, count: nil, tint: .appGold)
                            virtualGridCell(title: "ショート", icon: "flame.fill", albumID: "SHORTS", address: address, count: nil, tint: .cyan)
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
                SectionHeaderView(title: "Mac サーバー", icon: "macmini.fill")
                serverSearchingCard
            }
        }
    }

    // MARK: - サーバー探索中カード（レーダー風）
    private var serverSearchingCard: some View {
        VStack(spacing: 20) {
            RadarPulseView()
                .frame(height: 110)

            VStack(spacing: 6) {
                Text("サーバーを探しています…")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text("同じWi-Fi内で AllServerForMac を起動すると\n自動的にここへ表示されます")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .glassCard()
    }

    // MARK: - サーバーロックカード (PIN認証要求時)
    private var serverLockCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(AppTheme.goldGradient)
                .symbolEffect(.pulse)
                .shadow(color: Color.appGold.opacity(0.4), radius: 12)

            Text("このサーバーは保護されています")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Text("接続するにはPINが必要です。")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            Button(action: { Haptics.light(); isShowingPINPrompt = true }) {
                Text("PINを入力")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.appDarkBackground)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(AppTheme.goldGradient)
                    .clipShape(Capsule())
                    .shadow(color: Color.appGold.opacity(0.35), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(PressableCardStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard()
    }

    // MARK: - 状態表示カード
    private func statusCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.appTextSecondary)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard()
    }

    // MARK: - スケルトンローディング
    private func loadingSkeleton(width: CGFloat) -> some View {
        LazyVGrid(columns: albumColumns(for: width), spacing: 16) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonCard()
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    // MARK: - ローカル用コンポーネント
    private func localListRow(type: AlbumType, name: String, icon: String) -> some View {
        NavigationLink(destination: VideoGridView(albumType: type, albumName: name, videoManager: videoManager)) {
            HStack(spacing: 16) {
                LocalAlbumCoverView(albumType: type, videoManager: videoManager, icon: icon,
                                    color: type == .trash ? .gray : .appGold,
                                    onCount: { localCounts[type.id] = $0 })
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    if let count = localCounts[type.id] {
                        Text("\(count) 本")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(Color.appGold.opacity(0.85))
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(12)
            .glassCard(cornerRadius: AppTheme.radiusM)
        }
        .buttonStyle(PressableCardStyle(scale: 0.98))
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
            LocalAlbumCoverView(albumType: type, videoManager: videoManager, icon: icon,
                                color: type == .trash ? .gray : .appGold,
                                onCount: { localCounts[type.id] = $0 })
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .overlay(AppTheme.bottomScrim)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let count = localCounts[type.id] {
                            Text("\(count) 本")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.appGold)
                        }
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PressableCardStyle())
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
                ServerAlbumCoverView(serverAddress: address, albumID: album.id, icon: icon, color: .appGold)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("\(album.videoCount) 項目")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(Color.appGold.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(12)
            .glassCard(cornerRadius: AppTheme.radiusM)
        }
        .buttonStyle(PressableCardStyle(scale: 0.98))
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
            ServerAlbumCoverView(serverAddress: address, albumID: album.id, icon: icon, color: .appGold)
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .overlay(AppTheme.bottomScrim)
                .overlay(alignment: .bottomLeading) {
                    Text(album.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    CountBadge(count: album.videoCount)
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PressableCardStyle())
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
            ZStack {
                LinearGradient(colors: [tint.opacity(0.35), Color.appDarkSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.5), radius: 12)
            }
            .aspectRatio(1, contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(AppTheme.bottomScrim)
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if let count = count {
                    CountBadge(count: count, tint: LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PressableCardStyle())
    }

    private func virtualListRow(title: String, icon: String, albumID: String, address: String, count: Int?, tint: Color) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: title, serverAddress: address, albumID: albumID, allServerAlbums: serverManager.albums)) {
            HStack(spacing: 16) {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.35), Color.appDarkSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(tint)
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    if let count = count {
                        Text("\(count) 項目")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(tint.opacity(0.9))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(12)
            .glassCard(cornerRadius: AppTheme.radiusM)
        }
        .buttonStyle(PressableCardStyle(scale: 0.98))
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

// MARK: - レーダー風パルスアニメーション
struct RadarPulseView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.appGold.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 50, height: 50)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 2.2)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.7),
                        value: animate
                    )
            }

            Image(systemName: "wifi")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(AppTheme.goldGradient)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .frame(width: 56, height: 56)
                .background(Color.appDarkSurface.opacity(0.8))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.appGold.opacity(0.3), lineWidth: 1))
        }
        .onAppear { animate = true }
    }
}

// MARK: - カバー表示用コンポーネント

struct LocalAlbumCoverView: View {
    let albumType: AlbumType
    let videoManager: VideoManager
    let icon: String
    let color: Color
    var onCount: ((Int) -> Void)? = nil

    @State private var coverURL: URL?
    @State private var hasFetched = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.appDarkSurface.ignoresSafeArea()

                if let url = coverURL {
                    LocalVideoThumbnailView(url: url)
                        .allowsHitTesting(false) // タップ判定を親に譲る
                } else {
                    Image(systemName: icon)
                        .font(.system(size: proxy.size.width * 0.34, weight: .light))
                        .foregroundStyle(color.opacity(0.5))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            if !hasFetched {
                hasFetched = true
                Task {
                    let urls = await videoManager.fetchVideos(for: albumType)
                    coverURL = urls.first
                    onCount?(urls.count)
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
                Color.appDarkSurface.ignoresSafeArea()

                if let vid = coverVideoID {
                    AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(vid)")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        case .failure:
                            fallbackIcon(size: proxy.size.width * 0.34)
                        default:
                            SkeletonCard(cornerRadius: 0)
                        }
                    }
                } else {
                    fallbackIcon(size: proxy.size.width * 0.34)
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
            .foregroundStyle(color.opacity(0.5))
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
