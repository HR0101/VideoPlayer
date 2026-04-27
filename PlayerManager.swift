import AVKit
import Combine



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
    
    // 画質切り替え時、現在の再生位置を保ったままURLを変更する
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

    func changeVideo(to newURL: URL) {
        Task {
            do {
                let asset = AVURLAsset(url: newURL)
                let isPlayable = try await asset.load(.isPlayable)
                if isPlayable {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: playerItem)
                    self.player.play() 
                }
            } catch {
                print("Error changing video: \(error)")
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
