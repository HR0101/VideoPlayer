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

private enum RepeatMode { case off, all, one }

struct DraggablePlayerView: View {
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
    @State private var isVideoSwipeTransitioning = false
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
                        landscapeBody(width: geo.size.width)
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

    private func landscapeBody(width: CGFloat) -> some View {
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
            
            ZStack {
                if dragOffset.width > 0, let previous = landscapePreviewVideo(offset: -1) {
                    PlayerSwipePreviewPage(video: previous, serverAddress: serverAddress)
                        .offset(x: dragOffset.width - width)
                }
                if dragOffset.width < 0, let next = landscapePreviewVideo(offset: 1) {
                    PlayerSwipePreviewPage(video: next, serverAddress: serverAddress)
                        .offset(x: dragOffset.width + width)
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
                .opacity(1.0 - Double(max(0, dragOffset.height) / 300))
            }
            .clipped()

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
                    guard !isScrubbing, !isVideoSwipeTransitioning else { return }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    guard !isScrubbing, !isVideoSwipeTransitioning else { dragOffset = .zero; return }
                    let predictedWidth = value.predictedEndTranslation.width
                    let predictedHeight = value.predictedEndTranslation.height

                    if predictedHeight > 120 && abs(predictedHeight) > abs(predictedWidth) {
                        playerManager.shutdown()
                        videoToPlay = nil
                    }
                    else if abs(predictedWidth) > 120 && abs(predictedWidth) > abs(predictedHeight) {
                        completeLandscapeSwipe(forward: predictedWidth < 0, width: width)
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
                            EfficientSeekBarRow(
                                playerManager: playerManager,
                                startHideTimer: { self.startHideTimer() },
                                cancelHideTimer: { self.hideControlsTask?.cancel() },
                                isScrubbing: $isScrubbing
                            )
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

struct EfficientSeekBarRow: View {
    @ObservedObject var playerManager: PlayerManager
    let startHideTimer: () -> Void
    let cancelHideTimer: () -> Void
    @Binding var isScrubbing: Bool
    
    @State private var localProgress: Double = 0
    
    var body: some View {
        HStack(spacing: 10) {
            let duration = max(playerManager.duration, 0.01)
            let currentSec = isScrubbing ? localProgress * duration : playerManager.currentTime
            
            Text(currentSec.mediaDurationText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 40, alignment: .leading)

            GeometryReader { geo in
                let progress = isScrubbing ? localProgress : min(max(playerManager.currentTime / duration, 0), 1)
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
                            if !isScrubbing {
                                isScrubbing = true
                                cancelHideTimer()
                            }
                            let ratio = min(max(0, value.location.x / geo.size.width), 1)
                            localProgress = ratio
                            playerManager.fastSeek(toSeconds: ratio * duration)
                        }
                        .onEnded { value in
                            let ratio = min(max(0, value.location.x / geo.size.width), 1)
                            playerManager.seek(toSeconds: ratio * duration)
                            Haptics.soft()
                            startHideTimer()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isScrubbing = false
                            }
                        }
                )
            }
            .frame(height: 30)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isScrubbing)

            Text(playerManager.duration.mediaDurationText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 40, alignment: .trailing)
        }
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
            EfficientSeekBarRow(
                playerManager: playerManager,
                startHideTimer: { self.startHideTimer() },
                cancelHideTimer: { self.hideControlsTask?.cancel() },
                isScrubbing: $isScrubbing
            )
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

    private func landscapePreviewVideo(offset: Int) -> RemoteVideoInfo? {
        guard videos.count > 1, !isShuffle else { return nil }
        let target = currentIndex + offset
        if videos.indices.contains(target) {
            return videos[target]
        }
        if repeatMode == .all {
            return offset > 0 ? videos.first : videos.last
        }
        return nil
    }

    private func completeLandscapeSwipe(forward: Bool, width: CGFloat) {
        guard landscapePreviewVideo(offset: forward ? 1 : -1) != nil else {
            resetLandscapeDrag()
            return
        }
        isVideoSwipeTransitioning = true
        let targetX = forward ? -width : width
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            dragOffset = CGSize(width: targetX, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            changeVideo(offset: forward ? 1 : -1)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragOffset = .zero
            }
            isVideoSwipeTransitioning = false
        }
    }

    private func resetLandscapeDrag() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
            dragOffset = .zero
        }
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

struct PlayerSwipePreviewPage: View {
    let video: RemoteVideoInfo
    let serverAddress: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)", query: [URLQueryItem(name: "original", value: "true")])) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                default:
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                Spacer()
                Text(video.filename.cleanVideoTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 3)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
            }
        }
        .ignoresSafeArea()
    }
}

struct RemotePhotoViewer: View { 
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
            // フルスクリーンのプレイヤー/ショートが前面にある間は、裏のクイックビュー再生を止める
            if active { player?.pause() } else if isReady { player?.play() }
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
                // 前面にフルスクリーンの再生がある間は自動再生しない（裏で動かさない）
                if !isOverlayActive { p.play() }
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
