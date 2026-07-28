import SwiftUI
import AVKit
import MediaServerKit

struct SmartVideoPanView: View {
    let player: AVPlayer
    let videoSize: CGSize
    let scaleParam: Double
    
    var body: some View {
        if scaleParam > 0 {
            GeometryReader { geo in
                let viewAspect = geo.size.width / geo.size.height
                let videoAspect = videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : viewAspect
                
                let fillScale: CGFloat = {
                    if videoAspect > viewAspect {
                        return geo.size.height / (geo.size.width / videoAspect)
                    } else {
                        return geo.size.width / (geo.size.height * videoAspect)
                    }
                }()
                
                let finalScale: CGFloat = 1.0 + (fillScale - 1.0) * CGFloat(scaleParam)
                
                PlayerLayerView(player: player, videoGravity: .resizeAspect)
                    .scaleEffect(finalScale)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            PlayerLayerView(player: player, videoGravity: .resizeAspect)
        }
    }
}

private struct FullVideoLaunchRequest: Identifiable {
    let id = UUID()
    let video: RemoteVideoInfo
    let startTime: Double
}

@MainActor
final class RemoteShortsModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var currentVideo: RemoteVideoInfo?
    @Published var isLoading = false
    @Published var isPlaying = true
    @Published var progress: Double = 0.0
    @Published var isScrubbing = false
    @Published var videoSize: CGSize = .zero

    private var shuffledVideos: [RemoteVideoInfo] = []
    private var index = 0
    let serverAddress: String
    let clipDuration: Double = 60 // 1分
    @Published private(set) var clipStartTime: Double = 0
    private var timeObserverToken: Any?
    
    private var pendingInitialStartTime: Double?
    private var advanceTask: Task<Void, Never>?
    // 次の動画の先読み用（隠しプレイヤーでデータ／サーバーを温めるだけ。差し替え・使い回しはしない）
    private var preloadPlayer: AVPlayer?
    private var preloadedURL: URL?
    private var preloadTask: Task<Void, Never>?
    private var lastFastSeekTime = Date.distantPast
    private let requestedInitialVideo: RemoteVideoInfo?
    private let requestedInitialVideoID: String?
    private var didResolveInitialVideo = false
    private var didStart = false
    private let minimumRemainingDuration: Double = 1.0
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var clipRetry = 0
    private let maxClipRetry = 3

    private var effectiveClipDuration: Double {
        guard let duration = currentVideo?.duration, duration.isFinite, duration > clipStartTime else {
            return clipDuration
        }
        return max(0.1, min(clipDuration, duration - clipStartTime))
    }

    init(videos: [RemoteVideoInfo], serverAddress: String, initialVideo: RemoteVideoInfo? = nil, initialStartTime: Double? = nil) {
        // 写真を除外し、ランダムにシャッフルする
        var filtered = videos.filter { !$0.isPhoto }
        
        self.requestedInitialVideo = initialVideo
        self.requestedInitialVideoID = initialVideo?.id

        if let initial = initialVideo {
            filtered.removeAll(where: { $0.id == initial.id })
            self.shuffledVideos = [initial] + filtered.shuffled()
        } else {
            self.shuffledVideos = filtered.shuffled()
        }
        
        self.serverAddress = serverAddress
        self.pendingInitialStartTime = initialStartTime
        
        setupTimeObserver()
    }
    
