import AVKit
import Combine
import Foundation
import MediaServerKit

// MARK: - 差分切り替え再生（iPhone）
//
// 同じ尺・同じ動きで絵だけが違う「差分動画」をまとめて読み込み、
// 全部を同期で走らせたまま、見せる1本だけを差し替える。
// 切り替えは「どのレイヤーを見せるか」でしかないので継ぎ目が出ない。
//
// Mac と違い、ここは無線越しに本数ぶんの帯域とデコーダを同時に使う。
// 本数の上限（`maxVariants`）を低めに置いてあるのはそのため。
@MainActor
final class RemoteVariantPlayerViewModel: ObservableObject {
    /// 同時に走らせる上限。Mac は9本まで許しているが、iPhone は帯域もデコーダも足りない。
    /// 4K を4本も引くと、切り替え云々の前に再生自体が保たない。
    static let maxVariants = 4

    struct Variant: Identifiable {
        let id: String
        let title: String
    }

    @Published private(set) var variants: [Variant] = []
    @Published private(set) var activeIndex = 0
    @Published var commonCurrentTime: Double = 0
    @Published private(set) var commonDuration: Double = 1
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = true
    @Published private(set) var hasReachedEnd = false
    @Published private(set) var secondsUntilSwitch: Double = 0

    @Published var isAutoSwitching: Bool {
        didSet {
            RemoteVariantSettings.isAutoSwitchEnabled = isAutoSwitching
            secondsUntilSwitch = isAutoSwitching ? nextInterval() : 0
        }
    }

    /// 切り替え間隔の下限・上限。
    ///
    /// 丸め込みや上下の入れ替わりを `didSet` の中でやってはいけない。
    /// `@Published` は素の stored property と違い、`didSet` の中で自分自身へ代入すると
    /// `didSet` がもう一度走るため、`self = clamp(self)` の形が無限再帰になって落ちる。
    /// 変更は必ず下の `setMinInterval` / `setMaxInterval` を通す。
    @Published private(set) var minInterval: Double
    @Published private(set) var maxInterval: Double

    @Published var avoidsImmediateRepeat: Bool {
        didSet { RemoteVariantSettings.avoidsImmediateRepeat = avoidsImmediateRepeat }
    }

    @Published var isMuted: Bool = false { didSet { applyAudio() } }

    var players: [AVPlayer] { group.players }
    var variantCount: Int { variants.count }

    private static let tickSeconds: Double = 0.1
    /// 無線越しはローカルより開きやすいので、Mac の 0.25 秒より緩めに構える。
    /// 締めすぎると揃え直しが頻発して、そのたびに読み直しで引っかかる。
    private static let driftThreshold: Double = 0.4
    private static let driftCheckSeconds: Double = 5

    private let group: SynchronizedRemotePlayerGroup
    private var switchTask: Task<Void, Never>?
    private var isSliderEditing = false
    private var secondsSinceDriftCheck: Double = 0

