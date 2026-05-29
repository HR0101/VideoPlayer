import SwiftUI
import AVKit
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif


// MARK: - メインビュー
struct RemoteVideoListView: View {
    let serverName: String
    let serverAddress: String
    let albumID: String
    let allServerAlbums: [RemoteAlbumInfo]
    
    @State private var videos: [RemoteVideoInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    
    @State private var videoToPlay: RemoteVideoInfo?
    @State private var playingVideoID: String?
    @State private var photoToView: RemoteVideoInfo?
    @State private var videoForInfoSheet: RemoteVideoInfo?
    
    @State private var gridColumnCount: Int = 3
    @State private var lastPlayedID: String?
    
    @AppStorage("isListViewMode") private var isListViewMode = false
    
    @State private var isSelectionMode = false
    @State private var selectedVideoIDs = Set<String>()
    @State private var showMoveTargetSheet = false
    
    @State private var showUploadSourceMenu = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var isUploading = false
    @State private var itemsPendingDeletion: [PickedMediaItem] = []
    @State private var showDeletePrompt = false
    
    @EnvironmentObject var downloadManager: DownloadManager
    @ObservedObject private var favorites = FavoritesManager.shared

    @State private var currentSortOrder: RemoteSortOrder = .importDescending

    private let primaryDarkColor = Color.appDarkBackground
    private let accentGlowColor  = Color.appGold

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.appDarkBackground, Color.appDarkSurface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: gridColumnCount) }

    private var emptyMessage: String {
        switch albumID {
        case "HISTORY": return "再生履歴はありません。"
        case "FAVORITES": return "お気に入りに追加したメディアが\nここに表示されます。"
        default: return "右上のアップロードボタンから\n動画や写真を追加してください。"
        }
    }

    private var sortedAndFilteredVideos: [RemoteVideoInfo] {
        let filtered = searchText.isEmpty ? videos : videos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        if albumID == "HISTORY" || albumID == "FAVORITES" {
            return filtered
        }

        switch currentSortOrder {
        case .importDescending:   return filtered.sorted { $0.importDate > $1.importDate }
        case .importAscending:    return filtered.sorted { $0.importDate < $1.importDate }
        case .creationDescending: return filtered.sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .creationAscending:  return filtered.sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .durationDescending: return filtered.sorted { $0.duration > $1.duration }
        case .durationAscending:  return filtered.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        ZStack {
            backgroundGradient
            
            Group {
                if isLoading {
                    ProgressView().tint(accentGlowColor).scaleEffect(1.2)
                }
                else if let errorMessage = errorMessage { placeholderView(icon: "exclamationmark.triangle.fill", title: "エラーが発生しました", message: errorMessage) }
                else if videos.isEmpty { placeholderView(icon: albumID == "FAVORITES" ? "heart.slash" : "server.rack", title: "メディアがありません", message: emptyMessage) }
                else {
                    if isListViewMode {
                        videoList
                    } else {
                        videoGrid
                    }
                }
            }
            
            if isUploading {
                ZStack {
                    Color.black.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 24) {
                        ProgressView().scaleEffect(1.5).tint(accentGlowColor)
                        Text("サーバーへアップロード中...")
                            .foregroundColor(.white)
                            .font(.headline.weight(.medium))
                            .tracking(1.0)
                    }
                    .padding(40)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                }
            }
            
            if isSelectionMode {
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button(action: deleteSelectedVideos) {
                            Text("\(selectedVideoIDs.count)件削除")
                                .font(.headline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(selectedVideoIDs.isEmpty ? Color.white.opacity(0.1) : Color.red.opacity(0.8))
                                .foregroundColor(selectedVideoIDs.isEmpty ? .gray : .white)
                                .cornerRadius(16)
                                .shadow(color: selectedVideoIDs.isEmpty ? .clear : Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                        }.disabled(selectedVideoIDs.isEmpty)
                        
                        if !isVirtualAlbum {
                            Button(action: { showMoveTargetSheet = true }) {
                                Text("移動")
                                    .font(.headline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(selectedVideoIDs.isEmpty ? Color.white.opacity(0.1) : accentGlowColor)
                                    .foregroundColor(selectedVideoIDs.isEmpty ? .gray : primaryDarkColor)
                                    .cornerRadius(16)
                                    .shadow(color: selectedVideoIDs.isEmpty ? .clear : accentGlowColor.opacity(0.3), radius: 8, x: 0, y: 4)
                            }.disabled(selectedVideoIDs.isEmpty)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.white.opacity(0.1)), alignment: .top)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "検索")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(isSelectionMode ? "\(selectedVideoIDs.count)件選択" : serverName)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelectionMode {
                    Button(selectedVideoIDs.count == videos.count ? "選択解除" : "すべて選択") {
                        if selectedVideoIDs.count == videos.count { selectedVideoIDs.removeAll() } else { selectedVideoIDs = Set(videos.map { $0.id }) }
                    }.foregroundColor(accentGlowColor)
                }
            }
            
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelectionMode {
                    Button("完了") { isSelectionMode = false; selectedVideoIDs.removeAll() }
                        .font(.body.weight(.bold))
                        .foregroundColor(accentGlowColor)
                } else {
                    if !isVirtualAlbum {
                        Button(action: { showUploadSourceMenu = true }) {
                            Image(systemName: "icloud.and.arrow.up").foregroundColor(accentGlowColor)
                        }
                        .confirmationDialog("メディアを追加", isPresented: $showUploadSourceMenu, titleVisibility: .visible) {
                            Button("写真アプリから選ぶ") { showPhotoPicker = true }
                            Button("ファイルアプリから選ぶ") { showDocumentPicker = true }
                            Button("キャンセル", role: .cancel) {}
                        }
                    }
                    
                    Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isListViewMode.toggle() } }) {
                        Image(systemName: isListViewMode ? "square.grid.2x2" : "list.bullet")
                            .foregroundColor(accentGlowColor)
                    }
                    
                    Button(action: { withAnimation { isSelectionMode = true } }) { Text("選択").foregroundColor(accentGlowColor) }.disabled(videos.isEmpty)
                    
                    if !isVirtualAlbum {
                        Menu {
                            Picker("並び替え", selection: $currentSortOrder) { ForEach(RemoteSortOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) } }
                        } label: { Image(systemName: "arrow.up.arrow.down.circle").foregroundColor(accentGlowColor) }
                    }
                }
            }
        }
        .sheet(isPresented: $showMoveTargetSheet) { moveTargetSheet }
        .sheet(isPresented: $showPhotoPicker) { ServerPhotoPicker { items in handlePickedMedia(items: items) } }
        .sheet(isPresented: $showDocumentPicker) { ServerDocumentPicker { items in handlePickedMedia(items: items) } }
        .alert("アップロード完了", isPresented: $showDeletePrompt) {
            Button("元のファイルを削除", role: .destructive) { deletePendingItems() }
            Button("残す", role: .cancel) { cleanUpTempFiles() }
        } message: {
            Text("アップロードしたメディアを元のアプリから削除しますか？\n（写真アプリの場合はOSの削除確認が表示されます）")
        }
        .fullScreenCover(item: $videoToPlay) { video in
            let onlyVideos = sortedAndFilteredVideos.filter { !$0.isPhoto }
            if let initialIndex = onlyVideos.firstIndex(where: { $0.id == video.id }) {
                DraggablePlayerView(
                    videos: onlyVideos,
                    initialIndex: initialIndex,
                    serverAddress: serverAddress,
                    videoToPlay: $videoToPlay,
                    playingVideoID: $playingVideoID
                )
                .onAppear { if let id = playingVideoID { lastPlayedID = id } }
                .onDisappear { lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
            } else {
                DraggablePlayerView(
                    videos: [video],
                    initialIndex: 0,
                    serverAddress: serverAddress,
                    videoToPlay: $videoToPlay,
                    playingVideoID: $playingVideoID
                )
                .onAppear { if let id = playingVideoID { lastPlayedID = id } }
                .onDisappear { lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
            }
        }
        .fullScreenCover(item: $photoToView) { photo in
            let onlyPhotos = sortedAndFilteredVideos.filter { $0.isPhoto }
            if let initialIndex = onlyPhotos.firstIndex(where: { $0.id == photo.id }) {
                RemotePhotoViewer(
                    photos: onlyPhotos,
                    initialIndex: initialIndex,
                    serverAddress: serverAddress,
                    isPresented: Binding(get: { photoToView != nil }, set: { if !$0 { photoToView = nil } }),
                    downloadManager: downloadManager
                )
            } else {
                RemotePhotoViewer(
                    photos: [photo],
                    initialIndex: 0,
                    serverAddress: serverAddress,
                    isPresented: Binding(get: { photoToView != nil }, set: { if !$0 { photoToView = nil } }),
                    downloadManager: downloadManager
                )
            }
        }
        .sheet(item: $videoForInfoSheet) { video in VideoInfoSheetView(video: video, serverAddress: serverAddress, downloadManager: downloadManager) }
        .task { 
            if videos.isEmpty { await fetchVideosFromServer() }
            lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID()
        }
        .onShake {
            playRandomVideo()
        }
    }
    
    // MARK: - ランダム再生機能
    private func playRandomVideo() {
        guard !isSelectionMode, !videos.isEmpty else { return }
        let onlyVideos = videos.filter { !$0.isPhoto }
        guard let randomVideo = onlyVideos.randomElement() else { return }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        playingVideoID = randomVideo.id
        PlaybackHistoryManager.shared.saveLastPlayed(id: randomVideo.id)
        videoToPlay = randomVideo
    }
    
    // MARK: - アイコン（グリッド）表示
    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(sortedAndFilteredVideos) { video in thumbnailCell(for: video) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .padding(.bottom, isSelectionMode ? 100 : 0)
        }
        .refreshable { await fetchVideosFromServer() }
    }
    
    // MARK: - リスト表示
    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sortedAndFilteredVideos) { video in
                    listRow(for: video)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, isSelectionMode ? 100 : 0)
        }
        .refreshable { await fetchVideosFromServer() }
    }
    
    // MARK: - グリッド用のセル
    @ViewBuilder
    private func thumbnailCell(for video: RemoteVideoInfo) -> some View {
        let isLastPlayed = video.id == lastPlayedID
        ZStack(alignment: .topTrailing) {
            RemoteVideoThumbnailView(thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)"), duration: video.duration)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(isLastPlayed ? accentGlowColor : Color.white.opacity(0.15), lineWidth: isLastPlayed ? 2.5 : 0.5))
                .opacity(isSelectionMode && selectedVideoIDs.contains(video.id) ? 0.6 : 1.0)
            
            if isSelectionMode {
                let isSelected = selectedVideoIDs.contains(video.id)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.bold)).foregroundColor(isSelected ? accentGlowColor : .white)
                    .padding(8)
                    .background(Group { if !isSelected { Color.black.opacity(0.4).clipShape(Circle()) } })
            }
        }
        .overlay(alignment: .topLeading) {
            if favorites.isFavorite(video.id) {
                Image(systemName: "heart.fill")
                    .font(.caption).foregroundColor(.pink)
                    .padding(6).background(.ultraThinMaterial).clipShape(Circle()).padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleVideoTap(video) }
        .contextMenu { videoContextMenu(video) }
    }
    
    // MARK: - リスト用の行
    @ViewBuilder
    private func listRow(for video: RemoteVideoInfo) -> some View {
        let isLastPlayed = video.id == lastPlayedID
        HStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                RemoteVideoThumbnailView(thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)"), duration: video.duration)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(isLastPlayed ? accentGlowColor : Color.white.opacity(0.15), lineWidth: isLastPlayed ? 2 : 0.5))
                
                if isSelectionMode {
                    let isSelected = selectedVideoIDs.contains(video.id)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.bold)).foregroundColor(isSelected ? accentGlowColor : .white)
                        .padding(4).background(Group { if !isSelected { Color.black.opacity(0.4).clipShape(Circle()) } })
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(video.filename)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                Text(video.importDate, style: .date)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    
                if !video.isPhoto {
                    HStack(spacing: 4) {
                        Image(systemName: "film.fill").font(.system(size: 10))
                        Text("Video").font(.caption2.weight(.medium))
                    }
                    .foregroundColor(accentGlowColor.opacity(0.9))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.fill").font(.system(size: 10))
                        Text("Photo").font(.caption2.weight(.medium))
                    }
                    .foregroundColor(Color.orange.opacity(0.9))
                }
            }
            Spacer()

            if favorites.isFavorite(video.id) {
                Image(systemName: "heart.fill")
                    .font(.subheadline)
                    .foregroundColor(.pink)
            }

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.2))
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .opacity(isSelectionMode && selectedVideoIDs.contains(video.id) ? 0.7 : 1.0)
        .onTapGesture { handleVideoTap(video) }
        .contextMenu { videoContextMenu(video) }
    }
    
    // MARK: - 共通のアクション（タップ・メニュー）
    private func handleVideoTap(_ video: RemoteVideoInfo) {
        if isSelectionMode {
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id) }
        } else {
            if video.isPhoto { 
                photoToView = video
            } else {
                playingVideoID = video.id
                PlaybackHistoryManager.shared.saveLastPlayed(id: video.id)
                videoToPlay = video
            }
        }
    }
    
    @ViewBuilder
    private func videoContextMenu(_ video: RemoteVideoInfo) -> some View {
        Button { videoForInfoSheet = video } label: { Label("詳細情報", systemImage: "info.circle") }
        Button {
            favorites.toggle(video.id)
            if albumID == "FAVORITES" { Task { await fetchVideosFromServer() } }
        } label: {
            let fav = favorites.isFavorite(video.id)
            Label(fav ? "お気に入りから削除" : "お気に入りに追加", systemImage: fav ? "heart.slash" : "heart")
        }
        Button { if let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)") { downloadManager.startDownload(url: url, filename: video.filename, isPhoto: video.duration == 0) } } label: { Label("保存", systemImage: "square.and.arrow.down") }

        if albumID == "FAVORITES" {
            Button(role: .destructive) {
                favorites.remove(video.id)
                Task { await fetchVideosFromServer() }
            } label: { Label("お気に入りから削除", systemImage: "heart.slash") }
        } else if serverName != "ALL VIDEOS" && serverName != "ALL PHOTOS" {
            if albumID == "HISTORY" {
                Button(role: .destructive) {
                    PlaybackHistoryManager.shared.removeHistory(id: video.id)
                    Task { await fetchVideosFromServer() }
                } label: { Label("履歴から削除", systemImage: "minus.circle") }
            } else {
                Button(role: .destructive) { deleteSingleVideo(id: video.id) } label: { Label("アルバムから外す", systemImage: "minus.circle") }
            }
        }
    }

    private var moveTargetSheet: some View {
        NavigationView {
            List(allServerAlbums.filter { $0.id != albumID }) { album in
                Button(action: { showMoveTargetSheet = false; executeMove(to: album.id) }) {
                    HStack { Image(systemName: album.type == "photo" ? "photo.on.rectangle.fill" : "folder.fill").foregroundColor(accentGlowColor); Text(album.name).foregroundColor(.white) }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color.appDarkBackground.ignoresSafeArea())
            .navigationTitle("移動先を選択").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showMoveTargetSheet = false }.foregroundColor(accentGlowColor) } }
        }
    }
    
    // MARK: - API Calls
    private var isVirtualAlbum: Bool { albumID == "HISTORY" || albumID == "FAVORITES" }

    private func fetchAllMedia() async throws -> [RemoteVideoInfo] {
        let libraryAlbums = allServerAlbums.filter { $0.name == "ALL VIDEOS" || $0.name == "ALL PHOTOS" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var all: [RemoteVideoInfo] = []
        for album in libraryAlbums {
            guard let url = URL(string: "\(serverAddress)/albums/\(album.id)/videos") else { continue }
            let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
            all.append(contentsOf: try decoder.decode([RemoteVideoInfo].self, from: data))
        }
        return all
    }

    private func fetchVideosFromServer() async {
        isLoading = true
        defer { isLoading = false }

        if albumID == "HISTORY" {
            do {
                let allVideos = try await fetchAllMedia()
                let historyIDs = PlaybackHistoryManager.shared.getHistoryIDs()
                var historyVideos: [RemoteVideoInfo] = []
                for id in historyIDs {
                    if let video = allVideos.first(where: { $0.id == id }) {
                        historyVideos.append(video)
                    }
                }
                self.videos = historyVideos
            } catch {
                errorMessage = "履歴取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "FAVORITES" {
            do {
                let allMedia = try await fetchAllMedia()
                let favIDs = FavoritesManager.shared.ids
                self.videos = allMedia.filter { favIDs.contains($0.id) }
            } catch {
                errorMessage = "お気に入り取得失敗: \(error.localizedDescription)"
            }
        } else {
            guard let url = URL(string: "\(serverAddress)/albums/\(albumID)/videos") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.videos = try decoder.decode([RemoteVideoInfo].self, from: data)
            } catch {
                errorMessage = "取得失敗: \(error.localizedDescription)"
            }
        }
    }
    
    private func executeMove(to targetID: String) { let ids = Array(selectedVideoIDs); Task { _ = try? await ServerAPI.moveVideos(serverAddress: serverAddress, videoIDs: ids, sourceAlbumID: albumID, targetAlbumID: targetID); isSelectionMode = false; selectedVideoIDs.removeAll(); await fetchVideosFromServer() } }
    
    private func deleteSelectedVideos() {
        let ids = Array(selectedVideoIDs)
        if albumID == "HISTORY" {
            for id in ids { PlaybackHistoryManager.shared.removeHistory(id: id) }
            isSelectionMode = false
            selectedVideoIDs.removeAll()
            Task { await fetchVideosFromServer() }
        } else if albumID == "FAVORITES" {
            for id in ids { favorites.remove(id) }
            isSelectionMode = false
            selectedVideoIDs.removeAll()
            Task { await fetchVideosFromServer() }
        } else {
            Task { _ = try? await ServerAPI.deleteVideos(serverAddress: serverAddress, videoIDs: ids, albumID: albumID); isSelectionMode = false; selectedVideoIDs.removeAll(); await fetchVideosFromServer() }
        }
    }
    
    private func deleteSingleVideo(id: String) { Task { _ = try? await ServerAPI.deleteVideos(serverAddress: serverAddress, videoIDs: [id], albumID: albumID); await fetchVideosFromServer() } }
    
    private func handlePickedMedia(items: [PickedMediaItem]) {
        isUploading = true
        Task {
            for item in items {
                _ = try? await ServerAPI.uploadMedia(serverAddress: serverAddress, fileURL: item.tempURL, albumID: albumID)
            }
            isUploading = false
            await fetchVideosFromServer()
            
            itemsPendingDeletion = items
            showDeletePrompt = true
        }
    }
    
    private func deletePendingItems() {
        Task {
            for item in itemsPendingDeletion {
                do {
                    try await item.deleteAction()
                } catch {
                    print("元のファイルの削除に失敗しました: \(error)")
                }
            }
            cleanUpTempFiles()
        }
    }
    
    private func cleanUpTempFiles() {
        for item in itemsPendingDeletion {
            try? FileManager.default.removeItem(at: item.tempURL)
            try? FileManager.default.removeItem(at: item.tempURL.deletingLastPathComponent())
        }
        itemsPendingDeletion.removeAll()
    }
    
    private func placeholderView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(accentGlowColor.opacity(0.8))
                .shadow(color: accentGlowColor.opacity(0.3), radius: 10, x: 0, y: 0)
            
            Text(title).font(.title2.weight(.bold)).foregroundColor(.white).tracking(1.0)
            Text(message).font(.subheadline).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center).padding(.horizontal, 40).lineSpacing(6)
        }
        .padding()
    }
}

