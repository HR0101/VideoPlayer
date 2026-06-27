import SwiftUI
import AVKit
import MediaServerKit
import Vision

struct VideoAnalyzer {
    static func analyzeCenter(item: AVPlayerItem) async -> CGPoint? {
        guard let asset = item.asset as? AVURLAsset else { return nil }
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 300, height: 300)
        
        do {
            let seconds = item.duration.isValid && item.duration.isNumeric ? min(1.0, item.duration.seconds / 2.0) : 0.5
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let (cgImage, _) = try await imageGenerator.image(at: time)
            
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            
            if let results = request.results, !results.isEmpty {
                if let brightest = results.max(by: { averageBrightness(of: $0.boundingBox, in: cgImage) < averageBrightness(of: $1.boundingBox, in: cgImage) }) {
                    let x = brightest.boundingBox.midX
                    let y = 1.0 - brightest.boundingBox.midY
                    return CGPoint(x: x, y: y)
                }
            }
            
            let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
            try handler.perform([saliencyRequest])
            
            if let results = saliencyRequest.results, let first = results.first, let objects = first.salientObjects, !objects.isEmpty {
                if let brightest = objects.max(by: { averageBrightness(of: $0.boundingBox, in: cgImage) < averageBrightness(of: $1.boundingBox, in: cgImage) }) {
                    let x = brightest.boundingBox.midX
                    let y = 1.0 - brightest.boundingBox.midY
                    return CGPoint(x: x, y: y)
                }
            }
            
            return nil
        } catch {
            return nil
        }
    }
    
    private static func averageBrightness(of normalizedRect: CGRect, in image: CGImage) -> Double {
        let x = normalizedRect.origin.x * CGFloat(image.width)
        // normalized Y in Vision is bottom-left origin
        let y = (1.0 - normalizedRect.origin.y - normalizedRect.height) * CGFloat(image.height)
        let width = normalizedRect.width * CGFloat(image.width)
        let height = normalizedRect.height * CGFloat(image.height)
        
        let cropRect = CGRect(x: x, y: y, width: width, height: height)
        guard let cropped = image.cropping(to: cropRect) else { return 0 }
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bitmap,
                                width: 1,
                                height: 1,
                                bitsPerComponent: 8,
                                bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        context?.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        
        let r = Double(bitmap[0])
        let g = Double(bitmap[1])
        let b = Double(bitmap[2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

struct SmartVideoPanView: View {
    let player: AVPlayer
    let videoSize: CGSize
    let focusCenter: CGPoint?
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
                
                let maxOffsetX = max(0, (geo.size.width * finalScale - geo.size.width) / 2)
                let focusX = focusCenter?.x ?? 0.5
                let targetOffsetX = (0.5 - focusX) * (geo.size.width * finalScale)
                let clampedOffsetX = min(max(targetOffsetX, -maxOffsetX), maxOffsetX)
                
                PlayerLayerView(player: player, videoGravity: .resizeAspect)
                    .scaleEffect(finalScale)
                    .offset(x: clampedOffsetX, y: 0)
                    .animation(.easeInOut(duration: 0.8), value: focusCenter)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            PlayerLayerView(player: player, videoGravity: .resizeAspect)
        }
    }
}

// MARK: - スライドショー（サーバーの複数動画を指定秒ずつ連続再生）

@MainActor
final class RemoteSlideshowModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var index = 0
    @Published var isPlaying = true
    @Published var isLoading = false
    @Published var videoFocusCenter: CGPoint? = nil
    @Published var videoSize: CGSize = .zero

    var videos: [RemoteVideoInfo] = []
    var serverAddress: String = ""
    private var clipDuration: Double = 15
    private var advanceTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    /// 同一クリップの読み込み失敗時のリトライ回数
    private var clipRetry = 0
    private let maxClipRetry = 3

    var currentTitle: String { videos.indices.contains(index) ? videos[index].filename.cleanVideoTitle : "" }

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
                self.videoSize = observedItem.presentationSize
                Task {
                    if let center = await VideoAnalyzer.analyzeCenter(item: observedItem) {
                        await MainActor.run { self.videoFocusCenter = center }
                    } else {
                        await MainActor.run { self.videoFocusCenter = CGPoint(x: 0.5, y: 0.5) }
                    }
                }
                
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
    @EnvironmentObject var appSettings: AppSettings
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
            SmartVideoPanView(player: model.player, videoSize: model.videoSize, focusCenter: model.videoFocusCenter, scaleParam: appSettings.shortsVideoFillScale)
                .ignoresSafeArea()

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
    @Published var videoFocusCenter: CGPoint? = nil
    @Published var videoSize: CGSize = .zero

    private var shuffledVideos: [RemoteVideoInfo] = []
    private var index = 0
    let serverAddress: String
    let clipDuration: Double = 60 // 1分
    @Published private(set) var clipStartTime: Double = 0
    private var timeObserverToken: Any?
    
    private var nextPlayer: AVPlayer?
    private var nextClipStartTime: Double = 0
    private var pendingInitialStartTime: Double?
    private let requestedInitialVideo: RemoteVideoInfo?
    private let requestedInitialVideoID: String?
    private var didResolveInitialVideo = false
    private var didStart = false
    private let minimumRemainingDuration: Double = 1.0
    
    private var advanceTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var clipRetry = 0
    private let maxClipRetry = 3

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
        
        if shuffledVideos.isEmpty { return }
        if !isRetry { clipRetry = 0 }
        
        if index >= shuffledVideos.count {
            shuffledVideos.shuffle()
            index = 0
        }
        forceRequestedInitialVideoIfNeeded()
        
        let v = shuffledVideos[index]
        currentVideo = v
        #if DEBUG
        if let requestedInitialVideoID {
            print("ShortsPlay requestedID=\(requestedInitialVideoID) currentID=\(v.id) title=\(v.filename)")
        }
        #endif
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else { return }

        isLoading = true
        let startTarget: Double
        let oldPlayer = self.player
        let requestedStartTime = isRetry ? nil : pendingInitialStartTime
        if requestedStartTime != nil {
            pendingInitialStartTime = nil
        }
        
        if let nextP = nextPlayer, requestedStartTime == nil, (nextP.currentItem?.asset as? AVURLAsset)?.url == url {
            self.player = nextP
            startTarget = nextClipStartTime
            self.nextPlayer = nil
        } else {
            self.player = AVPlayer(url: url)
            let dur = v.duration
            if let requestedStartTime {
                startTarget = clampedClipStartTime(requestedStartTime, duration: dur)
            } else if isRetry {
                startTarget = clipStartTime
            } else {
                startTarget = dur > self.clipDuration ? Double.random(in: 0...(dur - self.clipDuration)) : 0
            }
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
        
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        
        self.clipStartTime = startTarget
        guard let item = self.player.currentItem else { return }
        
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
                self.isLoading = false
                self.videoSize = observedItem.presentationSize
                Task {
                    if let center = await VideoAnalyzer.analyzeCenter(item: observedItem) {
                        await MainActor.run { self.videoFocusCenter = center }
                    } else {
                        await MainActor.run { self.videoFocusCenter = CGPoint(x: 0.5, y: 0.5) }
                    }
                }
                
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
                // Video Layer
                SmartVideoPanView(player: model.player, videoSize: model.videoSize, focusCenter: model.videoFocusCenter, scaleParam: appSettings.shortsVideoFillScale)
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
                    Group {
                        HStack {
                            Button(action: {
                                model.pause()
                                if navState.selectedTab == 1 {
                                    navState.selectedTab = 0 // Return to Home Tab
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
                            if let _ = model.currentVideo {
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
                            // Left: Info
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
        .toolbar(model.isPlaying ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.isPlaying) { _, isPlaying in
            onPlayStateChanged?(isPlaying)
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
}

// MARK: - お気に入りショート用プレイヤーモデル
@MainActor
final class RemoteShortsFavoritesModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var currentVideo: RemoteVideoInfo?
    @Published var isLoading = false
    @Published var isPlaying = true
    @Published var progress: Double = 0.0
    @Published var videoFocusCenter: CGPoint? = nil
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
                self.videoSize = observedItem.presentationSize
                Task {
                    if let center = await VideoAnalyzer.analyzeCenter(item: observedItem) {
                        await MainActor.run { self.videoFocusCenter = center }
                    } else {
                        await MainActor.run { self.videoFocusCenter = CGPoint(x: 0.5, y: 0.5) }
                    }
                }
                
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
    @EnvironmentObject var appSettings: AppSettings
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: RemoteVideoInfo? = nil
    
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
                // Video Layer
                SmartVideoPanView(player: model.player, videoSize: model.videoSize, focusCenter: model.videoFocusCenter, scaleParam: appSettings.shortsVideoFillScale)
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
                            // Left: Info
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
                    }
                    .opacity(model.isPlaying ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: model.isPlaying)
                    
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
        .toolbar(model.isPlaying ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.isPlaying) { _, isPlaying in
            onPlayStateChanged?(isPlaying)
        }
    }
}
