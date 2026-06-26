import SwiftUI
import AVKit
import Combine
import MediaServerKit

// MARK: - 同時同期再生（サーバーの動画を最大9本グリッドで同期再生）

@MainActor
final class RemoteMultiPlayerModel: ObservableObject {
    @Published var players: [AVPlayer] = []
    @Published var commonCurrentTime: Double = 0
    @Published var commonDuration: Double = 1
    @Published var isMuted = true
    @Published var isPlaying = false

    private var leadPlayer: AVPlayer?
    private var leadObserver: Any?
    private var isScrubbing = false
    /// 各プレイヤーのアイテム読み込み状態を監視（index をキーに保持し、再作成時に差し替える）
    private var itemObservers: [Int: NSKeyValueObservation] = [:]
    /// 失敗時のリトライ回数（index ごと）
    private var retryCounts: [Int: Int] = [:]
    private let maxRetries = 3
    /// ユーザーの再生意図。準備が整ったプレイヤーはこの意図に従って自動再生する
    private var shouldBePlaying = true
    /// リトライ用に各プレイヤーの URL を保持
    private var urlsByIndex: [Int: URL] = [:]

    func setup(urls: [URL], leadIndex: Int) {
        // 既に setup 済みなら二重初期化しない
        guard players.isEmpty else { return }

        let newPlayers = urls.map { url -> AVPlayer in
            let p = AVPlayer(playerItem: AVPlayerItem(url: url))
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = true
            return p
        }
        players = newPlayers
        let lead = players.indices.contains(leadIndex) ? players[leadIndex] : players.first
        self.leadPlayer = lead

        // 固定遅延で一律 play せず、各プレイヤーの読み込み完了を待ってから再生する。
        // 失敗（コールドHDDへの初回アクセス等）した場合はアイテムを作り直してリトライする。
        for (i, p) in players.enumerated() {
            urlsByIndex[i] = urls[i]
            observeItem(of: p, at: i)
        }

        guard let lead else { return }
        leadObserver = lead.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self, !self.isScrubbing else { return }
            DispatchQueue.main.async {
                self.commonCurrentTime = t.seconds.isFinite ? t.seconds : 0
                if let d = lead.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.commonDuration = d
                }
                self.isPlaying = self.players.contains { $0.rate > 0 }
            }
        }
    }

    /// 指定プレイヤーの currentItem の status を監視し、準備完了で再生・失敗でリトライする
    private func observeItem(of player: AVPlayer, at index: Int) {
        guard let item = player.currentItem else { return }
        itemObservers[index]?.invalidate()
        itemObservers[index] = item.observe(\.status, options: [.new]) { [weak self, weak player] observedItem, _ in
            guard let self, let player else { return }
            Task { @MainActor in
                switch observedItem.status {
                case .readyToPlay:
                    self.retryCounts[index] = 0
                    if self.shouldBePlaying { player.play() }
                case .failed:
                    let n = (self.retryCounts[index] ?? 0) + 1
                    self.retryCounts[index] = n
                    guard n <= self.maxRetries, let url = self.urlsByIndex[index] else { return }
                    // 少し待ってからアイテムを作り直して再試行（HDDのスピンアップ完了を待つ）
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard self.players.indices.contains(index) else { return }
                    let fresh = AVPlayerItem(url: url)
                    player.replaceCurrentItem(with: fresh)
                    self.observeItem(of: player, at: index)
                default:
                    break
                }
            }
        }
    }

    func playAll() {
        shouldBePlaying = true
        players.forEach { $0.play() }
        isPlaying = true
    }

    func togglePlay() {
        if players.contains(where: { $0.rate > 0 }) {
            shouldBePlaying = false
            players.forEach { $0.pause() }
            isPlaying = false
        } else {
            shouldBePlaying = true
            players.forEach { $0.play() }
            isPlaying = true
        }
    }

    func seekAll(by s: Double) {
        for p in players {
            let cur = p.currentTime().seconds
            let dur = p.currentItem?.duration.seconds ?? .infinity
            let target = min(max(0, cur + s), dur.isFinite ? dur : cur + s)
            p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func seekAll(toPct pct: Double) {
        for p in players {
            guard let d = p.currentItem?.duration.seconds, d > 0 else { continue }
            p.seek(to: CMTime(seconds: d * pct, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func randomSeek() {
        let shortest = players.compactMap { $0.currentItem?.duration.seconds }.filter { $0 > 0 }.min() ?? 0
        guard shortest > 0 else { return }
        let ct = CMTime(seconds: Double.random(in: 0..<shortest), preferredTimescale: 600)
        players.forEach { $0.seek(to: ct, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    func toggleMute() {
        isMuted.toggle()
        players.forEach { $0.isMuted = isMuted }
    }

    func beginScrub() { isScrubbing = true }
    func endScrub() {
        isScrubbing = false
        if commonDuration > 0 { seekAll(toPct: commonCurrentTime / commonDuration) }
    }

    func shutdown() {
        if let o = leadObserver, let lp = leadPlayer { lp.removeTimeObserver(o) }
        leadObserver = nil
        leadPlayer = nil
        itemObservers.values.forEach { $0.invalidate() }
        itemObservers.removeAll()
        retryCounts.removeAll()
        urlsByIndex.removeAll()
        players.forEach { $0.pause(); $0.replaceCurrentItem(with: nil) }
        players = []
    }
}

struct RemoteMultiPlayerView: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RemoteMultiPlayerModel()
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    private var columns: Int { model.players.count <= 1 ? 1 : (model.players.count <= 4 ? 2 : 3) }
    private var rows: [[AVPlayer]] {
        let players = model.players
        guard !players.isEmpty else { return [] }
        return stride(from: 0, to: players.count, by: columns).map { Array(players[$0..<min($0 + columns, players.count)]) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.players.isEmpty {
                ProgressView("読み込み中...")
                    .tint(.white)
                    .foregroundColor(.white)
            } else {
                VStack(spacing: showControls ? 3 : 0) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: showControls ? 3 : 0) {
                            ForEach(rows[r].indices, id: \.self) { c in
                                PlayerLayerView(player: rows[r][c])
                                    .clipShape(RoundedRectangle(cornerRadius: showControls ? 8 : 0))
                                    .overlay(RoundedRectangle(cornerRadius: showControls ? 8 : 0).stroke(Color.white.opacity(showControls ? 0.15 : 0), lineWidth: 0.5))
                            }
                        }
                    }
                }
                .padding(showControls ? 3 : 0)
                .padding(.bottom, showControls ? 96 : 0)
                .animation(.easeInOut, value: showControls)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding()
                }
                Spacer()
                controls
            }
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut, value: showControls)
            .allowsHitTesting(showControls)
        }
        .statusBarHidden(true)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { showControls.toggle() }
            if showControls { resetHideTimer() } else { hideTask?.cancel() }
        }
        .onAppear {
            let vids = Array(videos.prefix(9))
            // HDDのスピンアップ等を先に済ませてから再生を仕込む（コールド状態での再生開始失敗対策）
            ServerAuth.prewarm(address: serverAddress, videoIDs: vids.map { $0.id })
            let urls = vids.compactMap { ServerAuth.mediaURL(address: serverAddress, path: "/video/\($0.id)") }
            let leadIndex = vids.enumerated().max(by: { $0.element.duration < $1.element.duration })?.offset ?? 0
            model.setup(urls: urls, leadIndex: leadIndex)
            // 再生意図をセット。各プレイヤーは準備が整い次第この意図に従って自動再生する
            model.playAll()
            resetHideTimer()
        }
        .onDisappear { 
            model.shutdown() 
            hideTask?.cancel()
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

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(timeStr(model.commonCurrentTime)).font(.caption.monospacedDigit()).foregroundColor(.white)
                Slider(value: $model.commonCurrentTime, in: 0...max(model.commonDuration, 0.1), onEditingChanged: { editing in
                    editing ? model.beginScrub() : model.endScrub()
                })
                .tint(.white)
                Text(timeStr(model.commonDuration)).font(.caption.monospacedDigit()).foregroundColor(.white)
            }
            HStack(spacing: 20) {
                ctlButton("gobackward.10") { model.seekAll(by: -10) }
                ctlButton(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                ctlButton("goforward.10") { model.seekAll(by: 10) }
                ctlButton("shuffle") { model.randomSeek() }
                ctlButton(model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { model.toggleMute() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func ctlButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).foregroundColor(.white).frame(width: 44, height: 44)
        }
    }

    private func timeStr(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
