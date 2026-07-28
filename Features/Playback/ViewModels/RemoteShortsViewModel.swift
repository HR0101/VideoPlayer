import SwiftUI
import AVKit
import MediaServerKit

@MainActor
final class RemoteShortsViewModel: ObservableObject {
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