    private func setupTimeObserver() {
        // Assumes timeObserverToken is already nil. Do not remove here.
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self, !self.isScrubbing else { return }
            let elapsed = time.seconds - self.clipStartTime
            self.progress = max(0, min(1, elapsed / self.effectiveClipDuration))
        }
    }

    func shutdown() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        advanceTask?.cancel()
        preloadTask?.cancel()
        preloadPlayer?.replaceCurrentItem(with: nil)
        preloadPlayer = nil
    }

    func jumpToVideo(_ video: RemoteVideoInfo, startTime: Double? = nil) {
        if let existingIndex = shuffledVideos.firstIndex(where: { $0.id == video.id }) {
            index = existingIndex
        } else {
            shuffledVideos.insert(video, at: index)
        }
        pendingInitialStartTime = startTime
        playClip()
        if !isPlaying {
            player.play()
            isPlaying = true
        }
    }

    var currentPlaybackTime: Double {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return clipStartTime }
        return max(0, seconds)
    }

    var nextPreviewVideo: RemoteVideoInfo? {
        guard shuffledVideos.count > 1 else { return nil }
        return shuffledVideos[(index + 1) % shuffledVideos.count]
    }

    var previousPreviewVideo: RemoteVideoInfo? {
        guard shuffledVideos.count > 1 else { return nil }
        let previousIndex = index == 0 ? shuffledVideos.count - 1 : index - 1
        return shuffledVideos[previousIndex]
    }

    func updateVideos(_ newVideos: [RemoteVideoInfo]) {
        let filtered = newVideos.filter { !$0.isPhoto }
        for v in filtered {
            if !shuffledVideos.contains(where: { $0.id == v.id }) {
                shuffledVideos.append(v)
            }
        }
        if !didStart && !shuffledVideos.isEmpty {
            start()
        }
    }

    func start() {
        guard !didStart else { return }
        if shuffledVideos.isEmpty { return }
        didStart = true
        pinRequestedInitialVideoIfNeeded()
        ServerAuth.prewarm(address: serverAddress, videoIDs: shuffledVideos.prefix(5).map { $0.id })
        playClip()
    }

    func playClip(isRetry: Bool = false) {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        // 現在のクリップを読み込む間は先読みを止め、帯域を新しい動画に優先的に回す
        preloadTask?.cancel()
        preloadPlayer?.replaceCurrentItem(with: nil)
        preloadPlayer = nil
        preloadedURL = nil

        if shuffledVideos.isEmpty { return }
        // 別クリップに切り替わるので、シークバー（progress）とスクラブ状態をリセットする。
        // これを入れないとスクラブした位置が次の動画に持ち越されてバーが戻らない。
        isScrubbing = false
        progress = 0
        if !isRetry { clipRetry = 0 }
        
        if index >= shuffledVideos.count {
            shuffledVideos.shuffle()
            index = 0
        }
        forceRequestedInitialVideoIfNeeded()
        
        let v = shuffledVideos[index]
        isLoading = true
        videoSize = .zero
        currentVideo = v
        #if DEBUG
        if let requestedInitialVideoID {
            print("ShortsPlay requestedID=\(requestedInitialVideoID) currentID=\(v.id) title=\(v.filename)")
        }
        #endif
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else {
            isLoading = false
            return
        }
        let startTarget: Double
        let requestedStartTime = isRetry ? nil : pendingInitialStartTime
        if requestedStartTime != nil {
            pendingInitialStartTime = nil
        }

        // 単一プレイヤーを使い回し、毎回新しいアイテムを作って差し替える（スライドショーと同じ確実な方式）。
        // プレイヤー自体を差し替えると黒画面、プリロード済みアイテムの使い回しは再生が止まる原因になるため、
        // ここでは使い回さず作り直す。次の動画の読み込みはサーバー側を温めて速くする。
        let item = AVPlayerItem(url: url)
        let dur = v.duration
        if let requestedStartTime {
            startTarget = clampedClipStartTime(requestedStartTime, duration: dur)
        } else if isRetry {
            startTarget = clipStartTime
        } else {
            startTarget = dur > self.clipDuration ? Double.random(in: 0...(dur - self.clipDuration)) : 0
        }

        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }

        self.clipStartTime = startTarget
        player.replaceCurrentItem(with: item)
        
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.next() }
        }

        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard observedItem.status == .readyToPlay else {
                    if observedItem.status == .failed {
                        if self.clipRetry < self.maxClipRetry {
                            self.clipRetry += 1
                            self.advanceTask = Task {
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                if !Task.isCancelled { await MainActor.run { self.playClip(isRetry: true) } }
                            }
                        } else {
                            self.isLoading = false
                            self.clipRetry = 0
                            self.advanceTask = Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { await MainActor.run { self.next() } }
                            }
                        }
                    }
                    return
                }
                
                // If the player replaced the item before this callback fired for the OLD item, ignore it
                if self.player.currentItem != observedItem { return }

                self.clipRetry = 0
                self.videoSize = observedItem.presentationSize
                self.isLoading = false

                // 現在の動画が再生可能になったので、次の動画の先読みを予約する（少し遅らせて開始し、現在の読み込みを優先）
                self.schedulePreloadNext()
                
                self.player.seek(to: CMTime(seconds: self.clipStartTime, preferredTimescale: 600)) { _ in
                    DispatchQueue.main.async {
                        if self.player.currentItem == observedItem {
                            self.player.play()
                            self.isPlaying = true
                            self.scheduleAdvance()
                        }
                    }
                }
            }
        }
        
    }

    /// 現在の動画が再生開始してから少し待って、次の動画を先読みする。
    /// 待つことで「今再生中の動画の読み込み」を優先し、先読みが邪魔をしないようにする。
    private func schedulePreloadNext() {
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.preloadNext() }
        }
    }

    private func preloadNext() {
        guard shuffledVideos.count > 1 else { return }
        let nextIndex = (index + 1) % shuffledVideos.count
        guard nextIndex != index, nextIndex < shuffledVideos.count else { return }
        let nextV = shuffledVideos[nextIndex]
        guard let nextUrl = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(nextV.id)") else { return }
        if preloadedURL == nextUrl, preloadPlayer != nil { return }

        // サーバー側を温める（HDDスピンアップ/OSキャッシュ）
        ServerAuth.prewarm(address: serverAddress, videoIDs: [nextV.id])

        // 隠しプレイヤーで次の動画の頭出しデータを先読み（映像なし・無音、バッファ上限を小さく）。
        // 差し替えも item の使い回しもしない「温め専用」。送り時は本体が新しい item を読むので
        // 黒画面・再生停止は起きず、サーバー/接続が温まっているぶん読み込みが速くなる。
        let item = AVPlayerItem(url: nextUrl)
        item.preferredForwardBufferDuration = 4
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = true
        preloadPlayer?.replaceCurrentItem(with: nil)
        preloadPlayer = p
        preloadedURL = nextUrl
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        // 動画の自然な終端まで再生するクリップ（1分未満の動画など）は、ウォールクロックの
        // タイマーを張らず endObserver の自然終了に任せる。タイマーだと、バッファリングで
        // 再生が遅れたぶん終端より手前で発火し、動画が途中で切れてしまうため。
        if let duration = currentVideo?.duration, duration.isFinite,
           duration - clipStartTime <= clipDuration + 0.5 {
            return
        }
        let remaining = max(0.1, effectiveClipDuration - max(0, player.currentTime().seconds - clipStartTime))
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.next() }
        }
    }

    func next() {
        index += 1
        playClip()
    }
    
    func previous() {
        index -= 1
        if index < 0 {
            index = max(0, shuffledVideos.count - 1)
        }
        playClip()
    }
    
    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            player.play()
            scheduleAdvance()
            isPlaying = true
        }
    }
    
    func pause() {
        if isPlaying {
            player.pause()
            advanceTask?.cancel()
            isPlaying = false
        }
    }
    
    func seek(to percent: Double) {
        advanceTask?.cancel()
        progress = percent
        let duration = effectiveClipDuration
        let safePercent = duration > 0.2 ? min(max(percent, 0), 0.99) : max(percent, 0)
        let targetSeconds = clipStartTime + (duration * safePercent)
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, finished else { return }
            self.progress = safePercent
            self.scheduleAdvance()
        }
    }

    func fastSeek(to percent: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastFastSeekTime) > 0.15 else { return }
        lastFastSeekTime = now
        
        advanceTask?.cancel()
        let duration = effectiveClipDuration
        let safePercent = duration > 0.2 ? min(max(percent, 0), 0.99) : max(percent, 0)
        let targetSeconds = clipStartTime + (duration * safePercent)
        progress = safePercent
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    }

    private func clampedClipStartTime(_ startTime: Double, duration: Double) -> Double {
        guard startTime.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let maxStart = max(0, duration - minimumRemainingDuration)
        return min(max(0, startTime), maxStart)
    }

    private func pinRequestedInitialVideoIfNeeded() {
        forceRequestedInitialVideoIfNeeded()
    }

    private func forceRequestedInitialVideoIfNeeded() {
        guard !didResolveInitialVideo, let requestedInitialVideoID else { return }
        if let requestedInitialVideo {
            shuffledVideos.removeAll { $0.id == requestedInitialVideoID }
            shuffledVideos.insert(requestedInitialVideo, at: 0)
            index = 0
            didResolveInitialVideo = true
            return
        }

        guard let initialIndex = shuffledVideos.firstIndex(where: { $0.id == requestedInitialVideoID }) else { return }
        guard initialIndex != 0 else {
            index = 0
            didResolveInitialVideo = true
            return
        }
        let initial = shuffledVideos.remove(at: initialIndex)
        shuffledVideos.insert(initial, at: 0)
        index = 0
        didResolveInitialVideo = true
    }
}