// MARK: - ピッカー・ビュー部品群

struct PickedMediaItem {
    let tempURL: URL
    let originalFilename: String
    let deleteAction: () async throws -> Void
}

struct ServerPhotoPicker: UIViewControllerRepresentable {
    let onMediaPicked: ([PickedMediaItem]) -> Void
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.videos, .images])
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ServerPhotoPicker
        init(_ parent: ServerPhotoPicker) { self.parent = parent }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            
            let group = DispatchGroup()
            var pickedItems: [PickedMediaItem] = []
            let queue = DispatchQueue(label: "pickedItems.queue")
            
            for result in results {
                group.enter()
                let provider = result.itemProvider
                let assetIdentifier = result.assetIdentifier
                
                let handleURL: (URL?) -> Void = { sourceURL in
                    defer { group.leave() }
                    guard let sourceURL = sourceURL else { return }
                    
                    let tempDir = FileManager.default.temporaryDirectory
                    let uniqueDir = tempDir.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)
                        let finalURL = uniqueDir.appendingPathComponent(sourceURL.lastPathComponent)
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                        
                        let deleteAction: () async throws -> Void = {
                            if let id = assetIdentifier {
                                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                                if let asset = assets.firstObject {
                                    try await PHPhotoLibrary.shared().performChanges {
                                        PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                                    }
                                }
                            }
                        }
                        
                        let item = PickedMediaItem(tempURL: finalURL, originalFilename: sourceURL.lastPathComponent, deleteAction: deleteAction)
                        queue.sync { pickedItems.append(item) }
                    } catch {
                        print("Copy error: \(error)")
                    }
                }
                
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in handleURL(url) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in handleURL(url) }
                } else {
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                if !pickedItems.isEmpty {
                    self.parent.onMediaPicked(pickedItems)
                }
            }
        }
    }
}

