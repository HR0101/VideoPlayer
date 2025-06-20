// ===================================
//  CustomVideoPlayerContainer.swift
// ===================================
// 安定化されたPlayerManagerを使い、再生準備が整うまでインジケーターを表示します。

import SwiftUI
import AVKit

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
