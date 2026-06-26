import SwiftUI
import AVKit
import MediaServerKit

// MARK: - スライドショー（サーバーの複数動画を指定秒ずつ連続再生）

@MainActor
final class RemoteSlideshowModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var index = 0
    @Published var isPlaying = true
    @Published var isLoading = false

    var videos: [RemoteVideoInfo] = []
    var serverAddress: String = ""
    private var clipDuration: Double = 15
    private var advanceTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    /// 同一クリップの読み込み失敗時のリトライ回数
    private var clipRetry = 0
    private let maxClipRetry = 3

    var currentTitle: String { videos.indices.contains(index) ? videos[index].filename : "" }

    func setup(videos: [RemoteVideoInfo], serverAddress: String) {
        self.videos = videos
        self.serverAddress = serverAddress
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.next() }
        }
    }

    func start(clip: Double) {
        clipDuration = clip
        index = 0
        // HDDのスピンアップ等を先に済ませる（コールド状態での再生開始失敗対策）
        ServerAuth.prewarm(address: serverAddress, videoIDs: videos.map { $0.id })
        playClip()
    }

    /// isRetry=true の場合は同じ index を読み直す（リトライ回数はリセットしない）
    func playClip(isRetry: Bool = false) {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        guard !videos.isEmpty else { return }
        if !isRetry { clipRetry = 0 }
        if index < 0 { index = videos.count - 1 }
        if index >= videos.count { index = 0 }

        let v = videos[index]
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else { return }

        isLoading = true
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // ステータスを監視して readyToPlay になってからシーク＆再生
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard observedItem.status == .readyToPlay else {
                    if observedItem.status == .failed {
                        // コールドHDDへの初回アクセス失敗等を考慮し、即スキップせず同じクリップをリトライする
                        if self.clipRetry < self.maxClipRetry {
                            self.clipRetry += 1
                            self.advanceTask = Task {
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                if !Task.isCancelled { await MainActor.run { self.playClip(isRetry: true) } }
                            }
                        } else {
                            self.isLoading = false
                            self.clipRetry = 0
                            // リトライしても駄目なら次のクリップへ
                            self.advanceTask = Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { await MainActor.run { self.next() } }
                            }
                        }
                    }
                    return
                }
                self.clipRetry = 0
                self.isLoading = false
                let dur = v.duration
                let start = dur > self.clipDuration ? Double.random(in: 0...(dur - self.clipDuration)) : 0
                self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in
                    DispatchQueue.main.async {
                        self.player.play()
                        self.isPlaying = true
                        self.scheduleAdvance()
                    }
                }
            }
        }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        let secs = clipDuration
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.next() }
        }
    }

    func next() { index += 1; playClip() }
    func prev() { index -= 1; playClip() }

    func togglePlay() {
        if player.rate > 0 {
            player.pause(); isPlaying = false; advanceTask?.cancel()
        } else {
            player.play(); isPlaying = true; scheduleAdvance()
        }
    }

    func shutdown() {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct RemoteSlideshowPlayerView: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RemoteSlideshowModel()

    private enum Phase { case setup, playing }
    @State private var phase: Phase = .setup
    @State private var clip: Double = 15

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .setup: setupView
            case .playing: playerView
            }
        }
        .statusBarHidden(true)
        .onAppear {
            model.setup(videos: videos, serverAddress: serverAddress)
        }
        .onDisappear { model.shutdown() }
    }

    private var setupView: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.square.stack.fill").font(.system(size: 44)).foregroundColor(.white)
            Text("スライドショー").font(.title2.bold()).foregroundColor(.white)
            Text("\(videos.count)本の動画から各クリップを切り出して連続再生します")
                .font(.callout).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)

            VStack(spacing: 8) {
                HStack {
                    Text("1クリップの長さ").foregroundColor(.white)
                    Spacer()
                    Text("\(Int(clip))秒").foregroundColor(.white).monospacedDigit()
                }
                Slider(value: $clip, in: 1...60, step: 1).tint(.white)
            }
            .frame(maxWidth: 340)

            HStack(spacing: 16) {
                Button("キャンセル") { dismiss() }.foregroundColor(.white)
                Button("開始") { phase = .playing; model.start(clip: clip) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
    }

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    private var playerView: some View {
        ZStack {
            PlayerLayerView(player: model.player).ignoresSafeArea()

            if model.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }

            VStack {
                HStack {
                    Text("\(model.index + 1) / \(videos.count)   \(model.currentTitle)")
                        .lineLimit(1).font(.subheadline.bold()).foregroundColor(.white).shadow(radius: 3)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding()

                Spacer()

                HStack(spacing: 30) {
                    btn("backward.end.fill") { model.prev() }
                    btn(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                    btn("forward.end.fill") { model.next() }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 30)
            }
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut, value: showControls)
            .allowsHitTesting(showControls)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { showControls.toggle() }
            if showControls { resetHideTimer() } else { hideTask?.cancel() }
        }
        .onAppear {
            resetHideTimer()
        }
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { showControls = false }
            }
        }
    }

    private func btn(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title).foregroundColor(.white).frame(width: 50, height: 50)
        }
    }
}