struct ServerDocumentPicker: UIViewControllerRepresentable {
    let onMediaPicked: ([PickedMediaItem]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .image], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ServerDocumentPicker
        init(_ parent: ServerDocumentPicker) { self.parent = parent }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var pickedItems: [PickedMediaItem] = []
            
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                let tempDir = FileManager.default.temporaryDirectory
                let uniqueDir = tempDir.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)
                    let finalURL = uniqueDir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: finalURL)
                    
                    // セキュリティスコープを維持したまま後で削除できるようにブックマークを作成
                    let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    
                    let deleteAction: () async throws -> Void = {
                        var isStale = false
                        let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                        let access = resolvedURL.startAccessingSecurityScopedResource()
                        defer { if access { resolvedURL.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.removeItem(at: resolvedURL)
                    }
                    
                    let item = PickedMediaItem(tempURL: finalURL, originalFilename: url.lastPathComponent, deleteAction: deleteAction)
                    pickedItems.append(item)
                } catch {
                    print("Document picker copy error: \(error)")
                }
                
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            if !pickedItems.isEmpty {
                parent.onMediaPicked(pickedItems)
            }
        }
    }
}

private struct RemoteVideoThumbnailView: View {
    let thumbnailURL: URL?
    let duration: TimeInterval
    private let primaryDarkColor = Color.appDarkBackground
    
