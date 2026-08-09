import SwiftUI
import AVKit
import MediaServerKit

@MainActor
final class RemoteShortsFavoritesViewModel: ObservableObject {
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
