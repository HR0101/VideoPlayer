import AVKit
import Combine
import Foundation

// MARK: - 複数プレイヤーの完全同期（ネットワーク越し）
//
// 差分切り替え再生は、同じ尺の動画を全部走らせたまま「どれを見せるか」だけを差し替える。
// 個別に play() を呼ぶとデコードの準備ができた順にバラバラと動き出すので、
// 「全員が再生可能になるまで待つ → preroll → 共通のホストタイムを指定して一斉に setRate」
// という順で揃える。考え方は Mac 側の `SynchronizedPlayerGroup` と同じ。
//
// ネットワーク越しなのでローカル再生より条件が悪い。ここが Mac 版との違い:
//  - 開始前に「バッファが足りているか」(`isPlaybackLikelyToKeepUp`) まで見る。
//    `readyToPlay` だけで走らせると、その直後に止まってしまう。
//  - `automaticallyWaitsToMinimizeStalling` は切ってある（一斉スタートの前提）。
//    切ると自前で貯まるのを待つ必要があるので、上の確認がそのぶん重要になる。
//  - 本数ぶんの帯域とデコーダを同時に食う。iPhone では数本が限度なので、
//    呼び出し側で本数を絞ること。
@MainActor
final class SynchronizedRemotePlayerGroup {
    let players: [AVPlayer]

    /// いちばん長い動画を基準にした共通の現在位置／総尺。
    var onTimeUpdate: (@MainActor (Double) -> Void)?
    var onDurationUpdate: (@MainActor (Double) -> Void)?
    var onPlayToEnd: (@MainActor () -> Void)?
    /// 走り出すまで待たされている間だけ true。読み込み中の表示に使う。
    var onPreparingChange: (@MainActor (Bool) -> Void)?

    /// 一斉スタートを予約するときの猶予。全プレイヤーへ setRate を配り終える前に
    /// その時刻が過ぎてしまうと、結局バラバラに動き出す。
    /// Mac より少し長めにしてあるのは、無線越しだと配るまでのばらつきが大きいため。
    private static let syncStartLeadSeconds: Double = 0.12
    /// 準備を待つ上限。電波が悪いままでも、いつまでも黒い画面で止めない。
    private static let readyTimeoutSeconds: Double = 20
    /// 開始位置がずれてもよい幅。ネットワーク越しに厳密シークを求めると
    /// そのたびに読み直しが走って、いつまでも始まらない。
    private static let seekTolerance = CMTime(seconds: 0.05, preferredTimescale: 600)

    private var leadPlayer: AVPlayer?
    private var leadTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var syncStartTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(urls: [URL]) {
        self.players = urls.map { url in
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = false
            player.sourceClock = CMClockGetHostTimeClock()
            return player
        }
        observeLeadPlayer()
    }

    // MARK: - 状態

    var isEmpty: Bool { players.isEmpty }

    var isPlaying: Bool { players.contains { $0.rate > 0 } }

    /// いちばん進んでいるプレイヤーと遅れているプレイヤーの開き（秒）。
    var drift: Double {
        let times = players.compactMap { player -> Double? in
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }
        guard let earliest = times.min(), let latest = times.max() else { return 0 }
        return latest - earliest
    }

    // MARK: - 再生

    func play() { startInSync() }

    func pause() {
        syncStartTask?.cancel()
        syncStartTask = nil
        players.forEach { $0.pause() }
        onPreparingChange?(false)
    }

