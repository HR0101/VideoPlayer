import SwiftUI
import MediaServerKit
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
    private struct ShortsLaunchRequest: Identifiable {
        let id = UUID()
        let video: RemoteVideoInfo
        let playlist: [RemoteVideoInfo]
        let startTime: Double?
    }

    private struct ShortsShelfItem: Identifiable {
        let id: String
        let frameKey: String
        let video: RemoteVideoInfo
    }

    private let shortsMaxDuration: Double = 60

    let serverName: String
    let serverAddress: String
    let albumID: String
    var allServerAlbums: [RemoteAlbumInfo] = []
    var initialVideoToPlay: RemoteVideoInfo? = nil
    var initialStartTime: Double? = nil
    var isPresentedFromShorts: Bool = false
    
    @EnvironmentObject var navState: AppNavigationState
    
    @State private var videos: [RemoteVideoInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showEmptyMessage = false
    @State private var centeredVideoIDInFeed: String? = nil
    @State private var centeredShortIDByShelf: [String: String] = [:]
    @State private var searchText = ""
    
    @State private var videoToPlay: RemoteVideoInfo?
    @State private var playingVideoID: String?
    @State private var isPlayerMinimized: Bool = false
    @State private var photoToView: RemoteVideoInfo?
    @State private var videoForInfoSheet: RemoteVideoInfo?
    
    @State private var gridColumnCount: Int = 3
    @State private var lastPlayedID: String?
    
    @AppStorage("isListViewMode") private var isListViewMode = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private func adaptiveGridColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if horizontalSizeClass == .regular {
            if width > 1100 { count = 7 }
            else if width > 900 { count = 6 }
            else if width > 600 { count = 5 }
            else { count = 4 }
        } else {
            count = 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    @State private var isSelectionMode = false
    @State private var selectedVideoIDs = Set<String>()
    @State private var showMoveTargetSheet = false

    // 同時再生・スライドショー
    @State private var showMultiPlayer = false
    @State private var multiPlayVideos: [RemoteVideoInfo] = []
    @State private var showSlideshow = false
    @State private var slideshowVideos: [RemoteVideoInfo] = []
    @State private var shortsLaunchRequest: ShortsLaunchRequest? = nil
    @State private var showShortsFavoritesPlayer = false
    @State private var selectedShortsFavoriteIndex: Int = 0
    @State private var isShortsPlaying: Bool = true
    
    @State private var showUploadSourceMenu = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var isUploading = false
    @State private var itemsPendingDeletion: [PickedMediaItem] = []
    @State private var showDeletePrompt = false
    
    @State private var showAlbumNav = false
    @State private var selectedAlbumIDForNav: String?
    
    @EnvironmentObject var downloadManager: DownloadManager
    @ObservedObject private var favorites = FavoritesManager.shared

    @State private var currentSortOrder: RemoteSortOrder = .importDescending
    
    // コントロール表示用の状態はDraggablePlayerViewに移動しました

    private let primaryDarkColor = Color.appDarkBackground
    private let accentGlowColor  = Color.appGold

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: gridColumnCount) }

    private var emptyMessage: String {
        switch albumID {
        case "HISTORY": return "再生履歴はありません。"
        case "FAVORITES": return "お気に入りに追加したメディアが\nここに表示されます。"
        default: return "右上のアップロードボタンから\n動画や写真を追加してください。"
        }
    }

    private var sortedAndFilteredVideos: [RemoteVideoInfo] {
        let uniqueVideos = uniqueVideosByID(videos)
        let filtered = searchText.isEmpty ? uniqueVideos : uniqueVideos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        if albumID == "HISTORY" || albumID == "FAVORITES" || albumID == "HOME" {
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
            if !isPresentedFromShorts {
                AppBackground()
                
                Group {
                    if isLoading {
                        VStack(spacing: 20) {
                            ProgressView().scaleEffect(1.5).tint(accentGlowColor)
                            Text("読み込み中...").foregroundColor(.white.opacity(0.8)).font(.headline)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if showEmptyMessage && videos.isEmpty && (errorMessage == nil || isVirtualAlbum) {
                        VStack(spacing: 16) {
                            Image(systemName: "film.circle").font(.system(size: 64)).foregroundColor(.white.opacity(0.3))
                            Text(isVirtualAlbum ? "メディアがありません" : "動画がありません").font(.title3.weight(.medium)).foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { geo in
                            if albumID == "SHORTS" {
                                RemoteShortsPlayerView(videos: sortedAndFilteredVideos, serverAddress: serverAddress, allServerAlbums: allServerAlbums, initialVideoToPlay: initialVideoToPlay) { playing in
                                    isShortsPlaying = playing
                                }
                                .id((initialVideoToPlay?.id ?? "shorts") + navState.shortsJumpTrigger.uuidString)
                            } else if albumID == "SHORTS_FAVORITES" {
                                shortsFavoritesGrid(width: geo.size.width)
                            } else if albumID == "HOME" {
                                homeFeedList(width: geo.size.width)
                            } else {
                                if isListViewMode { videoList } else { videoGrid(width: geo.size.width) }
                            }
                        }
                    }
                }
                
                if let error = errorMessage, !isVirtualAlbum {
                    VStack { Spacer(); Text(error).foregroundColor(.white).padding().background(Color.red.opacity(0.8)).cornerRadius(10).padding() }
                }
                
                if isUploading {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                        VStack(spacing: 24) {
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.2), lineWidth: 4).frame(width: 56, height: 56)
                                ProgressView().scaleEffect(1.4).tint(accentGlowColor)
                            }
                            Text("サーバーへアップロード中…").foregroundColor(.white).font(.headline.weight(.medium)).tracking(1.0)
                        }
                        .padding(40)
                        .glassCard(cornerRadius: 28)
                    }
                    .transition(.opacity)
                }
                
                if isSelectionMode {
                    VStack {
                        Spacer()
                        VStack(spacing: 0) {
                            let selectedVideoCount = sortedAndFilteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isPhoto }.count
                            HStack(spacing: 10) {
                                Button(action: {
                                    Haptics.light()
                                    multiPlayVideos = sortedAndFilteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isPhoto }
                                    showMultiPlayer = true
                                }) {
                                    Label("同時再生", systemImage: "square.grid.2x2.fill")
                                        .font(.subheadline.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(selectedVideoCount >= 2 ? AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.08)))
                                        .foregroundStyle(selectedVideoCount >= 2 ? .white : Color.appTextTertiary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(PressableCardStyle(scale: 0.97))
                                .disabled(selectedVideoCount < 2)

                                Button(action: {
                                    Haptics.light()
                                    slideshowVideos = sortedAndFilteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isPhoto }
                                    showSlideshow = true
                                }) {
                                    Label("スライドショー", systemImage: "play.square.stack.fill")
                                        .font(.subheadline.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(selectedVideoCount >= 2 ? AnyShapeStyle(LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.08)))
                                        .foregroundStyle(selectedVideoCount >= 2 ? .white : Color.appTextTertiary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(PressableCardStyle(scale: 0.97))
                                .disabled(selectedVideoCount < 2)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                            
                            HStack(spacing: 14) {
                                Button(action: { Haptics.warning(); deleteSelectedVideos() }) {
                                    Label("\(selectedVideoIDs.count)件削除", systemImage: "trash.fill")
                                        .font(.subheadline.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(selectedVideoIDs.isEmpty ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(LinearGradient(colors: [.red, .red.opacity(0.75)], startPoint: .top, endPoint: .bottom)))
                                        .foregroundStyle(selectedVideoIDs.isEmpty ? Color.appTextTertiary : .white)
                                        .clipShape(Capsule())
                                        .shadow(color: selectedVideoIDs.isEmpty ? .clear : Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                                }
                                .buttonStyle(PressableCardStyle(scale: 0.97))
                                .disabled(selectedVideoIDs.isEmpty)

                                if !isVirtualAlbum {
                                    Button(action: { Haptics.light(); showMoveTargetSheet = true }) {
                                        Label("移動", systemImage: "folder.fill")
                                            .font(.subheadline.weight(.bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .background(selectedVideoIDs.isEmpty ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(AppTheme.goldGradient))
                                            .foregroundStyle(selectedVideoIDs.isEmpty ? Color.appTextTertiary : Color.appDarkBackground)
                                            .clipShape(Capsule())
                                            .shadow(color: selectedVideoIDs.isEmpty ? .clear : accentGlowColor.opacity(0.3), radius: 8, x: 0, y: 4)
                                    }
                                    .buttonStyle(PressableCardStyle(scale: 0.97))
                                    .disabled(selectedVideoIDs.isEmpty)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        }
                        .background(.ultraThinMaterial)
                        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.white.opacity(0.1)), alignment: .top)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } // close if !isPresentedFromShorts
            
            if let video = videoToPlay {
                let onlyVideos = sortedAndFilteredVideos.filter { !$0.isPhoto }
                let playerStartTime = video.id == initialVideoToPlay?.id ? initialStartTime : nil
                if let initialIndex = onlyVideos.firstIndex(where: { $0.id == video.id }) {
                    DraggablePlayerView(
                        videos: onlyVideos,
                        initialIndex: initialIndex,
                        serverAddress: serverAddress,
                        videoToPlay: $videoToPlay,
                        playingVideoID: $playingVideoID,
                        isMinimized: $isPlayerMinimized,
                        initialStartTime: playerStartTime,
                        isPresentedFromShorts: isPresentedFromShorts
                    )
                    .id(video.id)
                    .onAppear { if let id = playingVideoID { lastPlayedID = id } }
                    .onDisappear { lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
                    .zIndex(100)
                } else {
                    DraggablePlayerView(
                        videos: [video],
                        initialIndex: 0,
                        serverAddress: serverAddress,
                        videoToPlay: $videoToPlay,
                        playingVideoID: $playingVideoID,
                        isMinimized: $isPlayerMinimized,
                        initialStartTime: playerStartTime,
                        isPresentedFromShorts: isPresentedFromShorts
                    )
                    .id(video.id)
                    .onAppear { if let id = playingVideoID { lastPlayedID = id } }
                    .onDisappear { lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
                    .zIndex(100)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSelectionMode)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
        .toolbar(shouldHideNavigationBar ? .hidden : .visible, for: .navigationBar)
        .toolbar((videoToPlay != nil && !isPlayerMinimized) || (albumID == "SHORTS" && isShortsPlaying) ? .hidden : .automatic, for: .tabBar)
        .fullScreenCover(isPresented: $showShortsFavoritesPlayer) {
            RemoteShortsFavoritesPlayerView(
                videos: sortedAndFilteredVideos,
                serverAddress: serverAddress,
                allServerAlbums: allServerAlbums,
                initialIndex: selectedShortsFavoriteIndex
            )
        }
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
                    
                    if albumID != "HOME" {
                        Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isListViewMode.toggle() } }) {
                            Image(systemName: isListViewMode ? "square.grid.2x2" : "list.bullet")
                                .foregroundColor(accentGlowColor)
                        }
                    }
                    
                    Button(action: { withAnimation { isSelectionMode = true } }) { Text("選択").foregroundColor(accentGlowColor) }.disabled(videos.isEmpty)
                    
                    if !isVirtualAlbum {
                        Menu {
                            Picker("並び替え", selection: $currentSortOrder) { ForEach(RemoteSortOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) } }
                        } label: { Image(systemName: "arrow.up.arrow.down.circle").foregroundColor(accentGlowColor) }
                    }
                    
                    if albumID != "SHORTS" && albumID != "HOME" {
                        Button(action: {
                            if let video = sortedAndFilteredVideos.filter({ isShortVideo($0) }).randomElement() {
                                openShortsPlayer(video: video, startTime: nil)
                            }
                        }) {
                            Image(systemName: "flame.fill").foregroundColor(.cyan)
                        }.disabled(sortedAndFilteredVideos.filter { isShortVideo($0) }.isEmpty)
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
        .fullScreenCover(isPresented: $showMultiPlayer) {
            RemoteMultiPlayerView(videos: multiPlayVideos, serverAddress: serverAddress)
        }
        .fullScreenCover(isPresented: $showSlideshow) {
            RemoteSlideshowPlayerView(videos: slideshowVideos, serverAddress: serverAddress)
        }
        .fullScreenCover(item: $shortsLaunchRequest) { request in
            // item ベースで提示することで、タップした動画が確実に initialVideoToPlay に渡る
            // （isPresented + 別 @State だと未反映の nil で生成され、ランダム再生になっていた）
            RemoteShortsPlayerView(videos: request.playlist, serverAddress: serverAddress, allServerAlbums: allServerAlbums, initialVideoToPlay: request.video, initialStartTime: request.startTime)
                .id(request.id)
        }
        .sheet(item: $videoForInfoSheet) { video in VideoInfoSheetView(video: video, serverAddress: serverAddress, downloadManager: downloadManager) }
        .task { 
            if let initial = initialVideoToPlay, albumID != "SHORTS" {
                videoToPlay = initial
                playingVideoID = initial.id
            }
            if videos.isEmpty { await fetchVideosFromServer() }
            lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID()
        }
        .onChange(of: allServerAlbums) { _, newAlbums in
            if isVirtualAlbum && videos.isEmpty && !newAlbums.isEmpty {
                Task { await fetchVideosFromServer() }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showEmptyMessage = true
            }
        }
        .onShake {
            playRandomVideo()
        }
        .navigationDestination(isPresented: $showAlbumNav) {
            if let pid = selectedAlbumIDForNav, let album = allServerAlbums.first(where: { $0.id == pid }) {
                RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: pid, allServerAlbums: allServerAlbums)
            }
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
    private func videoGrid(width: CGFloat) -> some View {
        ScrollView {
            LazyVGrid(columns: adaptiveGridColumns(for: width), spacing: 8) {
                ForEach(sortedAndFilteredVideos) { video in
                    thumbnailCell(for: video)
                        .scrollTransition(.animated(.spring(response: 0.4, dampingFraction: 0.8))) { content, phase in
                            content
                                .opacity(phase.isIdentity ? 1 : 0.5)
                                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                        }
                }
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
                        .scrollTransition(.animated(.spring(response: 0.4, dampingFraction: 0.8))) { content, phase in
                            content
                                .opacity(phase.isIdentity ? 1 : 0.5)
                                .scaleEffect(phase.isIdentity ? 1 : 0.96)
                        }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, isSelectionMode ? 100 : 0)
        }
        .refreshable { await fetchVideosFromServer() }
    }
    
    // MARK: - ホームフィード（YouTube風 大きなサムネイル）
    private func homeFeedList(width: CGFloat) -> some View {
        let shorts = sortedAndFilteredVideos.filter { isShortVideo($0) }
        
        return ScrollView {
            LazyVStack(spacing: 32) {
                let enumeratedVideos = Array(sortedAndFilteredVideos.enumerated())
                ForEach(enumeratedVideos, id: \.element.id) { index, video in
                    homeFeedRow(for: video, width: width)
                        .scrollTransition(.animated(.spring(response: 0.4, dampingFraction: 0.8))) { content, phase in
                            content
                                .opacity(phase.isIdentity ? 1 : 0.5)
                                .scaleEffect(phase.isIdentity ? 1 : 0.95)
                        }
                    
                    if isShortsShelfIndex(index) && !shorts.isEmpty {
                        shortsShelf(shorts: getStableShorts(for: index, from: shorts), width: width, shelfID: "shelf-\(index)")
                    }
                }
                
                // If there are less than 2 videos, display shorts shelf at the end
                if enumeratedVideos.count <= 1 && !shorts.isEmpty {
                    shortsShelf(shorts: getStableShorts(for: 1, from: shorts), width: width, shelfID: "shelf-end")
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, isSelectionMode ? 100 : 0)
        }
        .onPreferenceChange(FeedVideoFrameKey.self) { frames in
            let screenCenter = UIScreen.main.bounds.height / 2
            var closestID: String? = nil
            var minDistance: CGFloat = .infinity
            for (id, frame) in frames {
                let dist = abs(frame.midY - screenCenter)
                if dist < minDistance && dist < frame.height * 0.8 {
                    minDistance = dist
                    closestID = id
                }
            }
            if centeredVideoIDInFeed != closestID {
                centeredVideoIDInFeed = closestID
            }
        }
        .refreshable { await fetchVideosFromServer() }
    }
    
    private func getStableShorts(for shelfIndex: Int, from allShorts: [RemoteVideoInfo]) -> [RemoteVideoInfo] {
        let sorted = allShorts.filter { isShortVideo($0) }.sorted {
            let hash0 = UInt(bitPattern: $0.id.hashValue ^ shelfIndex.hashValue)
            let hash1 = UInt(bitPattern: $1.id.hashValue ^ shelfIndex.hashValue)
            return hash0 < hash1
        }
        
        var selected = [RemoteVideoInfo]()
        
        // おすすめショート棚は，実際にショートとして再生する動画だけに限定する。
        selected.append(contentsOf: sorted.prefix(15))
        
        // 棚ごとにもう一度安定したハッシュで並び替えて返す。
        return selected.sorted {
            let hash0 = UInt(bitPattern: $0.id.hashValue ^ (shelfIndex.hashValue &* 2))
            let hash1 = UInt(bitPattern: $1.id.hashValue ^ (shelfIndex.hashValue &* 2))
            return hash0 < hash1
        }
    }

    private func isShortsShelfIndex(_ index: Int) -> Bool {
        if index == 1 { return true }
        if index < 1 { return false }
        
        var currentIndex = 1
        var seed = 12345
        while currentIndex < index {
            seed = (seed &* 1103515245) &+ 12345
            let step = 4 + (abs(seed) % 7) // 4 to 10
            currentIndex += step
            if currentIndex == index { return true }
        }
        return false
    }
    
    @ViewBuilder
    private func shortsShelf(shorts: [RemoteVideoInfo], width: CGFloat, shelfID: String) -> some View {
        let items = shortsShelfItems(shorts: shorts, shelfID: shelfID)
        let videoIDByFrameKey = Dictionary(uniqueKeysWithValues: items.map { ($0.frameKey, $0.video.id) })

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill").foregroundColor(.cyan)
                Text("おすすめショート")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        Button {
                            #if DEBUG
                            print("ShortsCardTap shelf=\(shelfID) key=\(item.frameKey) tappedID=\(item.video.id) title=\(item.video.filename)")
                            #endif
                            Haptics.light()
                            openShortsPlayer(video: item.video, playbackKey: item.frameKey)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Group {
                                    if centeredShortIDByShelf[shelfID] == item.video.id {
                                        FeedInlinePlayerView(video: item.video, serverAddress: serverAddress, width: 140, isOverlayActive: videoToPlay != nil, playbackKey: item.frameKey)
                                            .id(item.frameKey)
                                            .frame(width: 140, height: 250)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .allowsHitTesting(false)
                                    } else {
                                        RemoteVideoThumbnailView(
                                            thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(item.video.id)", query: [URLQueryItem(name: "original", value: "true")]),
                                            duration: item.video.duration,
                                            contentMode: .fill,
                                            forceSquare: false
                                        )
                                        .id(item.frameKey)
                                        .frame(width: 140, height: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .allowsHitTesting(false)
                                    }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                                
                                Text(item.video.filename.cleanVideoTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .frame(width: 140, alignment: .leading)
                            }
                            .frame(width: 140, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ShortsVideoFrameKey.self, value: [item.frameKey: geo.frame(in: .global)])
                        })
                    }
                }
                .padding(.horizontal, 16)
            }
            .contentShape(Rectangle())
            .onPreferenceChange(ShortsVideoFrameKey.self) { frames in
                let screenCenter = UIScreen.main.bounds.width / 2
                var closestID: String? = nil
                var minDistance: CGFloat = .infinity
                for (key, frame) in frames {
                    let dist = abs(frame.midX - screenCenter)
                    // If it's near the center horizontally
                    if dist < minDistance && dist < 140 * 1.5 {
                        minDistance = dist
                        closestID = videoIDByFrameKey[key]
                    }
                }
                if centeredShortIDByShelf[shelfID] != closestID {
                    centeredShortIDByShelf[shelfID] = closestID
                }
            }
        }
        .padding(.vertical, 20)
        .background(
            Color.white.opacity(0.03)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .top)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .bottom)
        )
    }

    @ViewBuilder
    private func homeFeedRow(for video: RemoteVideoInfo, width: CGFloat) -> some View {
        let isLastPlayed = video.id == lastPlayedID
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                if centeredVideoIDInFeed == video.id {
                    FeedInlinePlayerView(video: video, serverAddress: serverAddress, width: width, isOverlayActive: videoToPlay != nil)
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                } else {
                    RemoteVideoThumbnailView(thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)", query: [URLQueryItem(name: "original", value: "true")]), duration: video.duration, contentMode: .fill, forceSquare: false)
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                        .overlay(
                            Rectangle().stroke(isLastPlayed ? accentGlowColor : Color.clear, lineWidth: isLastPlayed ? 3 : 0)
                        )
                }
                
                Color.clear
                    .frame(width: width, height: width * 9 / 16)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: FeedVideoFrameKey.self, value: [video.id: geo.frame(in: .global)])
                    })
            }
            .overlay(alignment: .topLeading) {
                if favorites.isFavorite(video.id) {
                    Image(systemName: "heart.fill")
                        .font(.body)
                        .foregroundColor(.pink)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(12)
                }
            }
            
            HStack(alignment: .top, spacing: 12) {
                Button(action: {
                    if let pid = video.parentAlbumID, let _ = allServerAlbums.first(where: { $0.id == pid }) {
                        selectedAlbumIDForNav = pid
                        showAlbumNav = true
                    }
                }) {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: video.isPhoto ? "photo" : "play.tv.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.8))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.filename.cleanVideoTitle)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    
                    HStack(spacing: 6) {
                        let albumName = allServerAlbums.first(where: { $0.id == video.parentAlbumID })?.name ?? serverName
                        Text(albumName)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                        Text(video.importDate, style: .date)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { handleVideoTap(video) }
        .contextMenu { videoContextMenu(video) }
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
                Text(video.filename.cleanVideoTitle)
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
            Haptics.soft()
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id) }
        } else {
            Haptics.light()
            if video.isPhoto { 
                photoToView = video
            } else if albumID == "HOME" && isShortVideo(video) {
                // item ベースの fullScreenCover が presented され、この動画を先頭再生する
                openShortsPlayer(video: video)
            } else {
                playingVideoID = video.id
                PlaybackHistoryManager.shared.saveLastPlayed(id: video.id)
                videoToPlay = video
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isPlayerMinimized = false
                }
            }
        }
    }

    private func openShortsPlayer(video: RemoteVideoInfo, startTime: Double? = nil, playbackKey: String? = nil) {
        let cardStartTime = playbackKey.flatMap { FeedPlaybackManager.shared.times[$0] }
        let sharedStartTime = playbackKey == nil ? FeedPlaybackManager.shared.times[video.id] : nil
        let resolvedStartTime = startTime ?? cardStartTime ?? sharedStartTime ?? 0
        #if DEBUG
        print("ShortsLaunch tappedID=\(video.id) title=\(video.filename) start=\(resolvedStartTime)")
        #endif
        shortsLaunchRequest = ShortsLaunchRequest(
            video: video,
            playlist: shortsLaunchPlaylist(startingWith: video),
            startTime: resolvedStartTime
        )
    }

    private func shortsLaunchPlaylist(startingWith video: RemoteVideoInfo) -> [RemoteVideoInfo] {
        let baseVideos = uniqueVideosByID(sortedAndFilteredVideos).filter { isShortVideo($0) && $0.id != video.id }
        return [video] + baseVideos
    }

    private func shortsShelfItems(shorts: [RemoteVideoInfo], shelfID: String) -> [ShortsShelfItem] {
        uniqueVideosByID(shorts).enumerated().map { index, video in
            let frameKey = shortsFrameKey(shelfID: shelfID, index: index, videoID: video.id)
            return ShortsShelfItem(id: frameKey, frameKey: frameKey, video: video)
        }
    }

    private func shortsFrameKey(shelfID: String, index: Int, videoID: String) -> String {
        "\(shelfID)#\(index)#\(videoID)"
    }

    private func uniqueVideosByID(_ source: [RemoteVideoInfo]) -> [RemoteVideoInfo] {
        var seenIDs = Set<String>()
        return source.filter { video in
            seenIDs.insert(video.id).inserted
        }
    }

    private func isShortVideo(_ video: RemoteVideoInfo) -> Bool {
        !video.isPhoto && video.duration > 0 && video.duration <= shortsMaxDuration
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
    private var isVirtualAlbum: Bool { albumID == "HISTORY" || albumID == "FAVORITES" || albumID == "SHORTS" || albumID == "HOME" || albumID == "SHORTS_FAVORITES" }
    private var shouldHideNavigationBar: Bool { (videoToPlay != nil && !isPlayerMinimized) || albumID == "SHORTS" || albumID == "SHORTS_FAVORITES" }

    private func fetchAllMedia(includePhotos: Bool = true) async throws -> [RemoteVideoInfo] {
        let libraryAlbums = allServerAlbums.filter { $0.name == "ALL VIDEOS" || (includePhotos && $0.name == "ALL PHOTOS") }
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
        } else if albumID == "SHORTS" {
            do {
                self.videos = try await fetchAllMedia(includePhotos: false)
            } catch {
                errorMessage = "ショート取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "SHORTS_FAVORITES" {
            do {
                let allMedia = try await fetchAllMedia(includePhotos: false)
                let favVideoIDs = Set(ShortsFavoritesManager.shared.clips.map { $0.videoID })
                self.videos = allMedia.filter { favVideoIDs.contains($0.id) }
            } catch {
                errorMessage = "ショートお気に入り取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "HOME" {
            do {
                self.videos = try await fetchAllMedia(includePhotos: false).shuffled()
            } catch {
                errorMessage = "おすすめ取得失敗: \(error.localizedDescription)"
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
        
        // HDDのスリープ復帰（スピンアップ）等のため、アルバムを開いた直後に最初の動画の先頭データをバックグラウンドで要求しておく
        if let firstVid = self.videos.first(where: { !$0.isPhoto }),
           let wakeupURL = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(firstVid.id)") {
            Task.detached {
                var req = URLRequest(url: wakeupURL)
                req.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
                // キャッシュを無視して必ずサーバーにアクセスさせる
                req.cachePolicy = .reloadIgnoringLocalCacheData
                _ = try? await URLSession.shared.data(for: req)
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
    
    @ViewBuilder
    private func shortsFavoritesGrid(width: CGFloat) -> some View {
        let clips = ShortsFavoritesManager.shared.clips
        if clips.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "heart.slash")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.3))
                Text("お気に入りショートはありません")
                    .font(.title3.weight(.medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                        let url = ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(clip.videoID)", query: [URLQueryItem(name: "time", value: String(Int(clip.startTime)))])
                        
                        Button {
                            selectedShortsFavoriteIndex = index
                            showShortsFavoritesPlayer = true
                        } label: {
                            GeometryReader { itemGeo in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .empty: Rectangle().fill(Color.white.opacity(0.1))
                                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                                    case .failure: Rectangle().fill(Color.white.opacity(0.1)).overlay(Image(systemName: "film").foregroundColor(.white.opacity(0.3)))
                                    @unknown default: EmptyView()
                                    }
                                }
                                .frame(width: itemGeo.size.width, height: itemGeo.size.height)
                                .clipped()
                            }
                            .aspectRatio(9/16, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    /// 読み込み中のスケルトン表示（グリッド/リストの形を模倣）
    @ViewBuilder
    private var loadingSkeleton: some View {
        if isListViewMode {
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 16) {
                        SkeletonCard(cornerRadius: AppTheme.radiusS)
                            .frame(width: 80, height: 80)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonCard(cornerRadius: 4).frame(width: 160, height: 12)
                            SkeletonCard(cornerRadius: 4).frame(width: 90, height: 10)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .glassCard(cornerRadius: AppTheme.radiusM)
                    .padding(.horizontal, 16)
                }
                Spacer()
            }
            .padding(.top, 16)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonCard(cornerRadius: AppTheme.radiusM)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .scrollDisabled(true)
        }
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
    var contentMode: ContentMode = .fill
    var forceSquare: Bool = true

    var body: some View {
        let content = ZStack {
            Rectangle().fill(Color.appDarkSurface)
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                case .failure:
                    Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.2))
                default:
                    SkeletonCard(cornerRadius: 0)
                }
            }
        }
        
        Group {
            if forceSquare {
                content.aspectRatio(1, contentMode: .fit)
            } else {
                content
            }
        }
        .overlay(alignment: .bottom) {
            if duration > 0 {
                LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.7)]), startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 4)
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 {
                Text(duration.mediaDurationText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
    }
}

