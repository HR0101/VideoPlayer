import SwiftUI

// MARK: - Mac の差分切り替え再生をこの iPhone から操作する
//
// 映像は Mac の全画面に出したまま、こちらは「どの差分を見せるか」を差し替えるだけ。
// 差分の実体を受け取らないので、iPhone で重ねて再生するとき（4 本まで）のような
// 帯域とデコーダの制約がなく、Mac 側の上限 9 本までそのまま並べられる。

struct RemoteVariantControlView: View {
  @ObservedObject var viewModel: RemoteControlViewModel
  let serverAddress: String

  @State private var scrubPosition = 0.0
  @State private var isScrubbing = false
  @State private var volume = 1.0
  @State private var isAdjustingVolume = false
  @State private var minInterval = 3.0
  @State private var maxInterval = 6.0
  @State private var isAdjustingInterval = false

  /// Mac 側 `VariantSwitchSettings.allowedRange` と同じ幅。
  private let intervalRange: ClosedRange<Double> = 0.1...60
  private let controlButtonSize: CGFloat = 48
  private let primaryControlButtonSize: CGFloat = 72

  private var state: RemoteVariantState { viewModel.variantState }

  var body: some View {
    VStack(spacing: 24) {
      header
      variantGrid
      switchControls
      autoSwitchPanel
      timelineControl
      transportControls
      volumeControl
      closeButton
    }
    .onAppear { syncDrafts() }
    .onChange(of: state.currentTime) { _, time in
      if !isScrubbing { scrubPosition = time }
    }
    .onChange(of: state.volume) { _, newVolume in
      if !isAdjustingVolume { volume = newVolume }
    }
    .onChange(of: state.minInterval) { _, newValue in
      if !isAdjustingInterval { minInterval = newValue }
    }
    .onChange(of: state.maxInterval) { _, newValue in
      if !isAdjustingInterval { maxInterval = newValue }
    }
  }

  // MARK: - 見出し