    var body: some View {
        ZStack {
            Rectangle().fill(primaryDarkColor)
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                case .failure: Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.2))
                default: ProgressView().tint(Color.appGold)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit).cornerRadius(16).clipped().shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 4)
        .overlay(alignment: .bottom) { if duration > 0 { LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.7)]), startPoint: .top, endPoint: .bottom).frame(height: 40) } }
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 { Text(formatDuration(duration)).font(.caption2.weight(.bold)).foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 4).background(.ultraThinMaterial.opacity(0.9)).cornerRadius(6).padding(8) }
        }
    }
    private func formatDuration(_ totalSeconds: TimeInterval) -> String { let secondsInt = Int(totalSeconds); return String(format: "%d:%02d", secondsInt / 60, secondsInt % 60) }
}

private enum RepeatMode { case off, all, one }

private struct DraggablePlayerView: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String

    @Binding var videoToPlay: RemoteVideoInfo?
    @Binding var playingVideoID: String?

    @State private var currentIndex: Int
    @StateObject private var playerManager: PlayerManager
    @ObservedObject private var favorites = FavoritesManager.shared
    @State private var dragOffset: CGSize = .zero
    @State private var selectedQuality: String = "original"

    @State private var isPreparingQuality: Bool = false
    @State private var prepareProgress: Double = 0
    @State private var prepareTask: Task<Void, Never>? = nil

    @State private var showControls: Bool = true
    @State private var hideControlsTask: Task<Void, Never>? = nil

    @State private var isContinuous: Bool = true
    @State private var isShuffle: Bool = false
    @State private var repeatMode: RepeatMode = .off
    @State private var isSlideshow: Bool = false
    @AppStorage("slideshowClipDuration") private var slideshowClipDuration: Double = 10
    @State private var slideshowTask: Task<Void, Never>? = nil

    private let accentGlowColor = Color.appGold

    init(videos: [RemoteVideoInfo], initialIndex: Int, serverAddress: String, videoToPlay: Binding<RemoteVideoInfo?>, playingVideoID: Binding<String?>) {
        self.videos = videos
        self._currentIndex = State(initialValue: initialIndex)
        self.serverAddress = serverAddress
        self._videoToPlay = videoToPlay
        self._playingVideoID = playingVideoID
        
        let initialVideo = videos[initialIndex]
        let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(initialVideo.id)") ?? URL(string: "\(serverAddress)/video/\(initialVideo.id)")!
        self._playerManager = StateObject(wrappedValue: PlayerManager(videoURL: url))
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 500))
            
            HStack {
                if currentIndex > 0 {
                    Image(systemName: "backward.end.alt.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(dragOffset.width > 50 ? min(1.0, Double(dragOffset.width - 50) / 100.0) : 0))
                        .padding(.leading, 40)
                }
                Spacer()
                if currentIndex < videos.count - 1 {
                    Image(systemName: "forward.end.alt.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(dragOffset.width < -50 ? min(1.0, Double(-dragOffset.width - 50) / 100.0) : 0))
                        .padding(.trailing, 40)
                }
            }
            
            VStack {
                VideoPlayer(player: playerManager.player)
                    .scaleEffect(max(0.8, 1 - (max(abs(dragOffset.width), max(0, dragOffset.height)) / 800)))
            }
            .offset(x: dragOffset.width, y: dragOffset.height > 0 ? dragOffset.height : 0)
            .opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 300))
            
            if showControls {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(videos[currentIndex].filename)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(radius: 2)
                        Spacer(minLength: 8)
                        Menu {
                            Button(action: { changeQuality("original") }) { if selectedQuality == "original" { Label("オリジナル", systemImage: "checkmark") } else { Text("オリジナル") } }
                            Button(action: { changeQuality("1080p") }) { if selectedQuality == "1080p" { Label("1080p (軽量・変換)", systemImage: "checkmark") } else { Text("1080p (軽量・変換)") } }
                        } label: {
                            HStack(spacing: 6) { Image(systemName: "line.3.horizontal.decrease.circle"); Text(qualityLabel(selectedQuality)).font(.subheadline.bold()) }
                            .padding(.horizontal, 12).padding(.vertical, 8).background(.ultraThinMaterial).overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5)).clipShape(Capsule()).shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2).foregroundColor(.white)
                        }
                        Button(action: toggleFavorite) {
                            Image(systemName: favorites.isFavorite(videos[currentIndex].id) ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundColor(favorites.isFavorite(videos[currentIndex].id) ? .pink : .white)
                                .shadow(radius: 2)
                        }
                    }

                    HStack(spacing: 22) {
                        controlToggle(icon: "shuffle", active: isShuffle) { isShuffle.toggle(); startHideTimer() }
                        controlToggle(icon: repeatMode == .one ? "repeat.1" : "repeat", active: repeatMode != .off) { cycleRepeatMode(); startHideTimer() }
                        controlToggle(icon: "infinity", active: isContinuous) { isContinuous.toggle(); startHideTimer() }
                        Menu {
                            Button(isSlideshow ? "スライドショーを停止" : "スライドショーを開始") { toggleSlideshow(); startHideTimer() }
                            Picker("1本あたりの秒数", selection: $slideshowClipDuration) {
                                Text("5秒").tag(5.0)
                                Text("10秒").tag(10.0)
                                Text("15秒").tag(15.0)
                                Text("30秒").tag(30.0)
                                Text("60秒").tag(60.0)
                            }
                        } label: {
                            Image(systemName: "play.square.stack")
                                .foregroundColor(isSlideshow ? accentGlowColor : .white.opacity(0.6))
                                .padding(8)
                                .background(isSlideshow ? accentGlowColor.opacity(0.18) : Color.clear)
                                .clipShape(Circle())
                        }
                    }
                    .font(.subheadline)

                    Spacer()
                }
                .padding(.top, 60)
                .padding(.horizontal, 20)
                .opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 100))
                .transition(.opacity)
            }

            if isPreparingQuality {
                ZStack {
                    Color.black.opacity(0.55).edgesIgnoringSafeArea(.all)
                    VStack(spacing: 14) {
                        ProgressView().scaleEffect(1.3).tint(.white)
                        Text("1080pに変換中…").foregroundColor(.white).font(.headline)
                        Text("\(Int(prepareProgress * 100))%")
                            .foregroundColor(.white.opacity(0.85))
                            .font(.subheadline.monospacedDigit())
                        Button("キャンセル") {
                            prepareTask?.cancel()
                            isPreparingQuality = false
                            selectedQuality = "original"
                        }
                        .foregroundColor(accentGlowColor)
                        .padding(.top, 4)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial)
                    .cornerRadius(18)
                }
                .transition(.opacity)
            }

            Group {
                Button("") { togglePlayPause() }.keyboardShortcut(.space, modifiers: [])
                Button("") { togglePlayPause() }.keyboardShortcut("k", modifiers: [])
                Button("") { seek(forward: true) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { seek(forward: true) }.keyboardShortcut("l", modifiers: [])
                Button("") { seek(forward: false) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { seek(forward: false) }.keyboardShortcut("j", modifiers: [])
                Button("") { adjustVolume(up: true) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { adjustVolume(up: false) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { toggleMute() }.keyboardShortcut("m", modifiers: [])
                Button("") { toggleFullScreen() }.keyboardShortcut("f", modifiers: [])
                Button("") { changeVideo(offset: -1) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { changeVideo(offset: 1) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("") { videoToPlay = nil }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .edgesIgnoringSafeArea(.all)
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    withAnimation { showControls.toggle() }
                    if showControls { startHideTimer() } else { hideControlsTask?.cancel() }
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    let w = dragOffset.width
                    let h = dragOffset.height

                    if h > 100 && abs(h) > abs(w) {
                        playerManager.shutdown()
                        videoToPlay = nil
                    }
                    else if abs(w) > 100 && abs(w) > abs(h) {
                        if w < 0 {
                            changeVideo(offset: 1)
                        } else {
                            changeVideo(offset: -1)
                        }
                        withAnimation(.spring()) { dragOffset = .zero }
                    } else {
                        withAnimation(.spring()) { dragOffset = .zero }
                    }
                }
        )
        .onAppear {
            startHideTimer()
            playerManager.onEnded = { handlePlaybackEnded() }
        }
        .onReceive(playerManager.$isReadyToPlay) { ready in
            if ready && isSlideshow { scheduleSlideshowAdvance() }
        }
        .onDisappear {
            slideshowTask?.cancel()
            prepareTask?.cancel()
            cleanupProxies()
            playerManager.shutdown()
        }
        .persistentSystemOverlays(.hidden)
    }

    private func controlToggle(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(active ? accentGlowColor : .white.opacity(0.6))
                .padding(8)
                .background(active ? accentGlowColor.opacity(0.18) : Color.clear)
                .clipShape(Circle())
        }
    }

    private func togglePlayPause() {
        if playerManager.isPlaying {
            playerManager.player.pause()
        } else {
            playerManager.player.play()
        }
        showControls = true
        startHideTimer()
    }
    
    private func seek(forward: Bool) {
        let currentTime = playerManager.player.currentTime()
        let delta = CMTime(seconds: forward ? 10 : -10, preferredTimescale: 600)
        let newTime = CMTimeAdd(currentTime, delta)
        playerManager.player.seek(to: newTime)
        showControls = true
        startHideTimer()
    }
    
    private func adjustVolume(up: Bool) {
        let currentVolume = playerManager.player.volume
        let newVolume = max(0.0, min(1.0, Double(currentVolume) + (up ? 0.1 : -0.1)))
        playerManager.player.volume = Float(newVolume)
        showControls = true
        startHideTimer()
    }
    
    private func toggleMute() {
        playerManager.player.isMuted.toggle()
        showControls = true
        startHideTimer()
    }
    
    private func toggleFullScreen() {
        #if canImport(AppKit)
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.toggleFullScreen(nil)
        }
        #endif
    }
    
    private func qualityLabel(_ q: String) -> String { switch q { case "1080p": return "1080p"; case "540p": return "540p"; default: return "Original" } }
    
    private func changeQuality(_ q: String) {
        selectedQuality = q
        let currentVideo = videos[currentIndex]

        if q == "original" {
            prepareTask?.cancel()
            isPreparingQuality = false
            if let newURL = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(currentVideo.id)") {
                playerManager.changeQuality(to: newURL)
            }
            startHideTimer()
            return
        }

        prepareTask?.cancel()
        prepareProgress = 0
        withAnimation { isPreparingQuality = true }
        prepareTask = Task { await prepareAndSwitch(video: currentVideo, quality: q) }
    }

    @MainActor
    private func prepareAndSwitch(video: RemoteVideoInfo, quality: String) async {
        guard let prepareURL = ServerAuth.mediaURL(
            address: serverAddress,
            path: "/video/\(video.id)/prepare",
            query: [URLQueryItem(name: "q", value: quality)]
        ) else {
            withAnimation { isPreparingQuality = false }
            return
        }
        let req = ServerAuth.request(prepareURL, address: serverAddress)
        struct PrepareResp: Codable { let state: String; let progress: Double }

        for _ in 0..<600 {
            if Task.isCancelled { return }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let resp = try? JSONDecoder().decode(PrepareResp.self, from: data) {
                    prepareProgress = resp.progress
                    if resp.state == "ready" {
                        // 待っている間に別画質/別動画へ切り替わっていない場合のみ反映
                        if selectedQuality == quality, video.id == videos[currentIndex].id,
                           let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)", query: [URLQueryItem(name: "q", value: quality)]) {
                            playerManager.changeQuality(to: url)
                        }
                        withAnimation { isPreparingQuality = false }
                        startHideTimer()
                        return
                    }
                }
            } catch {
                withAnimation { isPreparingQuality = false }
                selectedQuality = "original"
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        withAnimation { isPreparingQuality = false }
        selectedQuality = "original"
    }

    private func cleanupProxies() {
        let video = videos[currentIndex]
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)/proxy") else { return }
        let req = ServerAuth.request(url, address: serverAddress, method: "DELETE")
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
    
    private func changeVideo(offset: Int) {
        advance(forward: offset > 0, auto: false)
    }

    private func advance(forward: Bool, auto: Bool) {
        slideshowTask?.cancel()
        if auto && repeatMode == .one {
            playerManager.restart()
            return
        }
        guard let newIndex = targetIndex(forward: forward, auto: auto) else {
            playerManager.player.pause()
            return
        }
        goTo(index: newIndex)
    }

    private func targetIndex(forward: Bool, auto: Bool) -> Int? {
        guard videos.count > 1 else {
            return (auto && repeatMode == .all) ? currentIndex : nil
        }
        if isShuffle {
            return videos.indices.filter { $0 != currentIndex }.randomElement()
        }
        if forward {
            let n = currentIndex + 1
            if n < videos.count { return n }
            return repeatMode == .all ? 0 : nil
        } else {
            let p = currentIndex - 1
            if p >= 0 { return p }
            return repeatMode == .all ? videos.count - 1 : nil
        }
    }

    private func goTo(index newIndex: Int) {
        guard newIndex >= 0 && newIndex < videos.count else { return }

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // 自動送り時に変換待ちが発生しないよう、動画切り替えで画質をオリジナルへ戻す
        prepareTask?.cancel()
        isPreparingQuality = false
        selectedQuality = "original"

        currentIndex = newIndex
        let newVideo = videos[newIndex]
        playingVideoID = newVideo.id
        PlaybackHistoryManager.shared.saveLastPlayed(id: newVideo.id)

        if let newURL = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(newVideo.id)", query: [URLQueryItem(name: "q", value: selectedQuality)]) {
            let startAt = isSlideshow ? randomStart(for: newVideo) : 0
            playerManager.changeVideo(to: newURL, startAt: startAt)
        }

        showControls = true
        startHideTimer()
    }

    private func randomStart(for video: RemoteVideoInfo) -> Double {
        let maxStart = video.duration - slideshowClipDuration
        guard maxStart > 1 else { return 0 }
        return Double.random(in: 0...maxStart)
    }

    private func scheduleSlideshowAdvance() {
        slideshowTask?.cancel()
        let dur = slideshowClipDuration
        slideshowTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isSlideshow else { return }
                advance(forward: true, auto: true)
            }
        }
    }

    private func handlePlaybackEnded() {
        if repeatMode == .one {
            playerManager.restart()
            return
        }
        if isSlideshow || isContinuous || isShuffle {
            advance(forward: true, auto: true)
        }
    }

    private func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func toggleSlideshow() {
        isSlideshow.toggle()
        if isSlideshow {
            playerManager.seek(toSeconds: randomStart(for: videos[currentIndex]))
            playerManager.player.play()
            scheduleSlideshowAdvance()
        } else {
            slideshowTask?.cancel()
        }
    }

    private func toggleFavorite() {
        favorites.toggle(videos[currentIndex].id)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        showControls = true
        startHideTimer()
    }
    
    private func startHideTimer() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { showControls = false }
            }
        }
    }
}