private enum RepeatMode { case off, all, one }

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct DraggablePlayerView: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String

    @Binding var videoToPlay: RemoteVideoInfo?
    @Binding var playingVideoID: String?
    @Binding var isMinimized: Bool
    let initialStartTime: Double?
    var isPresentedFromShorts: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @StateObject private var playerManager: PlayerManager
    @ObservedObject private var favorites = FavoritesManager.shared
    @State private var dragOffset: CGSize = .zero
    @State private var showSameAlbumOnly: Bool = false
    @State private var selectedQuality: String = "original"
    
    @State private var isControlsHidden = false
    @State private var showFloatingControlsOverlay = false
    @State private var showTitlePopup: Bool = false

    @State private var isPreparingQuality: Bool = false
    @State private var prepareProgress: Double = 0
    @State private var prepareTask: Task<Void, Never>? = nil

    @State private var showControls: Bool = true
    @State private var hideControlsTask: Task<Void, Never>? = nil

    // シークバー操作中の状態
    @State private var isScrubbing: Bool = false
    @State private var scrubTarget: Double = 0

    // ダブルタップ ±10秒のフィードバック表示
    private struct SeekFeedback: Equatable {
        let forward: Bool
        let id: UUID
    }
    @State private var seekFeedback: SeekFeedback? = nil

    @State private var isContinuous: Bool = true
    @State private var isShuffle: Bool = false
    @State private var repeatMode: RepeatMode = .off
    @State private var isSlideshow: Bool = false
    @AppStorage("slideshowClipDuration") private var slideshowClipDuration: Double = 10
    @State private var slideshowTask: Task<Void, Never>? = nil

    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var navState: AppNavigationState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let accentGlowColor = Color.appGold

    init(videos: [RemoteVideoInfo], initialIndex: Int, serverAddress: String, videoToPlay: Binding<RemoteVideoInfo?>, playingVideoID: Binding<String?>, isMinimized: Binding<Bool>, initialStartTime: Double? = nil, isPresentedFromShorts: Bool = false) {
        self.videos = videos
        self._currentIndex = State(initialValue: initialIndex)
        self.serverAddress = serverAddress
        self._videoToPlay = videoToPlay
        self._playingVideoID = playingVideoID
        self._isMinimized = isMinimized
        self.initialStartTime = initialStartTime
        self.isPresentedFromShorts = isPresentedFromShorts
        self._showSameAlbumOnly = State(initialValue: UserDefaults.standard.bool(forKey: "showSameAlbumOnlyDefault"))
        
        let initialVideo = videos[initialIndex]
        let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(initialVideo.id)") ?? URL(string: "\(serverAddress)/video/\(initialVideo.id)")!
        let storedStartTime = FeedPlaybackManager.shared.times[initialVideo.id]
        let startAt = [initialStartTime, storedStartTime].compactMap { $0 }.first(where: { $0.isFinite }) ?? 0.0
        self._playerManager = StateObject(wrappedValue: PlayerManager(videoURL: url, startAt: startAt))
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isMinimized {
                    miniPlayerBody(width: geo.size.width, height: geo.size.height)
                } else {
                    if geo.size.width <= geo.size.height {
                        portraitBody(width: geo.size.width, topInset: geo.safeAreaInsets.top)
                    } else {
                        landscapeBody
                    }
                    keyboardShortcutButtons
                }
            }
        }
        .ignoresSafeArea()
        .overlay {
            if showTitlePopup {
                titlePopupOverlay
            }
        }
        .background(
            (isMinimized ? Color.clear : Color.black.opacity(max(0, 1.0 - Double(max(0, dragOffset.height)) / 300.0)))
                .ignoresSafeArea()
        )
        .onAppear {
            startHideTimer()
            playerManager.onEnded = { handlePlaybackEnded() }
            syncCurrentIndexWithPlayingVideo()
        }
        .onChange(of: videos) { _, _ in
            syncCurrentIndexWithPlayingVideo()
        }
        .onChange(of: playingVideoID) { _, _ in
            syncCurrentIndexWithPlayingVideo()
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

    // MARK: - 横向き（全画面）レイアウト

    private var landscapeBody: some View {
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
            
            // 映像面（OS標準コントロールなし。カスタムコントロールを重ねる）
            ZStack {
                PlayerLayerView(player: playerManager.player)
                if !playerManager.isReadyToPlay {
                    ProgressView().tint(.white).scaleEffect(1.3)
                }
            }
            .scaleEffect(max(0.8, 1 - (max(abs(dragOffset.width), max(0, dragOffset.height)) / 800)))
            .offset(x: dragOffset.width, y: dragOffset.height > 0 ? dragOffset.height : 0)
            .opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 300))

            // タップゾーン（中央: 表示切替 / 両端: ダブルタップで±10秒）
            tapZones

            // ±10秒のフィードバック
            seekFeedbackOverlay

            if showControls {
                controlsOverlay(compact: false)
                    .opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 100))
                    .transition(.opacity)
            }

            if isPreparingQuality {
                preparingOverlay
            }

        }
        .edgesIgnoringSafeArea(.all)
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard !isScrubbing else { return }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    guard !isScrubbing else { dragOffset = .zero; return }
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
    }

    /// 物理キーボード（iPad/Mac）用のショートカット。0サイズで常駐させる。
    private var keyboardShortcutButtons: some View {
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

    /// 画質変換中のローディングオーバーレイ（縦・横で共用）
    @ViewBuilder
    private var preparingOverlay: some View {
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
            .glassCard()
        }
        .transition(.opacity)
    }
    
    private var titlePopupOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showTitlePopup = false }
                }
            
            VStack(spacing: 20) {
                Text("動画タイトル")
                    .font(.headline)
                    .foregroundColor(.white)
                
                ScrollView {
                    if videos.indices.contains(currentIndex) {
                        Text(videos[currentIndex].filename.cleanVideoTitle)
                            .font(.body)
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .padding()
                    }
                }
                .frame(maxHeight: 150)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
                
                HStack(spacing: 20) {
                    Button(action: {
                        if videos.indices.contains(currentIndex) {
                            UIPasteboard.general.string = videos[currentIndex].filename.cleanVideoTitle
                        }
                        withAnimation { showTitlePopup = false }
                    }) {
                        Text("タイトルをコピー")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(accentGlowColor)
                            .foregroundColor(.black)
                            .cornerRadius(8)
                    }
                    
                    Button(action: {
                        withAnimation { showTitlePopup = false }
                    }) {
                        Text("閉じる")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(24)
            .background(Color.appDarkSurface)
            .cornerRadius(16)
            .padding(30)
        }
        .zIndex(1000)
    }

    // MARK: - 縦向き（YouTube風）レイアウト：上部で再生・下部で他の動画を探す

    private func portraitBody(width: CGFloat, topInset: CGFloat) -> some View {
        let videoHeight = width * 9.0 / 16.0
        // GeometryReader が ignoresSafeArea() されているため topInset は 0 になる。
        // UIApplication から実際のセーフエリアを取得し、ダイナミックアイランドとの重なりを避ける。
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = windowScene?.windows.first { $0.isKeyWindow } ?? windowScene?.windows.first
        let actualTopInset = window?.safeAreaInsets.top ?? 47
        let safeTop = actualTopInset > 0 ? actualTopInset : 47
        
        return VStack(spacing: 0) {
            // ダイナミックアイランド裏の黒帯
            Color.black
                .frame(height: safeTop)

            // 上部: 動画（16:9 固定）
            ZStack {
                Color.black
                PlayerLayerView(player: playerManager.player)
                if !playerManager.isReadyToPlay {
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
                tapZones
                seekFeedbackOverlay
                if showControls {
                    centerControls
                        .transition(.opacity)
                }
                if isPreparingQuality {
                    preparingOverlay
                }
            }
            .frame(width: width, height: videoHeight)
            .clipped()
            .contentShape(Rectangle())
            .offset(y: dragOffset.height > 0 ? dragOffset.height : 0)
            .zIndex(1)
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard !isScrubbing else { return }
                        dragOffset = value.translation
                    }
                    .onEnded { _ in
                        guard !isScrubbing else { dragOffset = .zero; return }
                        let w = dragOffset.width
                        let h = dragOffset.height
                        if h > 90 && abs(h) > abs(w) {
                            if isPresentedFromShorts {
                                playerManager.shutdown()
                                videoToPlay = nil
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    isMinimized = true
                                    dragOffset = .zero
                                }
                            }
                        } else if abs(w) > 90 && abs(w) > abs(h) {
                            changeVideo(offset: w < 0 ? 1 : -1)
                            withAnimation(.spring()) { dragOffset = .zero }
                        } else {
                            withAnimation(.spring()) { dragOffset = .zero }
                        }
                    }
            )

            Group {
                // 下部: コントロールパネルおよび他の動画リスト（一緒にスクロールする）
                upNextList(availableWidth: width)
            }
            .offset(y: isPresentedFromShorts ? (dragOffset.height > 0 ? dragOffset.height : 0) : (dragOffset.height > 0 ? dragOffset.height * 1.5 : 0))
            .opacity(max(0, 1.0 - Double(max(0, dragOffset.height)) / 150.0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            (isPresentedFromShorts ? Color.clear : Color.appDarkBackground.opacity(max(0, 1.0 - Double(max(0, dragOffset.height)) / 300.0)))
                .ignoresSafeArea()
        )
    }

    // MARK: - Mini Player
    private func miniPlayerBody(width: CGFloat, height: CGFloat) -> some View {
        let miniWidth: CGFloat = 160
        let miniHeight = miniWidth * 9.0 / 16.0
        
        return ZStack {
            Color.black
            PlayerLayerView(player: playerManager.player)
                .allowsHitTesting(false)
            
            // Close button overlay
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        playerManager.shutdown()
                        videoToPlay = nil
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.4).clipShape(Circle()))
                    }
                    .padding(4)
                }
                Spacer()
            }
        }
        .frame(width: miniWidth, height: miniHeight)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        // Position at bottom-right, keeping safe area in mind
        .position(x: width - miniWidth/2 - 16, y: height - miniHeight/2 - 100)
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isMinimized = false
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.width > 50 || value.translation.height > 50 || value.translation.width < -50 {
                        playerManager.shutdown()
                        withAnimation { videoToPlay = nil }
                    }
                }
        )
    }

    /// iPad 等の幅広端末ではグリッド、iPhone 等ではリスト表示で「次の動画」を表示
    private func upNextList(availableWidth: CGFloat) -> some View {
        let useGrid: Bool
        switch appSettings.upNextDisplayStyle {
        case 1: useGrid = false // List
        case 2: useGrid = true  // Grid
        default: useGrid = horizontalSizeClass == .regular && availableWidth > 500 // Auto
        }
        
        let hasMultipleAlbums = Set(videos.compactMap { $0.parentAlbumID }).count > 1
        let currentAlbumID = videos[currentIndex].parentAlbumID
        let displayVideos = (hasMultipleAlbums && showSameAlbumOnly) ? videos.filter { $0.parentAlbumID == currentAlbumID } : videos

        return ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // スクロールして消える部分（上部）
                    topBar(compact: true, isOverlay: false)
                        .background(Color.appDarkSurface)
                        .id("topBar")

                    // ピン留めされる完全固定部分
                    Section(header:
                        VStack(spacing: 0) {
                            if videos[currentIndex].duration > 0 {
                                videoSegmentsBar(width: availableWidth)
                            }
                            seekBarRow()
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                                .padding(.top, 8)
                        }
                        .background(Color.appDarkSurface)
                    ) {
                        // リストと一緒にスクロールする下部コントロール（シャッフル等）
                        playbackTogglesRow(compact: true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 16)
                            .background(Color.appDarkSurface)

                        // ヘッダー行
                        HStack {
                            Text("再生中・他の動画")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Spacer()
                            Text("\(displayVideos.count)本")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        
                        if hasMultipleAlbums {
                            Picker("表示フィルター", selection: $showSameAlbumOnly) {
                                Text("すべての動画").tag(false)
                                Text("同じアルバム").tag(true)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        }

                        if useGrid {
                            // iPadなど横幅の広い端末ではグリッド表示
                            let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: upNextGridColumnCount(width: availableWidth))
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(displayVideos, id: \.id) { video in
                                    let index = videos.firstIndex(where: { $0.id == video.id }) ?? 0
                                    Button { selectFromList(index) } label: {
                                        upNextGridCell(index: index, video: video)
                                    }
                                    .buttonStyle(.plain)
                                    .id(index)
                                }
                            }
                            .padding(.horizontal, 0)
                        } else {
                            // iPhone等ではリスト表示
                            LazyVStack(spacing: 0) {
                                ForEach(displayVideos, id: \.id) { video in
                                    let index = videos.firstIndex(where: { $0.id == video.id }) ?? 0
                                    Button { selectFromList(index) } label: {
                                        upNextRow(index: index, video: video)
                                    }
                                    .buttonStyle(.plain)
                                    .id(index)
                                }
                            }
                        }

                        Spacer().frame(height: 32)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentIndex) { _, _ in
                withAnimation(.easeInOut) { proxy.scrollTo("topBar", anchor: .top) }
            }
            .onAppear {
                proxy.scrollTo("topBar", anchor: .top)
            }
        }
    }

    /// 画面幅に応じたグリッド列数を計算
    private func upNextGridColumnCount(width: CGFloat) -> Int {
        if width > 1100 { return 5 }
        if width > 900  { return 4 }
        if width > 600  { return 3 }
        return 2
    }

    /// iPad用のグリッドセル（サムネ＋タイトル＋バッジ）
    private func upNextGridCell(index: Int, video: RemoteVideoInfo) -> some View {
        let isCurrent = index == currentIndex
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)")) { phase in
                    switch phase {
                    case .success(let image):
                        Color.clear.overlay(
                            image.resizable().scaledToFill()
                        )
                    case .failure:
                        ZStack { Color.appDarkSurface; Image(systemName: "film").foregroundStyle(.white.opacity(0.25)) }
                    default:
                        Color.appDarkSurface
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.appGold, lineWidth: 2.5)
                    }
                }

                if video.duration > 0 {
                    Text(video.duration.mediaDurationText)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(video.filename.cleanVideoTitle)
                    .font(.caption.weight(isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? Color.appGold : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    if isCurrent {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text("再生中")
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.appGold)
                    }
                    if favorites.isFavorite(video.id) {
                        Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(.pink)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(6)
        .background(isCurrent ? Color.white.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    /// iPhone用のリスト行
    private func upNextRow(index: Int, video: RemoteVideoInfo) -> some View {
        let isCurrent = index == currentIndex
        return HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        ZStack { Color.appDarkSurface; Image(systemName: "film").foregroundStyle(.white.opacity(0.25)) }
                    default:
                        Color.appDarkSurface
                    }
                }
                .frame(width: 136, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.appGold, lineWidth: 2)
                    }
                }

                if video.duration > 0 {
                    Text(video.duration.mediaDurationText)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(video.filename.cleanVideoTitle)
                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? Color.appGold : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if isCurrent {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("再生中")
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.appGold)
                } else if favorites.isFavorite(video.id) {
                    Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.white.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
    }
    
    // MARK: - Video Segments Bar
    @ViewBuilder
    private func videoSegmentsBar(width: CGFloat) -> some View {
        let video = videos[currentIndex]
        let duration = video.duration
        let segmentDuration = duration / 10.0
        
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { i in
                    let targetTime = segmentDuration * Double(i)
                    let url = ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)", query: [URLQueryItem(name: "time", value: String(Int(targetTime)))])
                    
                    Button(action: {
                        Haptics.light()
                        playerManager.seek(toSeconds: targetTime)
                    }) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                Rectangle().fill(Color.white.opacity(0.1))
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                Rectangle().fill(Color.white.opacity(0.1))
                                    .overlay(Image(systemName: "film").foregroundColor(.white.opacity(0.3)))
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(width: (width - 32) / 3.2, height: ((width - 32) / 3.2) * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Text(targetTime.mediaDurationText)
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.3))
    }

    private func selectFromList(_ index: Int) {
        guard index != currentIndex else {
            toggleControlsVisibility()
            return
        }
        goTo(index: index)
    }

    // MARK: - カスタムコントロール UI

    private func controlsOverlay(compact: Bool) -> some View {
        VStack(spacing: 0) {
            topBar(compact: compact, isOverlay: true)
            Spacer()
            bottomControls(compact: compact, isOverlay: true)
        }
        .overlay(centerControls)
    }

    /// 上部バー: 閉じる / タイトル / 画質 / お気に入り
    private func topBar(compact: Bool, isOverlay: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: { playerManager.shutdown(); videoToPlay = nil }) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
            }

            Text(videos[currentIndex].filename.cleanVideoTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(radius: 2)
                .textSelection(.enabled)
                .onTapGesture {
                    withAnimation { showTitlePopup = true }
                }

            Spacer(minLength: 8)

            Menu {
                Button(action: { changeQuality("original") }) { if selectedQuality == "original" { Label("オリジナル", systemImage: "checkmark") } else { Text("オリジナル") } }
                Button(action: { changeQuality("1080p") }) { if selectedQuality == "1080p" { Label("1080p (軽量・変換)", systemImage: "checkmark") } else { Text("1080p (軽量・変換)") } }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(qualityLabel(selectedQuality)).font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.white.opacity(0.12))
                .clipShape(Capsule())
            }

            Button(action: toggleFavorite) {
                let fav = favorites.isFavorite(videos[currentIndex].id)
                Image(systemName: fav ? "heart.fill" : "heart")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(fav ? .pink : .white)
                    .symbolEffect(.bounce, value: fav)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.top, compact ? (isOverlay ? 10 : 12) : 58)
        .padding(.bottom, compact ? (isOverlay ? 14 : 4) : 36)
        .background {
            if isOverlay {
                AppTheme.topScrim.allowsHitTesting(false)
            }
        }
    }

    /// 中央の再生コントロール
    private var centerControls: some View {
        HStack(spacing: 30) {
            Button(action: { changeVideo(offset: -1) }) {
                Image(systemName: "backward.end.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(currentIndex > 0 || isShuffle || repeatMode == .all ? 0.9 : 0.3))
                    .frame(width: 44, height: 44)
            }

            Button(action: { Haptics.soft(); quickSeek(forward: false); startHideTimer() }) {
                Image(systemName: "gobackward.10")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 48, height: 48)
            }

            Button(action: togglePlayPause) {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 74, height: 74)
                    .background(.white.opacity(0.14))
                    .background(.ultraThinMaterial.opacity(0.6))
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            }

            Button(action: { Haptics.soft(); quickSeek(forward: true); startHideTimer() }) {
                Image(systemName: "goforward.10")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 48, height: 48)
            }

            Button(action: { changeVideo(offset: 1) }) {
                Image(systemName: "forward.end.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(currentIndex < videos.count - 1 || isShuffle || repeatMode == .all ? 0.9 : 0.3))
                    .frame(width: 44, height: 44)
            }
        }
    }

    private func seekBarRow() -> some View {
        HStack(spacing: 10) {
            Text((isScrubbing ? scrubTarget : playerManager.currentTime).mediaDurationText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 40, alignment: .leading)

            seekBar

            Text(playerManager.duration.mediaDurationText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 40, alignment: .trailing)
        }
    }

    private func playbackTogglesRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 18 : 26) {
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSlideshow ? Color.appDarkBackground : .white.opacity(0.75))
                    .frame(width: 40, height: 40)
                    .background(isSlideshow ? AnyShapeStyle(AppTheme.goldGradient) : AnyShapeStyle(.white.opacity(0.12)))
                    .clipShape(Circle())
                    .shadow(color: isSlideshow ? Color.appGold.opacity(0.4) : .clear, radius: 6)
            }
        }
    }

    /// 下部: シークバー + 再生モードトグル
    private func bottomControls(compact: Bool, isOverlay: Bool = true) -> some View {
        VStack(spacing: 12) {
            seekBarRow()
            playbackTogglesRow(compact: compact)
        }
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.top, compact ? (isOverlay ? 16 : 8) : 50)
        .padding(.bottom, compact ? (isOverlay ? 12 : 16) : 46)
        .background {
            if isOverlay {
                LinearGradient(colors: [.clear, .black.opacity(0.45), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
    }

    /// ゴールドのカスタムシークバー（ドラッグでスクラブ）
    private var seekBar: some View {
        GeometryReader { geo in
            let duration = max(playerManager.duration, 0.01)
            let progress = min(max((isScrubbing ? scrubTarget : playerManager.currentTime) / duration, 0), 1)
            let barHeight: CGFloat = isScrubbing ? 9 : 5
            let knobSize: CGFloat = isScrubbing ? 19 : 13

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: barHeight)

                Capsule()
                    .fill(AppTheme.goldGradient)
                    .frame(width: max(geo.size.width * progress, barHeight), height: barHeight)
                    .shadow(color: Color.appGold.opacity(0.5), radius: isScrubbing ? 6 : 3)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                    .offset(x: geo.size.width * progress - knobSize / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        hideControlsTask?.cancel()
                        let ratio = min(max(0, value.location.x / geo.size.width), 1)
                        scrubTarget = Double(ratio) * playerManager.duration
                    }
                    .onEnded { _ in
                        playerManager.seek(toSeconds: scrubTarget)
                        Haptics.soft()
                        isScrubbing = false
                        startHideTimer()
                    }
            )
        }
        .frame(height: 30)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isScrubbing)
    }

    /// タップゾーン: 中央シングルタップで表示切替、左右ダブルタップで±10秒
    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleTapSeek(forward: false) }
                .onTapGesture { toggleControlsVisibility() }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControlsVisibility() }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleTapSeek(forward: true) }
                .onTapGesture { toggleControlsVisibility() }
        }
    }

    /// ±10秒シーク時のフィードバック表示
    @ViewBuilder
    private var seekFeedbackOverlay: some View {
        if let fb = seekFeedback {
            HStack {
                if fb.forward { Spacer() }
                VStack(spacing: 5) {
                    Image(systemName: fb.forward ? "goforward.10" : "gobackward.10")
                        .font(.system(size: 34, weight: .semibold))
                    Text(fb.forward ? "+10秒" : "−10秒")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(.black.opacity(0.35))
                .clipShape(Circle())
                .padding(.horizontal, 44)
                if !fb.forward { Spacer() }
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.75)))
            .id(fb.id)
        }
    }

    private func controlToggle(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.soft(); action() }) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? Color.appDarkBackground : .white.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(active ? AnyShapeStyle(AppTheme.goldGradient) : AnyShapeStyle(.white.opacity(0.12)))
                .clipShape(Circle())
                .shadow(color: active ? Color.appGold.opacity(0.4) : .clear, radius: 6)
        }
    }

    // MARK: - コントロール操作ヘルパー

    private func toggleControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { startHideTimer() } else { hideControlsTask?.cancel() }
    }

    /// ±10秒シーク（コントロール表示状態は変えない）
    private func quickSeek(forward: Bool) {
        let delta = CMTime(seconds: forward ? 10 : -10, preferredTimescale: 600)
        let newTime = CMTimeAdd(playerManager.player.currentTime(), delta)
        playerManager.player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func doubleTapSeek(forward: Bool) {
        Haptics.light()
        quickSeek(forward: forward)
        let fb = SeekFeedback(forward: forward, id: UUID())
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { seekFeedback = fb }
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run {
                if seekFeedback?.id == fb.id {
                    withAnimation(.easeOut(duration: 0.25)) { seekFeedback = nil }
                }
            }
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
        guard videos.indices.contains(currentIndex) else { return }
        let video = videos[currentIndex]
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)/proxy") else { return }
        let req = ServerAuth.request(url, address: serverAddress, method: "DELETE")
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private func syncCurrentIndexWithPlayingVideo() {
        guard !videos.isEmpty else { return }
        if let targetID = playingVideoID ?? videoToPlay?.id,
           let resolvedIndex = videos.firstIndex(where: { $0.id == targetID }) {
            if currentIndex != resolvedIndex {
                currentIndex = resolvedIndex
            }
        } else if !videos.indices.contains(currentIndex) {
            currentIndex = max(0, min(currentIndex, videos.count - 1))
        }
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
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                            .padding(.leading, 12)
                    }.buttonStyle(PlainButtonStyle())
                }
                Spacer()
                if currentIndex < photos.count - 1 {
                    Button(action: { changePhoto(offset: 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                            .padding(.trailing, 12)
                    }.buttonStyle(PlainButtonStyle())
                }
            }
            .opacity(scale > 1 ? 0 : 1)

            // 上部バー: 閉じる / ページカウンタ / 保存
            VStack {
                HStack {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()

                    if photos.count > 1 {
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button(action: {
                        downloadManager?.startDownload(url: url, filename: currentPhoto.filename, isPhoto: true)
                        Haptics.light()
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
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

// MARK: - Information Sheet
struct VideoInfoSheetView: View {
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

    init(video: RemoteVideoInfo, serverAddress: String, downloadManager: DownloadManager? = nil) {
        self.video = video
        self.serverAddress = serverAddress
        self.downloadManager = downloadManager
    }

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
                        .padding(.vertical, 15)
                        .background(AppTheme.goldGradient)
                        .foregroundColor(Color.appDarkBackground)
                        .clipShape(Capsule())
                        .shadow(color: accentColor.opacity(0.3), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(PressableCardStyle(scale: 0.97))
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

// MARK: - Home Feed AutoPlay Support

class FeedPlaybackManager {
    static let shared = FeedPlaybackManager()
    var times: [String: Double] = [:]
}

struct FeedVideoFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ShortsVideoFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct FeedInlinePlayerView: View {
    let video: RemoteVideoInfo
    let serverAddress: String
    let width: CGFloat
    let isOverlayActive: Bool
    var playbackKey: String? = nil
    
    @State private var player: AVPlayer?
    @State private var isReady: Bool = false
    @State private var endObserver: Any?
    @State private var timeObserverToken: Any?
    @AppStorage("feedVideoMuted") private var isMuted: Bool = false
    
    var body: some View {
        ZStack {
            Color.black
            if let p = player {
                PlayerLayerView(player: p, videoGravity: .resizeAspectFill)
                    .allowsHitTesting(false)
            }
            if !isReady {
                RemoteVideoThumbnailView(
                    thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)", query: [URLQueryItem(name: "original", value: "true")]),
                    duration: video.duration,
                    contentMode: .fill,
                    forceSquare: false
                )
            }
            
            if isReady {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            isMuted.toggle()
                        }) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onChange(of: isMuted) { _, muted in
            player?.isMuted = muted || isOverlayActive
        }
        .onChange(of: isOverlayActive) { _, active in
            player?.isMuted = isMuted || active
        }
        .onChange(of: video.id) { _, _ in
            resetPlayer()
            setupPlayer()
        }
        .onDisappear {
            resetPlayer()
        }
    }
    
    private func setupPlayer() {
        resetPlayer()
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)") else { return }
        let p = AVPlayer(url: url)
        p.isMuted = isMuted || isOverlayActive
        
        let dur = video.duration
        // 真ん中に重みを置いたランダムな開始位置
        let fraction = (Double.random(in: 0...1) + Double.random(in: 0...1)) / 2.0
        let targetSec = max(0, min(dur, dur * fraction))
        let key = playbackKey ?? video.id
        FeedPlaybackManager.shared.times[key] = targetSec
        FeedPlaybackManager.shared.times[video.id] = targetSec
        
        self.player = p
        p.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600)) { _ in
            DispatchQueue.main.async {
                guard player === p else { return }
                p.play()
                withAnimation(.easeInOut(duration: 0.3)) { isReady = true }
            }
        }
        
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            FeedPlaybackManager.shared.times[key] = time.seconds
            FeedPlaybackManager.shared.times[video.id] = time.seconds
        }
        
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero)
            p.play()
        }
    }

    private func resetPlayer() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        if let token = timeObserverToken, let currentPlayer = player {
            currentPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isReady = false
    }
}

extension String {
    /// 動画のファイル名から拡張子や不要な文字列（UUID、タイムスタンプ、ランダムなハッシュ値など）を取り除き、
    /// UI表示用のクリーンなタイトルを生成します。
    var cleanVideoTitle: String {
        // 1. 拡張子を削除
        var text = (self as NSString).deletingPathExtension
        let originalText = text
        
        // 2. ユーザーが設定した除外文字列を削除
        if let words = UserDefaults.standard.array(forKey: "excludedTitleWordsList") as? [String] {
            for word in words {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    text = text.replacingOccurrences(of: trimmed, with: " ", options: .caseInsensitive)
                }
            }
        }
        
        // 3. 不要なパターンの削除 (記号を消さずに、単語の境界を記号や空白で判定する)
        // UUID
        text = text.replacingOccurrences(of: "(?<=[^A-Za-z0-9]|^)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?=[^A-Za-z0-9]|$)", with: "", options: .regularExpression)
        
        // 6桁以上の数字の羅列（日付やタイムスタンプ、カメラのシーケンス番号など）
        text = text.replacingOccurrences(of: "(?<=[^A-Za-z0-9]|^)\\d{6,}(?=[^A-Za-z0-9]|$)", with: "", options: .regularExpression)
        
        // 接頭辞の削除 (大文字小文字を区別しない)
        text = text.replacingOccurrences(of: "(?<=[^A-Za-z0-9]|^)(LINE_ALBUM_|IMG_|VID_|RPReplay_)", with: "", options: [.regularExpression, .caseInsensitive])
        
        // 英数字が混ざった8文字以上のランダム文字列（ハッシュ値など）
        // (?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\\d) -> 単語内に英字と数字が両方含まれることを保証
        text = text.removingMatches(
            matching: "(?<=[^A-Za-z0-9]|^)(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\\d)[A-Za-z0-9]{8,}(?=[^A-Za-z0-9]|$)",
            keepingIfContainsRealWord: true
        )
        
        // 数字が含まれないアルファベットのみのランダム文字列対策（例: zJXShpZkIEIlXY）
        // 10文字以上で、大文字と小文字が混在し、かつ「小文字が3文字以上連続しない」不自然な単語（ハッシュ・ID特有のケース）
        text = text.removingMatches(
            matching: "(?<=[^A-Za-z0-9]|^)(?=.*[A-Z])(?=.*[a-z])(?![A-Za-z0-9]*[a-z]{3})[A-Za-z0-9]{10,}(?=[^A-Za-z0-9]|$)",
            keepingIfContainsRealWord: true
        )
        
        // URLエンコードされた文字列があれば戻す（%20など）
        text = text.removingPercentEncoding ?? text
        
        // 削除後に残った不要な記号の連続や、先頭・末尾の記号・空白を綺麗にする
        text = text.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
        text = text.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        text = text.replacingOccurrences(of: "^[_\\-~〜\\s\\[\\]()]+|[_\\-~〜\\s\\[\\]()]+$", with: "", options: .regularExpression)
        
        // 連続するスペースを1つにする
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // もし完全にランダムな文字列のみで空になってしまったら、元々のファイル名（拡張子なし）をそのまま採用する
        if text.isEmpty {
            return originalText
        }
        
        return text
    }
    
    /// 正規表現にマッチした部分文字列を削除します。keepingIfContainsRealWord が true の場合、
    /// マッチした文字列の中に実在する単語が含まれていれば削除せずに残します。
    func removingMatches(matching pattern: String, keepingIfContainsRealWord: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let nsString = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: nsString.length))
        
        var result = self
        // 後ろから置換することで、インデックスのズレを防ぐ
        for match in matches.reversed() {
            let matchedString = nsString.substring(with: match.range)
            var shouldKeep = false
            
            if keepingIfContainsRealWord && matchedString.containsRealWord() {
                shouldKeep = true
            }
            
            if !shouldKeep {
                if let rangeToReplace = Range(match.range, in: result) {
                    result.replaceSubrange(rangeToReplace, with: "")
                }
            }
        }
        return result
    }
    
    /// 文字列の中に実在する単語（英語などの辞書に載っている単語）が含まれているかを判定します
    func containsRealWord() -> Bool {
        let checker = UITextChecker()
        let nsText = self as NSString
        
        // 1. 連続したアルファベットのブロックを抽出してチェック
        let letterBlocks = self.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
        for block in letterBlocks {
            let range = NSRange(location: 0, length: block.utf16.count)
            if checker.rangeOfMisspelledWord(in: block, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
                return true
            }
        }
        
        // 2. キャメルケース（CamelCase）などで区切ってチェック（例: PartyVlog01 -> Party, Vlog）
        if let camelRegex = try? NSRegularExpression(pattern: "([A-Z]?[a-z]+|[A-Z]+(?![a-z]))") {
            let matches = camelRegex.matches(in: self, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let word = nsText.substring(with: match.range)
                if word.count >= 3 {
                    let range = NSRange(location: 0, length: word.utf16.count)
                    if checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
                        return true
                    }
                }
            }
        }
        
        // 3. 最後のフォールバック：4〜8文字の部分文字列をすべてチェックし、辞書に存在すればOKとする
        // （長すぎる文字列での処理落ちを防ぐため、元の文字列が50文字以下の場合のみ）
        if self.count < 50 {
            let lowerText = self.lowercased()
            let chars = Array(lowerText)
            if chars.count >= 4 {
                for i in 0...(chars.count - 4) {
                    for j in (i + 3)..<min(chars.count, i + 8) {
                        let sub = String(chars[i...j])
                        let range = NSRange(location: 0, length: sub.utf16.count)
                        if checker.rangeOfMisspelledWord(in: sub, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
                            return true
                        }
                    }
                }
            }
        }
        
        return false
    }
}