struct RemoteShortsPlayerView: View {
    @StateObject private var model: RemoteShortsModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var navState: AppNavigationState
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: FullVideoLaunchRequest? = nil
    @State private var pageDragOffset: CGFloat = 0
    @State private var isPageTransitioning = false
    @State private var transitionCoverVideo: RemoteVideoInfo?
    
    let videos: [RemoteVideoInfo]
    let allServerAlbums: [RemoteAlbumInfo]
    let initialVideoToPlay: RemoteVideoInfo?
    let initialStartTime: Double?
    var onPlayStateChanged: ((Bool) -> Void)?

    init(videos: [RemoteVideoInfo], serverAddress: String, allServerAlbums: [RemoteAlbumInfo], initialVideoToPlay: RemoteVideoInfo? = nil, initialStartTime: Double? = nil, onPlayStateChanged: ((Bool) -> Void)? = nil) {
        _model = StateObject(wrappedValue: RemoteShortsModel(videos: videos, serverAddress: serverAddress, initialVideo: initialVideoToPlay, initialStartTime: initialStartTime))
        self.videos = videos
        self.allServerAlbums = allServerAlbums
        self.initialVideoToPlay = initialVideoToPlay
        self.initialStartTime = initialStartTime
        self.onPlayStateChanged = onPlayStateChanged
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.currentVideo == nil {
                ProgressView().tint(.white)
            } else {
                GeometryReader { geo in
                    ZStack {
                        shortsAdjacentPreviewPages(pageHeight: geo.size.height)
                        currentShortsPage
                            .offset(y: pageDragOffset)
                        if let transitionCoverVideo {
                            ShortsPreviewPage(video: transitionCoverVideo, serverAddress: model.serverAddress)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                .ignoresSafeArea()
            }
        }
        // Vertical swipe to change video
        .gesture(
            DragGesture()
                .onChanged { value in
                    updatePageDrag(value)
                }
                .onEnded { value in
                    finishPageDrag(value)
                }
        )
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.shutdown()
        }
        .toolbar(model.isPlaying ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.isPlaying) { _, isPlaying in
            onPlayStateChanged?(isPlaying)
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading {
                hideTransitionCoverSoon()
            }
        }
        // Sheet for details
        .sheet(isPresented: $showInfoSheet, onDismiss: { if !model.isPlaying { model.togglePlay() } }) {
            if let v = model.currentVideo {
                VideoInfoSheetView(video: v, serverAddress: model.serverAddress, downloadManager: DownloadManager())
            }
        }
        // Fullscreen for jump to original
        .fullScreenCover(item: $jumpToFullVideo, onDismiss: { if !model.isPlaying { model.togglePlay() } }) { request in
            let v = request.video
            NavigationStack {
                RemoteVideoListView(
                    serverName: allServerAlbums.first(where: { $0.id == v.parentAlbumID })?.name ?? "動画",
                    serverAddress: model.serverAddress,
                    albumID: v.parentAlbumID ?? "ALL VIDEOS",
                    allServerAlbums: allServerAlbums,
                    initialVideoToPlay: v,
                    initialStartTime: request.startTime,
                    isPresentedFromShorts: true
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(" ") {
                            jumpToFullVideo = nil
                        }
                        .foregroundColor(.appGold)
                    }
                }
            }
            .presentationBackground(.clear)
        }
        .onChange(of: videos) { _, newVideos in
            model.updateVideos(newVideos)
        }
        .onChange(of: navState.shortsJumpTrigger) { _, _ in
            if let target = navState.targetShortsVideo {
                model.jumpToVideo(target)
            }
        }
    }

