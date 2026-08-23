import AVKit
import MediaServerKit
import SwiftUI

// MARK: - 差分切り替え再生（iPhone）
//
// 差分動画を重ねて置き、完全同期で全部走らせたまま見せる1枚だけを入れ替える。
// 重ねたビューを `if` で出し分けると、切り替えのたびに再生レイヤーが作り直されて
// 一瞬黒くなる。全部を常に置いたまま `opacity` だけ変えるのが要点。
//
// 操作系は Mac と同じく、触っていない間は引っ込める。

struct RemoteVariantPlayerView: View {
    @StateObject private var viewModel: RemoteVariantPlayerViewModel
    let onClose: () -> Void

    @State private var isChromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?

    private static let chromeAutoHideSeconds: Double = 2.5

    init(videos: [RemoteVideoInfo], serverAddress: String, onClose: @escaping () -> Void) {
        _viewModel = StateObject(
            wrappedValue: RemoteVariantPlayerViewModel(videos: videos, serverAddress: serverAddress)
        )
        self.onClose = onClose
    }

    /// 止めている間は出したままにする（消えていると再生ボタンの在り処が分からない）。
    private var isChromeShown: Bool { isChromeVisible || !viewModel.isPlaying }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            stack
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }

            if viewModel.isPreparing {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("\(viewModel.variantCount)本を読み込み中…")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            if isChromeShown {
                VStack {
                    topBar
                    Spacer()
                    controlPanel
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .onAppear {
            viewModel.start()
            scheduleChromeHide()
        }
        .onDisappear {
            chromeHideTask?.cancel()
            viewModel.cleanup()
        }
    }

    // MARK: - 映像

    @ViewBuilder
    private var stack: some View {
        if viewModel.players.isEmpty {
            Text("再生できる差分がありません").foregroundColor(.white)
        } else {
            ZStack {
                ForEach(Array(viewModel.players.enumerated()), id: \.offset) { index, player in
                    PlayerLayerView(player: player)
                        .opacity(index == viewModel.activeIndex ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - 操作系

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .accessibilityLabel("閉じる")

            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.activeIndex + 1) / \(viewModel.variantCount)　\(activeTitle)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if viewModel.isAutoSwitching, viewModel.variantCount > 1 {
                    Text(String(format: "次まで %.1f 秒", max(0, viewModel.secondsUntilSwitch)))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 0)

            Button { viewModel.isMuted.toggle() } label: {
                Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .accessibilityLabel(viewModel.isMuted ? "ミュート解除" : "ミュート")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var activeTitle: String {
        viewModel.variants.indices.contains(viewModel.activeIndex)
            ? viewModel.variants[viewModel.activeIndex].title.cleanVideoTitle
            : ""
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            variantChips
            transportRow
            intervalRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// 番号を押せばその差分へ。指で押す前提なので Mac のような細かいチップにはしない。
    private var variantChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.variants.enumerated()), id: \.element.id) { index, variant in
                    Button {
                        viewModel.showVariant(at: index)
                        revealChrome()
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text(variant.title.cleanVideoTitle)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 130)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(index == viewModel.activeIndex
                                ? Color.accentColor.opacity(0.9)
                                : Color.white.opacity(0.12))
                        )
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            Button {
                viewModel.togglePlayPause()
                revealChrome()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 26)
            }
            .accessibilityLabel(viewModel.isPlaying ? "一時停止" : "再生")

            Button {
                viewModel.showRandomVariant()
                revealChrome()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
            }
            .disabled(viewModel.variantCount < 2)
            .accessibilityLabel("ランダムな差分へ")

            Text(formatTime(viewModel.commonCurrentTime))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))

            Slider(
                value: $viewModel.commonCurrentTime,
                in: 0...max(viewModel.commonDuration, 0.1)
            ) { isEditing in
                viewModel.sliderEditingChanged(isEditing: isEditing)
                revealChrome()
            }
            .tint(.white)

            Text(formatTime(viewModel.commonDuration))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private var intervalRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $viewModel.isAutoSwitching) {
                Text("自動切り替え").font(.caption).foregroundColor(.white)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            Text("自動").font(.caption).foregroundColor(.white.opacity(0.85))

            Spacer(minLength: 4)

            stepper(
                label: String(format: "%.1f", viewModel.minInterval),
                onDecrease: { viewModel.setMinInterval(viewModel.minInterval - 0.5) },
                onIncrease: { viewModel.setMinInterval(viewModel.minInterval + 0.5) },
                accessibility: "下限の秒数"
            )
            Text("〜").font(.caption).foregroundColor(.white.opacity(0.6))
            stepper(
                label: String(format: "%.1f", viewModel.maxInterval),
                onDecrease: { viewModel.setMaxInterval(viewModel.maxInterval - 0.5) },
                onIncrease: { viewModel.setMaxInterval(viewModel.maxInterval + 0.5) },
                accessibility: "上限の秒数"
            )
            Text("秒").font(.caption).foregroundColor(.white.opacity(0.6))
        }
        .opacity(viewModel.isAutoSwitching ? 1 : 0.45)
    }

    private func stepper(
        label: String,
        onDecrease: @escaping () -> Void,
        onIncrease: @escaping () -> Void,
        accessibility: String
    ) -> some View {
        HStack(spacing: 0) {
            Button { onDecrease(); revealChrome() } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 28)
            }
            Text(label)
                .font(.caption.monospacedDigit())
                .frame(width: 34)
            Button { onIncrease(); revealChrome() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 28)
            }
        }
        .foregroundColor(.white)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .disabled(!viewModel.isAutoSwitching)
        .accessibilityLabel(accessibility)
    }

    // MARK: - 操作系の出し入れ

    private func toggleChrome() {
        if isChromeVisible {
            chromeHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = false }
        } else {
            revealChrome()
        }
    }

    private func revealChrome() {
        if !isChromeVisible {
            withAnimation(.easeOut(duration: 0.16)) { isChromeVisible = true }
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.chromeAutoHideSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { isChromeVisible = false }
        }
    }

    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        guard seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
