import AVKit
import Combine

@MainActor
final class PlayerManager: ObservableObject {
    @Published var player = AVPlayer()
    @Published var isPlaying = false
    @Published var isReadyToPlay = false

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    var onEnded: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    init(videoURL: URL, startAt: Double = 0) {
        addPeriodicObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let endedItem = notification.object as? AVPlayerItem,
                  endedItem === self.player.currentItem else { return }
            Task { @MainActor in self.onEnded?() }
        }
        setupPlayer(with: videoURL, startAt: startAt)
    }

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let dur = self.player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
            }
        }
    }

    private func setupPlayer(with url: URL, startAt: Double = 0) {
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let isPlayable = try await asset.load(.isPlayable)

                if isPlayable {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: playerItem)
                    if startAt > 0 {
                        let target = CMTime(seconds: startAt, preferredTimescale: 600)
                        await self.player.seek(to: target)
                    }

                    player.publisher(for: \.rate)
                        .map { $0 > 0 }
                        .sink { [weak self] playing in self?.isPlaying = playing }
                        .store(in: &cancellables)

                    self.isReadyToPlay = true
                    player.play()
                }
            } catch {
                print("Error loading video asset: \(error)")
            }
        }
    }

    func changeQuality(to newURL: URL) {
        let currentTime = player.currentTime()
        let wasPlaying = isPlaying

        Task {
            do {
                let asset = AVURLAsset(url: newURL)
                let isPlayable = try await asset.load(.isPlayable)
                if isPlayable {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: playerItem)

                    await self.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)

                    if wasPlaying {
                        self.player.play()
                    }
                }
            } catch {
                print("Error changing quality: \(error)")
            }
        }
    }

    func changeVideo(to newURL: URL, startAt: Double = 0) {
        isReadyToPlay = false
        currentTime = 0
        duration = 0
        Task {
            do {
                let asset = AVURLAsset(url: newURL)
                let isPlayable = try await asset.load(.isPlayable)
                if isPlayable {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: playerItem)
                    let target = CMTime(seconds: max(0, startAt), preferredTimescale: 600)
                    await self.player.seek(to: target)
                    self.isReadyToPlay = true
                    self.player.play()
                }
            } catch {
                print("Error changing video: \(error)")
            }
        }
    }

    func seek(toSeconds seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func restart() {
        player.seek(to: .zero)
        player.play()
    }

    func shutdown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        onEnded = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