    private var currentShortsPage: some View {
        ZStack {
            SmartVideoPanView(player: model.player, videoSize: model.videoSize, scaleParam: appSettings.shortsVideoFillScale)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isPageTransitioning else { return }
                    model.togglePlay()
                }
            
            if model.isLoading {
                ProgressView().tint(.white).scaleEffect(1.5)
            }
            
            if !model.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.8))
                    .allowsHitTesting(false)
            }

            VStack {
                Group {
                    HStack {
                        Button(action: {
                            model.pause()
                            if navState.selectedTab == 1 {
                                navState.selectedTab = 0
                            } else {
                                dismiss()
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                                Text(" ")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        Spacer()
                        if model.currentVideo != nil {
                            Button(action: {
                                model.pause()
                                showInfoSheet = true
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "ellipsis.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                    Text(" ")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                }
                            }
                        }
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)

                    Spacer()

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let v = model.currentVideo {
                                Text(v.filename.cleanVideoTitle)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .shadow(radius: 2)
                                
                                Text(v.importDate, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        
                        Spacer()
                        
                        VStack(spacing: 24) {
                            if let v = model.currentVideo {
                                Button(action: {
                                    Haptics.light()
                                    let isShortsFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                    if isShortsFav {
                                        if let clipId = shortsFavorites.getClipId(videoID: v.id, startTime: model.clipStartTime) {
                                            shortsFavorites.removeClip(id: clipId)
                                        }
                                    } else {
                                        shortsFavorites.addClip(videoID: v.id, startTime: model.clipStartTime, endTime: model.clipStartTime + model.clipDuration)
                                        if !favorites.isFavorite(v.id) {
                                            favorites.toggle(v.id)
                                        }
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        let isFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                        Image(systemName: isFav ? "heart.fill" : "heart")
                                            .font(.title)
                                            .foregroundColor(isFav ? .pink : .white)
                                            .shadow(radius: 2)
                                        Text("いいね")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                }
                                
                                Button(action: {
                                    let startTime = model.currentPlaybackTime
                                    model.pause()
                                    jumpToFullVideo = FullVideoLaunchRequest(video: v, startTime: startTime)
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "play.tv.fill")
                                            .font(.title)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                        Text("本編へ")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
                .opacity(model.isPlaying ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isPlaying)
                
                EfficientShortsSeekBar(
                    progress: model.progress,
                    onScrubUpdate: { percent in model.fastSeek(to: percent) },
                    onScrubEnd: { percent in model.seek(to: percent) },
                    isScrubbing: $model.isScrubbing
                )
                .frame(height: 44)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func shortsAdjacentPreviewPages(pageHeight: CGFloat) -> some View {
        if pageDragOffset > 0, let previous = model.previousPreviewVideo {
            ShortsPreviewPage(video: previous, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset - pageHeight)
        }
        if pageDragOffset < 0, let next = model.nextPreviewVideo {
            ShortsPreviewPage(video: next, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset + pageHeight)
        }
    }

    private func updatePageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else { return }
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        pageDragOffset = value.translation.height
    }

    private func finishPageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else {
            resetPageDrag()
            return
        }
        let threshold: CGFloat = 70
        let predictedHeight = value.predictedEndTranslation.height
        let predictedWidth = value.predictedEndTranslation.width
        guard abs(predictedHeight) > abs(predictedWidth) else {
            resetPageDrag()
            return
        }
        if predictedHeight < -threshold {
            completePageTransition(toNext: true)
        } else if predictedHeight > threshold {
            completePageTransition(toNext: false)
        } else {
            resetPageDrag()
        }
    }

    private func completePageTransition(toNext: Bool) {
        isPageTransitioning = true
        let target = toNext ? -UIScreen.main.bounds.height : UIScreen.main.bounds.height
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            pageDragOffset = target
        }
        let coverVideo = toNext ? model.nextPreviewVideo : model.previousPreviewVideo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            transitionCoverVideo = coverVideo
            if toNext {
                model.next()
            } else {
                model.previous()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageDragOffset = 0
            }
            isPageTransitioning = false
            hideTransitionCoverSoon()
        }
    }

    private func resetPageDrag() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
            pageDragOffset = 0
        }
    }

    private func hideTransitionCoverSoon() {
        guard transitionCoverVideo != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !model.isLoading else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                transitionCoverVideo = nil
            }
        }
    }
}

// MARK: - お気に入りショート用プレイヤーモデル
@MainActor
final class RemoteShortsFavoritesModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var currentVideo: RemoteVideoInfo?
    @Published var isLoading = false
    @Published var isPlaying = true
    @Published var isScrubbing = false
    @Published var progress: Double = 0.0
    @Published var videoSize: CGSize = .zero

    private var clips: [ShortsFavoriteClip] = []
    private var allVideos: [RemoteVideoInfo] = []
    private var index = 0
    let serverAddress: String
    
    @Published private(set) var clipDuration: Double = 0
    @Published private(set) var clipStartTime: Double = 0
    private var timeObserverToken: Any?
    
    private var nextPlayer: AVPlayer?
    private var advanceTask: Task<Void, Never>?
    private var lastFastSeekTime = Date.distantPast
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?

    private var effectiveClipDuration: Double {
        guard let duration = currentVideo?.duration, duration.isFinite, duration > clipStartTime else {
            return max(0.1, clipDuration)
        }
        return max(0.1, min(clipDuration, duration - clipStartTime))
    }

    var nextPreviewVideo: RemoteVideoInfo? {
        guard clips.count > 1 else { return nil }
        return videoForClip(at: (index + 1) % clips.count)
    }

    var previousPreviewVideo: RemoteVideoInfo? {
        guard clips.count > 1 else { return nil }
        let previousIndex = index == 0 ? clips.count - 1 : index - 1
        return videoForClip(at: previousIndex)
    }

    private func videoForClip(at clipIndex: Int) -> RemoteVideoInfo? {
        guard clips.indices.contains(clipIndex) else { return nil }
        return allVideos.first { $0.id == clips[clipIndex].videoID }
    }

    init(videos: [RemoteVideoInfo], serverAddress: String, initialIndex: Int = 0) {
        self.allVideos = videos
        self.serverAddress = serverAddress
        self.clips = ShortsFavoritesManager.shared.clips
        self.index = min(max(0, initialIndex), max(0, clips.count - 1))
        
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.next() }
        }
        
        setupTimeObserver()
    }
    
    private func setupTimeObserver() {
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self, !self.isScrubbing else { return }
            let elapsed = time.seconds - self.clipStartTime
            if self.effectiveClipDuration > 0 {
                self.progress = max(0, min(1, elapsed / self.effectiveClipDuration))
            }
        }
    }

    func shutdown() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        nextPlayer?.pause()
        advanceTask?.cancel()
    }

    func start() {
        if clips.isEmpty { return }
        playClip()
    }

    func playClip() {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        
        if clips.isEmpty { return }
        
        if index >= clips.count {
            index = 0
        }
        
        let clip = clips[index]
        guard let v = allVideos.first(where: { $0.id == clip.videoID }) else {
            clips.remove(at: index)
            playClip()
            return
        }
        
        isLoading = true
        videoSize = .zero
        currentVideo = v
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else {
            isLoading = false
            return
        }

        let oldPlayer = self.player
        
        self.player = AVPlayer(url: url)
        self.clipStartTime = clip.startTime
        self.clipDuration = clip.endTime - clip.startTime
        
        if oldPlayer !== self.player {
            if let token = timeObserverToken {
                oldPlayer.removeTimeObserver(token)
                timeObserverToken = nil
            }
            oldPlayer.pause()
            oldPlayer.replaceCurrentItem(with: nil)
            setupTimeObserver()
        }
        
        guard let item = self.player.currentItem else {
            isLoading = false
            return
        }

        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard observedItem.status == .readyToPlay else {
                    if observedItem.status == .failed {
                        self.isLoading = false
                        self.advanceTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if !Task.isCancelled { await MainActor.run { self.next() } }
                        }
                    }
                    return
                }
                
                if self.player.currentItem != observedItem { return }

                self.videoSize = observedItem.presentationSize
                self.isLoading = false
                
                self.player.seek(to: CMTime(seconds: self.clipStartTime, preferredTimescale: 600)) { _ in
                    DispatchQueue.main.async {
                        if self.player.currentItem == observedItem {
                            self.player.play()
                            self.isPlaying = true
                            self.scheduleAdvance()
                        }
                    }
                }
            }
        }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        let remaining = max(0.1, effectiveClipDuration - max(0, player.currentTime().seconds - clipStartTime))
        advanceTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self.next() }
        }
    }

    func next() {
        index += 1
        playClip()
    }
    
    func previous() {
        index -= 1
        if index < 0 {
            index = max(0, clips.count - 1)
        }
        playClip()
    }
    
    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            player.play()
            scheduleAdvance()
            isPlaying = true
        }
    }
    
    func pause() {
        if isPlaying {
            player.pause()
            advanceTask?.cancel()
            isPlaying = false
        }
    }
    
    func seek(to percent: Double) {
        advanceTask?.cancel()
        let duration = effectiveClipDuration
        let safePercent = duration > 0.2 ? min(max(percent, 0), 0.99) : max(percent, 0)
        let targetSec = clipStartTime + (duration * safePercent)
        progress = safePercent
        player.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, finished else { return }
            self.scheduleAdvance()
        }
    }

    func fastSeek(to percent: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastFastSeekTime) > 0.15 else { return }
        lastFastSeekTime = now
        
        advanceTask?.cancel()
        let duration = effectiveClipDuration
        let safePercent = duration > 0.2 ? min(max(percent, 0), 0.99) : max(percent, 0)
        let targetSec = clipStartTime + (duration * safePercent)
        progress = safePercent
        player.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600), toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    }
}

