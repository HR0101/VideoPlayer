import SwiftUI
import AVKit
import UIKit

// MARK: - AVPlayerLayer の素のサーフェス（OS標準コントロールなし）
// カスタムコントロールを重ねるためのプレイヤー表示ビュー
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    final class PlayerContainerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
}

struct CustomVideoPlayerContainer: View {
    let videoURL: URL
    @StateObject private var playerManager: PlayerManager

    init(videoURL: URL) {
        self.videoURL = videoURL
        _playerManager = StateObject(wrappedValue: PlayerManager(videoURL: videoURL))
    }

    var body: some View {
        ZStack {
            Color.black

            if playerManager.isReadyToPlay {
                VideoPlayer(player: playerManager.player)
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onDisappear {
            playerManager.shutdown()
        }
    }
}
