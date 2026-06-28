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
    
    @StateObject private var viewModel = RemoteVideoListViewModel()
    @State private var showEmptyMessage = false
    @State private var centeredVideoIDInFeed: String? = nil
    @State private var centeredShortIDByShelf: [String: String] = [:]
    
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

    private var videos: [RemoteVideoInfo] { viewModel.videos }
    private var sortedAndFilteredVideos: [RemoteVideoInfo] { viewModel.sortedAndFilteredVideos(for: albumID) }

    var body: some View {
        ZStack {
            if !isPresentedFromShorts {
                AppBackground()
                
                Group {
                    if viewModel.isLoading {
                        VStack(spacing: 20) {
                            ProgressView().scaleEffect(1.5).tint(accentGlowColor)
                            Text("読み込み中...").foregroundColor(.white.opacity(0.8)).font(.headline)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if showEmptyMessage && videos.isEmpty && (viewModel.errorMessage == nil || isVirtualAlbum) {
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
                
                if let error = viewModel.errorMessage, !isVirtualAlbum {
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
                    selectionActionOverlay
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
        .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
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
                            Picker("並び替え", selection: $viewModel.currentSortOrder) { ForEach(RemoteSortOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) } }
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
    
    private var selectedVideoCount: Int {
        sortedAndFilteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isPhoto }.count
    }

    private var selectedVideosOnly: [RemoteVideoInfo] {
        sortedAndFilteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isPhoto }
    }

    private var selectionActionOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Button(action: { Haptics.warning(); deleteSelectedVideos() }) {
                        Label("\(selectedVideoIDs.count)件削除", systemImage: "trash.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(selectionButtonBackground(enabled: !selectedVideoIDs.isEmpty, colors: [.red, .red.opacity(0.75)]))
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

    private func selectionButtonBackground(enabled: Bool, colors: [Color]) -> AnyShapeStyle {
        if enabled {
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Color.white.opacity(0.08))
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
                                        FeedInlinePlayerView(video: item.video, serverAddress: serverAddress, width: 140, isOverlayActive: videoToPlay != nil || shortsLaunchRequest != nil, playbackKey: item.frameKey)
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
                let screenBounds = UIScreen.main.bounds
                let screenCenterX = screenBounds.width / 2
                let screenCenterY = screenBounds.height / 2
                var closestID: String? = nil
                var minDistance: CGFloat = .infinity
                for (key, frame) in frames {
                    let horizontalDistance = abs(frame.midX - screenCenterX)
                    let verticalDistance = abs(frame.midY - screenCenterY)
                    let isVerticallyActive = frame.intersects(screenBounds) && verticalDistance < frame.height * 0.9
                    if isVerticallyActive && horizontalDistance < minDistance && horizontalDistance < 140 * 1.5 {
                        minDistance = horizontalDistance
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
                    FeedInlinePlayerView(video: video, serverAddress: serverAddress, width: width, isOverlayActive: videoToPlay != nil || shortsLaunchRequest != nil)
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

    private func fetchVideosFromServer() async {
        await viewModel.fetchVideos(serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
    }
    
    private func executeMove(to targetID: String) {
        let ids = Array(selectedVideoIDs)
        Task {
            await viewModel.moveVideos(ids: ids, serverAddress: serverAddress, sourceAlbumID: albumID, targetAlbumID: targetID, allServerAlbums: allServerAlbums)
            isSelectionMode = false
            selectedVideoIDs.removeAll()
        }
    }
    
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
            Task {
                await viewModel.deleteVideos(ids: ids, serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
                isSelectionMode = false
                selectedVideoIDs.removeAll()
            }
        }
    }
    
    private func deleteSingleVideo(id: String) {
        Task {
            await viewModel.deleteVideos(ids: [id], serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
        }
    }
    
    private func handlePickedMedia(items: [PickedMediaItem]) {
        isUploading = true
        Task {
            await viewModel.uploadMedia(items: items, serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
            isUploading = false
            
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
