import SwiftUI
import MediaServerKit
import AVKit

// MARK: - Home Feed AutoPlay Support

class FeedPlaybackManager {
    static let shared = FeedPlaybackManager()
    var times: [String: Double] = [:]
}

struct FeedVideoFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ShortsVideoFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct FeedInlinePlayerView: View {
    let video: RemoteVideoInfo
    let serverAddress: String
    let width: CGFloat
    let isOverlayActive: Bool
    var playbackKey: String? = nil

    @State private var player: AVPlayer?
    @State private var isReady: Bool = false
    @State private var endObserver: Any?
    @State private var timeObserverToken: Any?
    @AppStorage("feedVideoMuted") private var isMuted: Bool = false

    var body: some View {
        ZStack {
            Color.black
            if let p = player {
                PlayerLayerView(player: p, videoGravity: .resizeAspectFill)
                    .allowsHitTesting(false)
            }
            if !isReady {
                RemoteVideoThumbnailView(
                    thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)", query: [URLQueryItem(name: "original", value: "true")]),
                    duration: video.duration,
                    contentMode: .fill,
                    forceSquare: false
                )
            }

            if isReady {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            isMuted.toggle()
                        }) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onChange(of: isMuted) { _, muted in
            player?.isMuted = muted || isOverlayActive
        }
        .onChange(of: isOverlayActive) { _, active in
            player?.isMuted = isMuted || active
            // フルスクリーンのプレイヤー/ショートが前面にある間は、裏のクイックビュー再生を止める
            if active { player?.pause() } else if isReady { player?.play() }
        }
        .onChange(of: video.id) { _, _ in
            resetPlayer()
            setupPlayer()
        }
        .onDisappear {
            resetPlayer()
        }
    }

    private func setupPlayer() {
        resetPlayer()
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)") else { return }
        let p = AVPlayer(url: url)
        p.isMuted = isMuted || isOverlayActive

        let dur = video.duration
        // 真ん中に重みを置いたランダムな開始位置
        let fraction = (Double.random(in: 0...1) + Double.random(in: 0...1)) / 2.0
        let targetSec = max(0, min(dur, dur * fraction))
        let key = playbackKey ?? video.id
        FeedPlaybackManager.shared.times[key] = targetSec
        FeedPlaybackManager.shared.times[video.id] = targetSec

        self.player = p
        p.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600)) { _ in
            DispatchQueue.main.async {
                guard player === p else { return }
                // 前面にフルスクリーンの再生がある間は自動再生しない（裏で動かさない）
                if !isOverlayActive { p.play() }
                withAnimation(.easeInOut(duration: 0.3)) { isReady = true }
            }
        }

        timeObserverToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            FeedPlaybackManager.shared.times[key] = time.seconds
            FeedPlaybackManager.shared.times[video.id] = time.seconds
        }

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero)
            p.play()
        }
    }

    private func resetPlayer() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        if let token = timeObserverToken, let currentPlayer = player {
            currentPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isReady = false
    }
}
