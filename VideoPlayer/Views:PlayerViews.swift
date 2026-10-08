//
//  Views:PlayerViews.swift
//  VideoPlayer
//
//  Created by hara ryuto   on 2025/06/20.
//

import SwiftUI
import AVKit

// MARK: VideoPlayer Views
/// ビデオプレーヤーのコンテナビュー。ロード状態の管理とジェスチャーを担当する。
struct CustomVideoPlayerContainer: View {
    let videoURL: URL
    @StateObject private var playerManager = PlayerManager()
    @Environment(\.presentationMode) var presentationMode
    
    @State private var viewOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if playerManager.isReadyToPlay, let player = playerManager.player {
                PlayerView(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
            }
        }
        .onAppear { playerManager.setupPlayer(with: videoURL) }
        .onDisappear { playerManager.shutdown() }
        .offset(y: viewOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // 下方向へのドラッグのみを許可
                    if value.translation.height > 0 {
                        viewOffset = value.translation
                    }
                }
                .onEnded { value in
                    // 一定以上ドラッグされたら画面を閉じる
                    if value.translation.height > 100 {
                        presentationMode.wrappedValue.dismiss()
                    } else {
                        // ドラッグが不十分な場合は元の位置に戻す
                        withAnimation(.spring()) {
                            viewOffset = .zero
                        }
                    }
                }
        )
    }
}

/// AVPlayerViewControllerをSwiftUIにラップするビュー
struct PlayerView: UIViewControllerRepresentable {
    var player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}