    func startInSync(seek target: (@MainActor (AVPlayer) -> CMTime?)? = nil) {
        syncStartTask?.cancel()
        let players = self.players
        guard !players.isEmpty else { return }

        players.forEach { $0.pause() }
        let seekTargets = players.map { player in (player: player, time: target?(player)) }
        onPreparingChange?(true)

        syncStartTask = Task { @MainActor in
            for entry in seekTargets {
                guard let time = entry.time else { continue }
                await entry.player.seek(
                    to: time,
                    toleranceBefore: Self.seekTolerance,
                    toleranceAfter: Self.seekTolerance
                )
                if Task.isCancelled { return }
            }

            await Self.waitUntilAllBuffered(players)
            if Task.isCancelled { return }

            for player in players {
                _ = await player.preroll(atRate: 1.0)
                if Task.isCancelled { return }
            }

            // `pause()` は1本ずつ止まるので止まった位置がばらつく。`.invalid` のまま走らせると
            // そのばらつきが固定され、一時停止のたびに積み上がる。共通の位置を明示して揃える。
            let hasSeekTargets = seekTargets.contains { $0.time != nil }
            let alignment = hasSeekTargets ? CMTime.invalid : Self.commonStartTime(of: players)

            let startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: Self.syncStartLeadSeconds, preferredTimescale: 600)
            for player in players {
                player.setRate(1.0, time: alignment, atHostTime: startHostTime)
            }
            onPreparingChange?(false)
        }
    }

    /// そろえにいく開きの上限。これを超えていたら位置には触らない
    /// （尺の違うものが混ざっている、片方が終わっている、などは直すべきずれではない）。
    private static let maxAlignableSpread: Double = 1.0

    private static func commonStartTime(of players: [AVPlayer]) -> CMTime {
        let seconds = players.compactMap { player -> Double? in
            let value = player.currentTime().seconds
            guard value.isFinite else { return nil }
            if let duration = player.currentItem?.duration.seconds, duration.isFinite,
               value >= duration - 0.05 {
                return nil
            }
            return value
        }
        guard let earliest = seconds.min(), let latest = seconds.max() else { return .invalid }
        guard latest - earliest <= maxAlignableSpread else { return .invalid }
        return CMTime(seconds: earliest, preferredTimescale: 600)
    }

    /// ずれが `threshold` 秒を超えていたら、いちばん進んでいる位置へ全員を揃え直す。
    @discardableResult
    func resyncIfDrifting(threshold: Double) -> Bool {
        guard isPlaying, drift > threshold else { return false }
        let latest = players.compactMap { player -> Double? in
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }.max() ?? 0
        let target = CMTime(seconds: latest, preferredTimescale: 600)
        startInSync { _ in target }
        return true
    }

    /// 全プレイヤーが「再生可能」かつ「そのまま流し続けられるだけ貯まっている」まで待つ。
    /// 無線越しでは `readyToPlay` になった直後はまだ貯まっておらず、
    /// そこで走らせると数百ミリ秒で止まってしまう。
    private static func waitUntilAllBuffered(_ players: [AVPlayer]) async {
        let deadline = Date().addingTimeInterval(readyTimeoutSeconds)
        while Date() < deadline {
            let ready = players.allSatisfy { $0.currentItem?.status == .readyToPlay }
            let buffered = players.allSatisfy { $0.currentItem?.isPlaybackLikelyToKeepUp == true }
            if ready && buffered { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
    }

    // MARK: - シーク

    func applySeek(_ target: @escaping @MainActor (AVPlayer) -> CMTime?) {
        guard !isPlaying else {
            startInSync(seek: target)
            return
        }
        syncStartTask?.cancel()
        syncStartTask = nil
        for player in players {
            guard let time = target(player) else { continue }
            player.seek(to: time, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
        }
    }

    func seekAll(by seconds: Double) {
        applySeek { player in
            let current = player.currentTime().seconds
            guard current.isFinite else { return nil }
            return CMTime(seconds: max(0, current + seconds), preferredTimescale: 600)
        }
    }

    func seekAll(toPercentage percentage: Double) {
        applySeek { player in
            guard let duration = player.currentItem?.duration, duration.seconds > 0 else { return nil }
            return CMTime(seconds: duration.seconds * percentage, preferredTimescale: 600)
        }
    }

    // MARK: - 監視と後始末

    private func observeLeadPlayer() {
        guard let leadPlayer = players.max(by: {
            ($0.currentItem?.duration.seconds ?? 0) < ($1.currentItem?.duration.seconds ?? 0)
        }) else { return }
        self.leadPlayer = leadPlayer

        leadPlayer.publisher(for: \.currentItem?.duration)
            .compactMap { $0?.seconds }
            .filter { !$0.isNaN && $0 > 0 }
            .sink { [weak self] duration in self?.onDurationUpdate?(duration) }
            .store(in: &cancellables)

        leadTimeObserver = leadPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.onTimeUpdate?(time.seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: leadPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onPlayToEnd?() }
        }
    }

    func cleanup() {
        syncStartTask?.cancel()
        syncStartTask = nil
        cancellables.removeAll()
        if let leadTimeObserver {
            leadPlayer?.removeTimeObserver(leadTimeObserver)
            self.leadTimeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        leadPlayer = nil
        onTimeUpdate = nil
        onDurationUpdate = nil
        onPlayToEnd = nil
        onPreparingChange = nil
        players.forEach {
            $0.pause()
            // 画面を閉じてもダウンロードが続くと、次に開く再生の帯域を食う。
            $0.replaceCurrentItem(with: nil)
        }
    }
}