@MainActor
final class RemoteShortsModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var currentVideo: RemoteVideoInfo?
    @Published var isLoading = false
    @Published var isPlaying = true
    @Published var progress: Double = 0.0
    @Published var isScrubbing = false

    private var shuffledVideos: [RemoteVideoInfo] = []
    private var index = 0
    let serverAddress: String
    let clipDuration: Double = 60 // 1分
    @Published private(set) var clipStartTime: Double = 0
    private var timeObserverToken: Any?
    
    private var nextPlayer: AVPlayer?
    private var nextClipStartTime: Double = 0
    
    private var advanceTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var clipRetry = 0
    private let maxClipRetry = 3

    init(videos: [RemoteVideoInfo], serverAddress: String) {
        // 写真を除外し、ランダムにシャッフルする
        self.shuffledVideos = videos.filter { !$0.isPhoto }.shuffled()
        self.serverAddress = serverAddress
        
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.next() }
        }
        
        setupTimeObserver()
    }
    
    private func setupTimeObserver() {
        // Assumes timeObserverToken is already nil. Do not remove here.
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self, !self.isScrubbing else { return }
            let elapsed = time.seconds - self.clipStartTime
            self.progress = max(0, min(1, elapsed / self.clipDuration))
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
        if shuffledVideos.isEmpty { return }
        ServerAuth.prewarm(address: serverAddress, videoIDs: shuffledVideos.prefix(5).map { $0.id })
        playClip()
    }

    func playClip(isRetry: Bool = false) {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        
        if shuffledVideos.isEmpty { return }
        if !isRetry { clipRetry = 0 }
        
        if index >= shuffledVideos.count {
            shuffledVideos.shuffle()
            index = 0
        }
        
        let v = shuffledVideos[index]
        currentVideo = v
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else { return }

        isLoading = true
        let startTarget: Double
        let oldPlayer = self.player
        
        if let nextP = nextPlayer, (nextP.currentItem?.asset as? AVURLAsset)?.url == url {
            self.player = nextP
            startTarget = nextClipStartTime
            self.nextPlayer = nil
        } else {
            self.player = AVPlayer(url: url)
            let dur = v.duration
            startTarget = dur > self.clipDuration ? Double.random(in: 0...(dur - self.clipDuration)) : 0
        }
        
        if oldPlayer !== self.player {
            if let token = timeObserverToken {
                oldPlayer.removeTimeObserver(token)
                timeObserverToken = nil
            }
            oldPlayer.pause()
            oldPlayer.replaceCurrentItem(with: nil)
            setupTimeObserver()
        }
        
        self.clipStartTime = startTarget
        guard let item = self.player.currentItem else { return }

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
        
        // --- Preload next video ---
        let nextIndex = (index + 1) % shuffledVideos.count
        if nextIndex < shuffledVideos.count && nextIndex != index {
            let nextV = shuffledVideos[nextIndex]
            if let nextUrl = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(nextV.id)") {
                let nPlayer = AVPlayer(url: nextUrl)
                self.nextPlayer = nPlayer
                
                let nextDur = nextV.duration
                self.nextClipStartTime = nextDur > self.clipDuration ? Double.random(in: 0...(nextDur - self.clipDuration)) : 0
                nPlayer.seek(to: CMTime(seconds: self.nextClipStartTime, preferredTimescale: 600))
            }
        }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.clipDuration ?? 60) * 1_000_000_000)
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
        progress = percent
        let targetSeconds = clipStartTime + (clipDuration * percent)
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600)) { [weak self] _ in
            self?.scheduleAdvance()
        }
    }
}

