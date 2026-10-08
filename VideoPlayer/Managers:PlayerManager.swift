//
//  Managers:PlayerManager.swift
//  VideoPlayer
//
//  Created by hara ryuto   on 2025/06/20.
//

import SwiftUI
import AVKit

// MARK: - Player Manager
/// AVPlayerのインスタンスを管理し、再生状態を監視するクラス
class PlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isReadyToPlay: Bool = false
    
    private var playerStatusObserver: NSKeyValueObservation?

    /// 指定されたURLのビデオを非同期で準備する
    func setupPlayer(with url: URL) {
        isReadyToPlay = false
        let asset = AVAsset(url: url)
        
        // 再生可能かどうかを非同期でロード
        asset.loadValuesAsynchronously(forKeys: ["playable"]) { [weak self] in
            guard let self = self else { return }
            
            var error: NSError? = nil
            let status = asset.statusOfValue(forKey: "playable", error: &error)
            
            DispatchQueue.main.async {
                if status == .loaded {
                    let playerItem = AVPlayerItem(asset: asset)
                    self.player = AVPlayer(playerItem: playerItem)
                    
                    // プレーヤーのステータスを監視
                    self.playerStatusObserver = self.player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                        if item.status == .readyToPlay {
                            self?.isReadyToPlay = true
                        }
                    }
                } else {
                    print("ビデオアセットの読み込みに失敗しました: \(error?.localizedDescription ?? "不明なエラー")")
                    self.player = nil
                }
            }
        }
    }

    /// プレーヤーとオブザーバーをクリーンアップする
    func shutdown() {
        player?.pause()
        player = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil
        isReadyToPlay = false
    }
}