    init(videos: [RemoteVideoInfo], serverAddress: String) {
        let playable = videos.prefix(Self.maxVariants).compactMap { video -> (RemoteVideoInfo, URL)? in
            guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)") else {
                return nil
            }
            return (video, url)
        }

        self.group = SynchronizedRemotePlayerGroup(urls: playable.map(\.1))
        self.variants = playable.map { Variant(id: $0.0.id, title: $0.0.filename) }
        self.isAutoSwitching = RemoteVariantSettings.isAutoSwitchEnabled
        self.minInterval = RemoteVariantSettings.minInterval
        self.maxInterval = RemoteVariantSettings.maxInterval
        self.avoidsImmediateRepeat = RemoteVariantSettings.avoidsImmediateRepeat

        group.onDurationUpdate = { [weak self] duration in self?.commonDuration = duration }
        group.onTimeUpdate = { [weak self] time in
            guard let self, !self.isSliderEditing else { return }
            self.commonCurrentTime = time
        }
        group.onPlayToEnd = { [weak self] in self?.handlePlayToEnd() }
        group.onPreparingChange = { [weak self] preparing in self?.isPreparing = preparing }
        applyAudio()
    }

    // MARK: - 再生

    func start() {
        guard !group.isEmpty else { return }
        hasReachedEnd = false
        isPlaying = true
        group.play()
        secondsUntilSwitch = isAutoSwitching ? nextInterval() : 0
        startTicking()
    }

    func togglePlayPause() {
        if isPlaying {
            isPlaying = false
            group.pause()
        } else {
            if hasReachedEnd {
                hasReachedEnd = false
                group.applySeek { _ in .zero }
            }
            isPlaying = true
            group.play()
        }
    }

    func seek(by seconds: Double) {
        hasReachedEnd = false
        group.seekAll(by: seconds)
    }

    func sliderEditingChanged(isEditing: Bool) {
        isSliderEditing = isEditing
        guard !isEditing, commonDuration > 0 else { return }
        hasReachedEnd = false
        group.seekAll(toPercentage: commonCurrentTime / commonDuration)
    }

    private func handlePlayToEnd() {
        hasReachedEnd = true
        isPlaying = false
        secondsUntilSwitch = 0
        group.pause()
    }

    // MARK: - 差分の切り替え

    func showVariant(at index: Int) {
        guard variants.indices.contains(index) else { return }
        applySwitch(to: index)
    }

    func showNextVariant() {
        guard variantCount > 1 else { return }
        applySwitch(to: (activeIndex + 1) % variantCount)
    }

    func showPreviousVariant() {
        guard variantCount > 1 else { return }
        applySwitch(to: (activeIndex - 1 + variantCount) % variantCount)
    }

    func showRandomVariant() {
        guard variantCount > 1 else { return }
        let candidates = avoidsImmediateRepeat
            ? variants.indices.filter { $0 != activeIndex }
            : Array(variants.indices)
        guard let pick = candidates.randomElement() else { return }
        applySwitch(to: pick)
    }

    /// 手で切り替えたときも次の自動切り替えまでの時間は測り直す
    /// （切り替えた直後にまた勝手に変わると、見たかった1本を見られない）。
    private func applySwitch(to index: Int) {
        activeIndex = index
        applyAudio()
        secondsUntilSwitch = isAutoSwitching ? nextInterval() : 0
    }

    /// 聞こえるのは表示中の1本だけ。裏の動画は走らせたままミュートする
    /// （止めると切り替えた瞬間に頭出しからやり直しになる）。
    private func applyAudio() {
        for (index, player) in players.enumerated() {
            player.isMuted = index != activeIndex || isMuted
        }
    }

    // MARK: - 間隔

    func setMinInterval(_ value: Double) {
        let clamped = RemoteVariantSettings.clamp(value)
        minInterval = clamped
        if maxInterval < clamped { maxInterval = clamped }
        persistIntervals()
    }

    func setMaxInterval(_ value: Double) {
        let clamped = RemoteVariantSettings.clamp(value)
        maxInterval = clamped
        if minInterval > clamped { minInterval = clamped }
        persistIntervals()
    }

    private func persistIntervals() {
        RemoteVariantSettings.minInterval = minInterval
        RemoteVariantSettings.maxInterval = maxInterval
        if isAutoSwitching, secondsUntilSwitch > maxInterval { secondsUntilSwitch = maxInterval }
    }

    private func nextInterval() -> Double {
        maxInterval > minInterval ? Double.random(in: minInterval...maxInterval) : minInterval
    }

    // MARK: - 自動切り替えの時計

    private func startTicking() {
        switchTask?.cancel()
        switchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard isPlaying else { return }

        secondsSinceDriftCheck += Self.tickSeconds
        if secondsSinceDriftCheck >= Self.driftCheckSeconds {
            secondsSinceDriftCheck = 0
            group.resyncIfDrifting(threshold: Self.driftThreshold)
        }

        guard isAutoSwitching, variantCount > 1 else { return }
        secondsUntilSwitch -= Self.tickSeconds
        if secondsUntilSwitch <= 0 { showRandomVariant() }
    }

    func cleanup() {
        switchTask?.cancel()
        switchTask = nil
        group.cleanup()
    }
}

// MARK: - 設定

/// 切り替え間隔まわりの設定。Mac 側の `VariantSwitchSettings` と同じ役割で、
/// 端末ごとに好みが違うので値は共有せずそれぞれで持つ。
enum RemoteVariantSettings {
    private static let minKey = "remoteVariant.minInterval"
    private static let maxKey = "remoteVariant.maxInterval"
    private static let autoKey = "remoteVariant.autoSwitchEnabled"
    private static let repeatKey = "remoteVariant.avoidsImmediateRepeat"

    static let allowedRange: ClosedRange<Double> = 0.5...60

    static var minInterval: Double {
        get { read(minKey, fallback: 3) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: minKey) }
    }

    static var maxInterval: Double {
        get { max(read(maxKey, fallback: 6), minInterval) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: maxKey) }
    }

    static var isAutoSwitchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var avoidsImmediateRepeat: Bool {
        get { UserDefaults.standard.object(forKey: repeatKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: repeatKey) }
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }

    private static func read(_ key: String, fallback: Double) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
        return clamp(stored)
    }
}