struct RemoteShortsPlayerView: View {
    @StateObject private var model: RemoteShortsModel
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: RemoteVideoInfo? = nil
    
    let allServerAlbums: [RemoteAlbumInfo]

    init(videos: [RemoteVideoInfo], serverAddress: String, allServerAlbums: [RemoteAlbumInfo]) {
        _model = StateObject(wrappedValue: RemoteShortsModel(videos: videos, serverAddress: serverAddress))
        self.allServerAlbums = allServerAlbums
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.currentVideo == nil {
                ProgressView().tint(.white)
            } else {
                // Video Layer
                PlayerLayerView(player: model.player)
                    .ignoresSafeArea()
                    .onTapGesture {
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

                // Overlay Controls
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.down")
                                .font(.title3.weight(.bold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.4).clipShape(Circle()))
                        }
                        Spacer()
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)

                    Spacer()

                    HStack(alignment: .bottom) {
                        // Left: Info
                        VStack(alignment: .leading, spacing: 8) {
                            if let v = model.currentVideo {
                                Text(v.filename)
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
                        
                        // Right: Actions
                        VStack(spacing: 24) {
                            if let v = model.currentVideo {
                                // Like Button
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
                                
                                // Jump to Full Video
                                Button(action: {
                                    model.pause()
                                    jumpToFullVideo = v
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
                                
                                // Info Button
                                Button(action: {
                                    model.pause()
                                    showInfoSheet = true
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .font(.title)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                        Text("詳細")
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
                    

                    // Seek Bar
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer()
                            Rectangle()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 6)
                                .overlay(
                                    Rectangle()
                                        .fill(Color.white)
                                        .frame(width: geo.size.width * CGFloat(model.progress), height: 6),
                                    alignment: .leading
                                )
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    model.isScrubbing = true
                                    let percent = max(0, min(1, value.location.x / geo.size.width))
                                    model.progress = percent
                                }
                                .onEnded { value in
                                    let percent = max(0, min(1, value.location.x / geo.size.width))
                                    model.seek(to: percent)
                                    model.isScrubbing = false
                                }
                        )
                    }
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        // Vertical swipe to change video
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height < -50 {
                        // Swipe up -> next
                        model.next()
                    } else if value.translation.height > 50 {
                        // Swipe down -> previous
                        model.previous()
                    }
                }
        )
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.shutdown()
        }
        // Sheet for details
        .sheet(isPresented: $showInfoSheet, onDismiss: { if !model.isPlaying { model.togglePlay() } }) {
            if let v = model.currentVideo {
                VideoInfoSheetView(video: v, serverAddress: model.serverAddress, downloadManager: DownloadManager())
            }
        }
        // Fullscreen for jump to original
        .fullScreenCover(item: $jumpToFullVideo, onDismiss: { if !model.isPlaying { model.togglePlay() } }) { v in
            NavigationStack {
                RemoteVideoListView(
                    serverName: allServerAlbums.first(where: { $0.id == v.parentAlbumID })?.name ?? "動画",
                    serverAddress: model.serverAddress,
                    albumID: v.parentAlbumID ?? "ALL VIDEOS",
                    allServerAlbums: allServerAlbums,
                    initialVideoToPlay: v,
                    isPresentedFromShorts: true
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("閉じる") {
                            jumpToFullVideo = nil
                        }
                        .foregroundColor(.appGold)
                    }
                }
            }
            .presentationBackground(.clear)
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
    @Published var progress: Double = 0.0

    private var clips: [ShortsFavoriteClip] = []
    private var allVideos: [RemoteVideoInfo] = []
    private var index = 0
    let serverAddress: String
    
    @Published private(set) var clipDuration: Double = 0
    @Published private(set) var clipStartTime: Double = 0
    private var timeObserverToken: Any?
    
    private var nextPlayer: AVPlayer?
    private var advanceTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?

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
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self else { return }
            let elapsed = time.seconds - self.clipStartTime
            if self.clipDuration > 0 {
                self.progress = max(0, min(1, elapsed / self.clipDuration))
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
        
        currentVideo = v
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else { return }

        isLoading = true
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
        
        guard let item = self.player.currentItem else { return }

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
        advanceTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.clipDuration * 1_000_000_000))
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
        let targetSec = clipStartTime + (clipDuration * percent)
        player.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600))
    }
}