private struct RemotePhotoViewer: View { 
    let photos: [RemoteVideoInfo]
    @State private var currentIndex: Int
    let serverAddress: String
    @Binding var isPresented: Bool
    var downloadManager: DownloadManager?
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    init(photos: [RemoteVideoInfo], initialIndex: Int, serverAddress: String, isPresented: Binding<Bool>, downloadManager: DownloadManager?) {
        self.photos = photos
        self._currentIndex = State(initialValue: initialIndex)
        self.serverAddress = serverAddress
        self._isPresented = isPresented
        self.downloadManager = downloadManager
    }
    
    var body: some View { 
        let currentPhoto = photos[currentIndex]
        let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(currentPhoto.id)") ?? URL(string: "\(serverAddress)/video/\(currentPhoto.id)")!
        
        ZStack { 
            Color.black.edgesIgnoringSafeArea(.all)
            
            AsyncImage(url: url) { phase in 
                switch phase { 
                case .empty: ProgressView().tint(.white) 
                case .success(let image): 
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(MagnificationGesture()
                            .onChanged { val in let delta = val / lastScale; lastScale = val; scale *= delta }
                            .onEnded { _ in lastScale = 1.0; if scale < 1.0 { withAnimation { scale = 1.0 } } }
                        )
                        .simultaneousGesture(DragGesture()
                            .onChanged { val in 
                                if scale > 1 { 
                                    offset = CGSize(width: lastOffset.width + val.translation.width, height: lastOffset.height + val.translation.height) 
                                } else { 
                                    offset = val.translation 
                                } 
                            }
                            .onEnded { val in 
                                if scale > 1 { 
                                    lastOffset = offset 
                                } else { 
                                    if abs(val.translation.height) > 100 && abs(val.translation.height) > abs(val.translation.width) { 
                                        isPresented = false 
                                    } else if abs(val.translation.width) > 100 {
                                        if val.translation.width < 0 { changePhoto(offset: 1) } else { changePhoto(offset: -1) }
                                        withAnimation { offset = .zero }
                                    } else { 
                                        withAnimation { offset = .zero } 
                                    } 
                                } 
                            }
                        )
                        .contextMenu { 
                            Button { downloadManager?.startDownload(url: url, filename: currentPhoto.filename, isPhoto: true) } label: { Label("写真アプリに保存", systemImage: "square.and.arrow.down") } 
                        } 
                case .failure: Text("画像の読み込みに失敗しました").foregroundColor(.white)
                @unknown default: EmptyView() 
                } 
            }
            
            HStack {
                if currentIndex > 0 {
                    Button(action: { changePhoto(offset: -1) }) {
                        Image(systemName: "chevron.left").font(.system(size: 40)).foregroundColor(.white.opacity(0.3)).padding()
                    }.buttonStyle(PlainButtonStyle())
                }
                Spacer()
                if currentIndex < photos.count - 1 {
                    Button(action: { changePhoto(offset: 1) }) {
                        Image(systemName: "chevron.right").font(.system(size: 40)).foregroundColor(.white.opacity(0.3)).padding()
                    }.buttonStyle(PlainButtonStyle())
                }
            }
            
            VStack { 
                HStack { 
                    Spacer()
                    Button(action: { isPresented = false }) { 
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundColor(.white.opacity(0.8)).padding() 
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer() 
            } 
            
            Group {
                Button("") { changePhoto(offset: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { changePhoto(offset: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { isPresented = false }.keyboardShortcut(.escape, modifiers: [])
                Button("") { toggleFullScreen() }.keyboardShortcut("f", modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        } 
    } 
    
    private func changePhoto(offset: Int) {
        let newIndex = currentIndex + offset
        if newIndex >= 0 && newIndex < photos.count {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            
            currentIndex = newIndex
            scale = 1.0
            self.offset = .zero
            lastOffset = .zero
        }
    }
    
    private func toggleFullScreen() {
        #if canImport(AppKit)
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.toggleFullScreen(nil)
        }
        #endif
    }
}

private struct VideoInfoSheetView: View {
    let video: RemoteVideoInfo
    let serverAddress: String
    @Environment(\.dismiss) var dismiss
    var downloadManager: DownloadManager?

    private let bgGradient = LinearGradient(
        colors: [Color.appDarkBackground, Color.appDarkSurface],
        startPoint: .top,
        endPoint: .bottom
    )
    private let accentColor = Color.appGold

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    RemoteVideoThumbnailView(
                        thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)"),
                        duration: video.duration
                    )
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 10)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                    Button(action: startDownload) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("写真アプリに保存").fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(LinearGradient(colors: [accentColor, accentColor.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(Color.appDarkSurface)
                        .cornerRadius(16)
                        .shadow(color: accentColor.opacity(0.2), radius: 8, x: 0, y: 4)
                    }
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 16) {
                        InfoRow(title: "ファイル名", value: video.filename, isMain: true)
                        Divider().background(Color.white.opacity(0.2))
                        HStack {
                            if !video.isPhoto {
                                VStack(alignment: .leading) {
                                    Text("長さ").font(.caption).foregroundColor(.white.opacity(0.6))
                                    Text(formatDuration(video.duration))
                                        .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                                }
                                Spacer()
                            }
                            VStack(alignment: .leading) {
                                Text("インポート日").font(.caption).foregroundColor(.white.opacity(0.6))
                                Text(video.importDate, style: .date)
                                    .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                            }
                            if !video.isPhoto { Spacer() }
                        }
                        if let creationDate = video.creationDate {
                            Divider().background(Color.white.opacity(0.2))
                            VStack(alignment: .leading) {
                                Text("撮影日時").font(.caption).foregroundColor(.white.opacity(0.6))
                                Text(creationDate, style: .date)
                                    .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                            }
                        }
                        Divider().background(Color.white.opacity(0.2))
                        InfoRow(title: "種類", value: video.isPhoto ? "画像" : "動画", isMain: false)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    .padding(.horizontal, 20)

                    Spacer(minLength: 40)
                }
            }
            .background(bgGradient.ignoresSafeArea())
            .navigationTitle("詳細情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") { dismiss() }
                        .font(.body.weight(.bold))
                        .foregroundColor(accentColor)
                }
            }
        }
    }

    private func startDownload() {
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)") else { return }
        downloadManager?.startDownload(url: url, filename: video.filename, isPhoto: video.duration == 0)
        dismiss()
    }

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let s = Int(totalSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private struct InfoRow: View {
        let title: String
        let value: String
        var isMain: Bool = false

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                Text(value)
                    .font(isMain ? .headline.weight(.bold) : .subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Shake Gesture Components
private class ShakeDetectingUIView: UIView { 
    var onShake: () -> Void = {}
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { super.didMoveToWindow(); self.becomeFirstResponder() }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) { 
        if motion == .motionShake { onShake() }
        super.motionEnded(motion, with: event) 
    } 
}
private struct ShakeDetector: UIViewRepresentable { 
    let onShake: () -> Void
    func makeUIView(context: Context) -> ShakeDetectingUIView { let v = ShakeDetectingUIView(); v.onShake = onShake; return v }
    func updateUIView(_ uiView: ShakeDetectingUIView, context: Context) { uiView.onShake = onShake } 
}
private struct ShakeViewModifier: ViewModifier { 
    let onShake: () -> Void
    func body(content: Content) -> some View { content.background(ShakeDetector(onShake: onShake).frame(width: 0, height: 0)) } 
}
extension View { 
    func onShake(perform action: @escaping () -> Void) -> some View { self.modifier(ShakeViewModifier(onShake: action)) } 
}