import SwiftUI
import AVKit
import MediaServerKit

// MARK: - スライドショー（サーバーの複数動画を指定秒ずつ連続再生）

@MainActor
final class RemoteSlideshowModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var index = 0
    @Published var isPlaying = true
    @Published var isLoading = false

    var videos: [RemoteVideoInfo] = []
    var serverAddress: String = ""
    private var clipDuration: Double = 15
    private var advanceTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    /// 同一クリップの読み込み失敗時のリトライ回数
    private var clipRetry = 0
    private let maxClipRetry = 3

    var currentTitle: String { videos.indices.contains(index) ? videos[index].filename : "" }

    func setup(videos: [RemoteVideoInfo], serverAddress: String) {
        self.videos = videos
        self.serverAddress = serverAddress
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.next() }
        }
    }

    func start(clip: Double) {
        clipDuration = clip
        index = 0
        // HDDのスピンアップ等を先に済ませる（コールド状態での再生開始失敗対策）
        ServerAuth.prewarm(address: serverAddress, videoIDs: videos.map { $0.id })
        playClip()
    }

    /// isRetry=true の場合は同じ index を読み直す（リトライ回数はリセットしない）
    func playClip(isRetry: Bool = false) {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        guard !videos.isEmpty else { return }
        if !isRetry { clipRetry = 0 }
        if index < 0 { index = videos.count - 1 }
        if index >= videos.count { index = 0 }

        let v = videos[index]
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(v.id)") else { return }

        isLoading = true
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // ステータスを監視して readyToPlay になってからシーク＆再生
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard observedItem.status == .readyToPlay else {
                    if observedItem.status == .failed {
                        // コールドHDDへの初回アクセス失敗等を考慮し、即スキップせず同じクリップをリトライする
                        if self.clipRetry < self.maxClipRetry {
                            self.clipRetry += 1
                            self.advanceTask = Task {
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                if !Task.isCancelled { await MainActor.run { self.playClip(isRetry: true) } }
                            }
                        } else {
                            self.isLoading = false
                            self.clipRetry = 0
                            // リトライしても駄目なら次のクリップへ
                            self.advanceTask = Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { await MainActor.run { self.next() } }
                            }
                        }
                    }
                    return
                }
                self.clipRetry = 0
                self.isLoading = false
                let dur = v.duration
                let start = dur > self.clipDuration ? Double.random(in: 0...(dur - self.clipDuration)) : 0
                self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in
                    DispatchQueue.main.async {
                        self.player.play()
                        self.isPlaying = true
                        self.scheduleAdvance()
                    }
                }
            }
        }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        let secs = clipDuration
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.next() }
        }
    }

    func next() { index += 1; playClip() }
    func prev() { index -= 1; playClip() }

    func togglePlay() {
        if player.rate > 0 {
            player.pause(); isPlaying = false; advanceTask?.cancel()
        } else {
            player.play(); isPlaying = true; scheduleAdvance()
        }
    }

    func shutdown() {
        advanceTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct RemoteSlideshowPlayerView: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RemoteSlideshowModel()

    private enum Phase { case setup, playing }
    @State private var phase: Phase = .setup
    @State private var clip: Double = 15

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .setup: setupView
            case .playing: playerView
            }
        }
        .statusBarHidden(true)
        .onAppear {
            model.setup(videos: videos, serverAddress: serverAddress)
        }
        .onDisappear { model.shutdown() }
    }

    private var setupView: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.square.stack.fill").font(.system(size: 44)).foregroundColor(.white)
            Text("スライドショー").font(.title2.bold()).foregroundColor(.white)
            Text("\(videos.count)本の動画から各クリップを切り出して連続再生します")
                .font(.callout).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)

            VStack(spacing: 8) {
                HStack {
                    Text("1クリップの長さ").foregroundColor(.white)
                    Spacer()
                    Text("\(Int(clip))秒").foregroundColor(.white).monospacedDigit()
                }
                Slider(value: $clip, in: 1...60, step: 1).tint(.white)
            }
            .frame(maxWidth: 340)

            HStack(spacing: 16) {
                Button("キャンセル") { dismiss() }.foregroundColor(.white)
                Button("開始") { phase = .playing; model.start(clip: clip) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
    }

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    private var playerView: some View {
        ZStack {
            PlayerLayerView(player: model.player).ignoresSafeArea()

            if model.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }

            VStack {
                HStack {
                    Text("\(model.index + 1) / \(videos.count)   \(model.currentTitle)")
                        .lineLimit(1).font(.subheadline.bold()).foregroundColor(.white).shadow(radius: 3)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding()

                Spacer()

                HStack(spacing: 30) {
                    btn("backward.end.fill") { model.prev() }
                    btn(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                    btn("forward.end.fill") { model.next() }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 30)
            }
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut, value: showControls)
            .allowsHitTesting(showControls)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { showControls.toggle() }
            if showControls { resetHideTimer() } else { hideTask?.cancel() }
        }
        .onAppear {
            resetHideTimer()
        }
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { showControls = false }
            }
        }
    }

    private func btn(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title).foregroundColor(.white).frame(width: 50, height: 50)
        }
    }
}