// MARK: - お気に入りショート用プレイヤービュー
struct RemoteShortsFavoritesPlayerView: View {
    @StateObject private var model: RemoteShortsFavoritesModel
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: RemoteVideoInfo? = nil
    
    let allServerAlbums: [RemoteAlbumInfo]

    init(videos: [RemoteVideoInfo], serverAddress: String, allServerAlbums: [RemoteAlbumInfo], initialIndex: Int = 0) {
        _model = StateObject(wrappedValue: RemoteShortsFavoritesModel(videos: videos, serverAddress: serverAddress, initialIndex: initialIndex))
        self.allServerAlbums = allServerAlbums
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
                // Video Layer
                PlayerLayerView(player: model.player)
                    .ignoresSafeArea()
                    .onTapGesture {
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

                // Overlay Controls
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.down")
                                .font(.title3.weight(.bold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.4).clipShape(Circle()))
                        }
                        Spacer()
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)

                    Spacer()

                    HStack(alignment: .bottom) {
                        // Left: Info
                        VStack(alignment: .leading, spacing: 8) {
                            if let v = model.currentVideo {
                                Text(v.filename)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .shadow(radius: 2)
                            }
                        }
                        
                        Spacer()
                        
                        // Right: Actions
                        VStack(spacing: 24) {
                            if let v = model.currentVideo {
                                // Like Button
                                Button(action: {
                                    Haptics.light()
                                    let isShortsFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                    if isShortsFav {
                                        if let clipId = shortsFavorites.getClipId(videoID: v.id, startTime: model.clipStartTime) {
                                            shortsFavorites.removeClip(id: clipId)
                                            if shortsFavorites.clips.isEmpty {
                                                dismiss()
                                            }
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
                    
                    // Seek Bar
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer()
                            Rectangle()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 6)
                                .overlay(
                                    Rectangle()
                                        .fill(Color.white)
                                        .frame(width: geo.size.width * CGFloat(model.progress), height: 6),
                                    alignment: .leading
                                )
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let percent = max(0, min(1, value.location.x / geo.size.width))
                                    model.progress = percent
                                }
                                .onEnded { value in
                                    let percent = max(0, min(1, value.location.x / geo.size.width))
                                    model.seek(to: percent)
                                }
                        )
                    }
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        // Vertical swipe to change video
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height < -50 {
                        // Swipe up -> next
                        model.next()
                    } else if value.translation.height > 50 {
                        // Swipe down -> previous
                        model.previous()
                    }
                }
        )
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
    }
}