// MARK: - お気に入りショート用プレイヤービュー
struct RemoteShortsFavoritesPlayerView: View {
    @StateObject private var model: RemoteShortsFavoritesModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appSettings: AppSettings
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: RemoteVideoInfo? = nil
    @State private var pageDragOffset: CGFloat = 0
    @State private var isPageTransitioning = false
    @State private var transitionCoverVideo: RemoteVideoInfo?
    
    let allServerAlbums: [RemoteAlbumInfo]
    var onPlayStateChanged: ((Bool) -> Void)?

    init(videos: [RemoteVideoInfo], serverAddress: String, allServerAlbums: [RemoteAlbumInfo], initialIndex: Int = 0, onPlayStateChanged: ((Bool) -> Void)? = nil) {
        _model = StateObject(wrappedValue: RemoteShortsFavoritesModel(videos: videos, serverAddress: serverAddress, initialIndex: initialIndex))
        self.allServerAlbums = allServerAlbums
        self.onPlayStateChanged = onPlayStateChanged
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.currentVideo == nil {
                if shortsFavorites.clips.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "heart.slash")
                            .font(.system(size: 64))
                            .foregroundColor(.white.opacity(0.3))
                        Text("お気に入りショートはありません")
                            .font(.title3.weight(.medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                GeometryReader { geo in
                    ZStack {
                        shortsAdjacentPreviewPages(pageHeight: geo.size.height)
                        currentFavoriteShortsPage
                            .offset(y: pageDragOffset)
                        if let transitionCoverVideo {
                            ShortsPreviewPage(video: transitionCoverVideo, serverAddress: model.serverAddress)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                .ignoresSafeArea()
            }
        }
        // Vertical swipe to change video
        .gesture(
            DragGesture()
                .onChanged { value in
                    updatePageDrag(value)
                }
                .onEnded { value in
                    finishPageDrag(value)
                }
        )
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
        .toolbar(model.isPlaying ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.isPlaying) { _, isPlaying in
            onPlayStateChanged?(isPlaying)
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading {
                hideTransitionCoverSoon()
            }
        }
    }

    private var currentFavoriteShortsPage: some View {
        ZStack {
            SmartVideoPanView(player: model.player, videoSize: model.videoSize, scaleParam: appSettings.shortsVideoFillScale)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isPageTransitioning else { return }
                    model.togglePlay()
                }
            
            if model.isLoading {
                ProgressView().tint(.white).scaleEffect(1.5)
            }
            
            if !model.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.8))
                    .allowsHitTesting(false)
            }

            VStack {
                if !model.isPlaying {
                    HStack {
                        Button(action: {
                            model.pause()
                            dismiss()
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                                Text(" ")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)
                }
                
                Group {
                    Spacer()

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let v = model.currentVideo {
                                Text(v.filename.cleanVideoTitle)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .shadow(radius: 2)
                            }
                        }
                        
                        Spacer()
                        
                        VStack(spacing: 24) {
                            if let v = model.currentVideo {
                                Button(action: {
                                    Haptics.light()
                                    let isShortsFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                    if isShortsFav, let clipId = shortsFavorites.getClipId(videoID: v.id, startTime: model.clipStartTime) {
                                        shortsFavorites.removeClip(id: clipId)
                                        if shortsFavorites.clips.isEmpty {
                                            dismiss()
                                        }
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        let isFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                        Image(systemName: isFav ? "heart.fill" : "heart")
                                            .font(.title)
                                            .foregroundColor(isFav ? .pink : .white)
                                            .shadow(radius: 2)
                                        Text("いいね")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
                .opacity(model.isPlaying ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isPlaying)
                
                EfficientShortsSeekBar(
                    progress: model.progress,
                    onScrubUpdate: { percent in model.fastSeek(to: percent) },
                    onScrubEnd: { percent in model.seek(to: percent) },
                    isScrubbing: $model.isScrubbing
                )
                .frame(height: 44)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func shortsAdjacentPreviewPages(pageHeight: CGFloat) -> some View {
        if pageDragOffset > 0, let previous = model.previousPreviewVideo {
            ShortsPreviewPage(video: previous, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset - pageHeight)
        }
        if pageDragOffset < 0, let next = model.nextPreviewVideo {
            ShortsPreviewPage(video: next, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset + pageHeight)
        }
    }

    private func updatePageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else { return }
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        pageDragOffset = value.translation.height
    }

    private func finishPageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else {
            resetPageDrag()
            return
        }
        let threshold: CGFloat = 70
        let predictedHeight = value.predictedEndTranslation.height
        let predictedWidth = value.predictedEndTranslation.width
        guard abs(predictedHeight) > abs(predictedWidth) else {
            resetPageDrag()
            return
        }
        if predictedHeight < -threshold {
            completePageTransition(toNext: true)
        } else if predictedHeight > threshold {
            completePageTransition(toNext: false)
        } else {
            resetPageDrag()
        }
    }

    private func completePageTransition(toNext: Bool) {
        isPageTransitioning = true
        let target = toNext ? -UIScreen.main.bounds.height : UIScreen.main.bounds.height
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            pageDragOffset = target
        }
        let coverVideo = toNext ? model.nextPreviewVideo : model.previousPreviewVideo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            transitionCoverVideo = coverVideo
            if toNext {
                model.next()
            } else {
                model.previous()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageDragOffset = 0
            }
            isPageTransitioning = false
            hideTransitionCoverSoon()
        }
    }

    private func resetPageDrag() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
            pageDragOffset = 0
        }
    }

    private func hideTransitionCoverSoon() {
        guard transitionCoverVideo != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !model.isLoading else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                transitionCoverVideo = nil
            }
        }
    }
}

struct ShortsPreviewPage: View {
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
                        .ignoresSafeArea()
                case .failure:
                    Image(systemName: "film")
                        .font(.system(size: 60, weight: .light))
                        .foregroundColor(.white.opacity(0.35))
                default:
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(video.filename.cleanVideoTitle)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(radius: 2)
                        Text(video.importDate, style: .date)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 68)
            }
        }
    }
}

struct EfficientShortsSeekBar: View {
    let progress: Double
    let onScrubUpdate: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    @Binding var isScrubbing: Bool
    
    @State private var localProgress: Double = 0
    
    var body: some View {
        GeometryReader { geo in
            let displayProgress = isScrubbing ? localProgress : progress
            
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 6)
                    .overlay(
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(displayProgress), height: 6),
                        alignment: .leading
                    )
                Spacer()
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                        }
                        let percent = max(0, min(1, value.location.x / geo.size.width))
                        localProgress = percent
                        onScrubUpdate(percent)
                    }
                    .onEnded { value in
                        let percent = max(0, min(1, value.location.x / geo.size.width))
                        onScrubEnd(percent)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isScrubbing = false
                        }
                    }
            )
        }
    }
}
