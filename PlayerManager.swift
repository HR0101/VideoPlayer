import AVKit
import Combine

// ===================================
//  PlayerManager.swift (シームレス画質変更 + 連続再生/シークバー対応版)
// ===================================
// 安定したビデオ再生を実現するための、プレイヤー管理クラスです。

@MainActor
final class PlayerManager: ObservableObject {
    @Published var player = AVPlayer()
    @Published var isPlaying = false
    @Published var isReadyToPlay = false

    // ★ シークバー用の再生位置・長さ (秒)
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    // ★ 動画が最後まで再生されたときに呼ばれる
    var onEnded: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    init(videoURL: URL) {
        addPeriodicObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onEnded?() }
        }
        setupPlayer(with: videoURL)
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

    private func setupPlayer(with url: URL) {
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let isPlayable = try await asset.load(.isPlayable)

                if isPlayable {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: playerItem)

                    player.publisher(for: \.rate)
                        .map { $0 > 0 }
                        .assign(to: \.isPlaying, on: self)
                        .store(in: &cancellables)

                    self.isReadyToPlay = true
                    player.play()
                }
            } catch {
                print("Error loading video asset: \(error)")
            }
        }
    }

    // ★ 画質切り替え時、現在の再生位置を保ったままURLを変更する
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

                    // 正確に元の時間へシークする
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

    // ★ 別の動画へ完全に切り替える (startAt 秒から再生 / 既定は先頭)
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

    // ★ シークバーから指定秒へ移動
    func seek(toSeconds seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // ★ 先頭へ戻して再生 (リピート1曲用)
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