  private var header: some View {
    VStack(spacing: 8) {
      Label("Macで差分切り替え再生中", systemImage: "rectangle.on.rectangle.angled")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.appGold)

      Text(state.activeVariant?.title ?? "差分")
        .font(.title3.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.center)

      Text("\(state.activeIndex + 1) / \(state.variants.count) 本目")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }
  }

  // MARK: - 差分を直接えらぶ

  private var variantGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("差分を選ぶ", systemImage: "square.grid.2x2.fill")
          .font(.headline)
          .foregroundStyle(.white)
        Spacer()
        Text("タップでMacの表示が切り替わります")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.55))
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 104), spacing: 12)],
        spacing: 12
      ) {
        ForEach(Array(state.variants.enumerated()), id: \.element.id) { index, variant in
          variantCard(variant, index: index)
        }
      }
    }
  }

  private func variantCard(_ variant: RemoteVariantState.Item, index: Int) -> some View {
    let isActive = index == state.activeIndex
    return Button {
      Task { await viewModel.sendVariant(action: .showVariant, value: Double(index)) }
      Haptics.medium()
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        ZStack(alignment: .topLeading) {
          RemoteVideoThumbnailView(
            thumbnailURL: ServerAuth.mediaURL(
              address: serverAddress,
              path: "/thumbnail/\(variant.id)"
            ),
            duration: 0
          )
          .frame(height: 66)
          .frame(maxWidth: .infinity)
          .clipped()

          Text("\(index + 1)")
            .font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(isActive ? .black : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isActive ? Color.appGold : Color.black.opacity(0.7), in: Capsule())
            .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        Text(variant.title)
          .font(.caption2)
          .foregroundStyle(isActive ? .white : .white.opacity(0.66))
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(isActive ? Color.appGold.opacity(0.16) : Color.white.opacity(0.06))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(isActive ? Color.appGold : Color.white.opacity(0.12), lineWidth: isActive ? 2 : 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(index + 1)本目 \(variant.title)")
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }

  // MARK: - 前・ランダム・次

  private var switchControls: some View {
    HStack(spacing: 12) {
      switchButton(icon: "chevron.left", title: "前の差分") {
        await viewModel.sendVariant(action: .previousVariant)
      }
      switchButton(icon: "shuffle", title: "ランダム") {
        await viewModel.sendVariant(action: .randomVariant)
      }
      switchButton(icon: "chevron.right", title: "次の差分") {
        await viewModel.sendVariant(action: .nextVariant)
      }
    }
    .disabled(state.variants.count < 2)
    .opacity(state.variants.count < 2 ? 0.35 : 1)
  }

  private func switchButton(
    icon: String,
    title: String,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
      Haptics.medium()
    } label: {
      VStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .semibold))
        Text(title)
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
  }

  // MARK: - 自動切り替え

  private var autoSwitchPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Toggle(isOn: autoSwitchBinding) {
        HStack {
          Label("自動で切り替える", systemImage: "timer")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
          Spacer()
          if state.isAutoSwitching && state.isPlaying {
            Text(String(format: "あと %.1f秒", max(state.secondsUntilSwitch, 0)))
              .font(.caption.monospacedDigit())
              .foregroundStyle(Color.appGold)
          }
        }
      }
      .tint(Color.appGold)

      if state.isAutoSwitching {
        intervalSlider(
          title: "最短",
          value: $minInterval,
          commit: { await viewModel.sendVariant(action: .setMinInterval, value: minInterval) }
        )
        intervalSlider(
          title: "最長",
          value: $maxInterval,
          commit: { await viewModel.sendVariant(action: .setMaxInterval, value: maxInterval) }
        )
        Text("最短と最長を同じにすれば固定間隔、開ければその範囲でばらつきます。")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.5))

        Toggle(isOn: avoidRepeatBinding) {
          Text("同じ差分が連続しないようにする")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .tint(Color.appGold)
      }
    }
    .padding(18)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
  }

  private func intervalSlider(
    title: String,
    value: Binding<Double>,
    commit: @escaping () async -> Void
  ) -> some View {
    VStack(spacing: 4) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.75))
        Spacer()
        Text(String(format: "%.1f 秒", value.wrappedValue))
          .font(.caption.monospacedDigit())
          .foregroundStyle(Color.appGold)
      }
      Slider(
        value: value,
        in: intervalRange,
        onEditingChanged: { editing in
          isAdjustingInterval = editing
          if !editing { Task { await commit() } }
        }
      )
      .tint(Color.appGold)
    }
  }

  private var autoSwitchBinding: Binding<Bool> {
    Binding(
      get: { state.isAutoSwitching },
      set: { newValue in
        Task {
          await viewModel.sendVariant(
            action: .setAutoSwitching,
            value: newValue ? 1 : 0
          )
        }
      }
    )
  }

  private var avoidRepeatBinding: Binding<Bool> {
    Binding(
      get: { state.avoidsImmediateRepeat },
      set: { newValue in
        Task {
          await viewModel.sendVariant(
            action: .setAvoidsImmediateRepeat,
            value: newValue ? 1 : 0
          )
        }
      }
    )
  }

  // MARK: - 再生位置と音量

  private var timelineControl: some View {
    VStack(spacing: 6) {
      Slider(
        value: $scrubPosition,
        in: 0...max(state.duration, 0.1),
        onEditingChanged: { editing in
          isScrubbing = editing
          if !editing {
            Task { await viewModel.sendVariant(action: .seekTo, value: scrubPosition) }
          }
        }
      )
      .tint(Color.appGold)
      HStack {
        Text(timeText(scrubPosition))
        Spacer()
        Text("−" + timeText(max(state.duration - scrubPosition, 0)))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.white.opacity(0.65))
    }
  }

  private var transportControls: some View {
    HStack(spacing: 18) {
      controlButton(icon: "gobackward.10", accessibilityLabel: "10秒戻る") {
        await viewModel.sendVariant(action: .seekBy, value: -10)
      }
      Button {
        Task { await viewModel.sendVariant(action: .togglePlayback) }
      } label: {
        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 28, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: primaryControlButtonSize, height: primaryControlButtonSize)
          .background(Color.appGold, in: Circle())
      }
      .accessibilityLabel(state.isPlaying ? "一時停止" : "再生")
      controlButton(icon: "goforward.10", accessibilityLabel: "10秒進む") {
        await viewModel.sendVariant(action: .seekBy, value: 10)
      }
    }
  }

  private var volumeControl: some View {
    HStack(spacing: 14) {
      Button {
        Task { await viewModel.sendVariant(action: .toggleMute) }
      } label: {
        Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
          .frame(width: 28)
      }
      .foregroundStyle(state.isMuted ? Color.appGold : .white)
      .accessibilityLabel(state.isMuted ? "ミュートを解除" : "ミュート")

      Slider(
        value: $volume,
        in: 0...1,
        onEditingChanged: { editing in
          isAdjustingVolume = editing
          if !editing {
            Task { await viewModel.sendVariant(action: .setVolume, value: volume) }
          }
        }
      )
      .tint(Color.appGold)

      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.white.opacity(0.8))
    }
    .padding(18)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
  }

  private var closeButton: some View {
    Button(role: .destructive) {
      Task { await viewModel.sendVariant(action: .close) }
    } label: {
      Label("Macのプレイヤーを閉じる", systemImage: "xmark.circle")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
    .buttonStyle(.bordered)
  }

  private func controlButton(
    icon: String,
    accessibilityLabel: String,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: controlButtonSize, height: controlButtonSize)
        .background(Color.white.opacity(0.1), in: Circle())
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private func syncDrafts() {
    scrubPosition = state.currentTime
    volume = state.volume
    minInterval = clampedInterval(state.minInterval)
    maxInterval = clampedInterval(state.maxInterval)
  }

  /// Mac が繋がる前の初期値（0）でスライダーの範囲を割らないようにする。
  private func clampedInterval(_ value: Double) -> Double {
    min(max(value, intervalRange.lowerBound), intervalRange.upperBound)
  }

  private func timeText(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let totalSeconds = max(Int(seconds), 0)
    let hours = totalSeconds / 3_600
    let minutes = totalSeconds % 3_600 / 60
    let remainingSeconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }
}
