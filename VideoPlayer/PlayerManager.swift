import AVKit
import Combine

// ===================================
//  PlayerManager.swift
// ===================================
// 安定したビデオ再生を実現するための、プレイヤー管理クラスです。

@MainActor
final class PlayerManager: ObservableObject {
    @Published var player = AVPlayer()
    @Published var isPlaying = false
    @Published var isReadyToPlay = false
    private var cancellables = Set<AnyCancellable>()

    init(videoURL: URL) {
        setupPlayer(with: videoURL)
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

    func shutdown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
