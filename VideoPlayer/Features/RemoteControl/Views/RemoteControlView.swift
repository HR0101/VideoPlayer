import SwiftUI
import UIKit

private struct RemoteChapterThumbnailView: View {
  let url: URL?
  let isCurrent: Bool
  let timeText: String
  let action: () -> Void

  @State private var image: UIImage?
  @State private var didFail = false

  private let maximumLoadAttempts = 4
  private let retryDelayNanoseconds: UInt64 = 700_000_000
  private let width: CGFloat = 156
  private let height: CGFloat = 88

  var body: some View {
    Button(action: action) {
      ZStack(alignment: .bottomTrailing) {
        thumbnailContent
          .frame(width: width, height: height)
          .clipped()

        Text(timeText)
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.black.opacity(0.72), in: Capsule())
          .padding(6)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isCurrent ? Color.appGold : Color.white.opacity(0.16),
            lineWidth: isCurrent ? 3 : 1
          )
      }
      .shadow(color: isCurrent ? Color.appGold.opacity(0.28) : .clear, radius: 10)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(timeText)へ移動")
    .task(id: url) {
      await loadImage()
    }
  }

  @ViewBuilder
  private var thumbnailContent: some View {
    if let image {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
    } else {
      ZStack {
        Color.white.opacity(0.08)
        if didFail {
          Image(systemName: "photo.badge.exclamationmark")
            .foregroundStyle(.white.opacity(0.5))
        } else {
          ProgressView()
            .tint(Color.appGold)
        }
      }
    }
  }

  private func loadImage() async {
    image = nil
    didFail = false
    guard let url else {
      didFail = true
      return
    }

    for attempt in 0..<maximumLoadAttempts {
      if Task.isCancelled { return }
      do {
        var request = URLRequest(url: url)
        request.cachePolicy = attempt == 0
          ? .returnCacheDataElseLoad
          : .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
          didFail = true
          return
        }
        if httpResponse.statusCode == 200, let loadedImage = UIImage(data: data) {
          image = loadedImage
          return
        }
        guard httpResponse.statusCode == 202 else {
          didFail = true
          return
        }
      } catch {
        if attempt == maximumLoadAttempts - 1 {
          didFail = true
          return
        }
      }

      try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
    }
    didFail = true
  }
}

struct RemoteControlView: View {
  @EnvironmentObject private var serverManager: ServerConnectionViewModel
  @EnvironmentObject private var navState: AppNavigationState
  @EnvironmentObject private var viewModel: RemoteControlViewModel

  @State private var scrubPosition = 0.0
  @State private var isScrubbing = false
  @State private var volume = 1.0
  @State private var isAdjustingVolume = false

  private let controlButtonSize: CGFloat = 48
  private let primaryControlButtonSize: CGFloat = 72
  private let chapterCount = 10

  private var serverAddress: String? {
    serverManager.server?.address
  }

  var body: some View {
    NavigationStack {
      ZStack {
        AppBackground()
        ScrollView {
          VStack(spacing: 24) {
            if serverAddress == nil {
              unavailableServerView
            } else if viewModel.isLoading && !viewModel.playbackState.isAvailable {
              ProgressView("Macの状態を確認中…")
                .tint(Color.appGold)
                .foregroundStyle(.white)
                .padding(.top, 120)
            } else if viewModel.variantState.isAvailable, let serverAddress {
              // 差分切り替え再生が動いているときは、通常再生のリモコンではなく
              // 「どの差分を見せるか」を選ぶ盤面に差し替える。
              RemoteVariantControlView(
                viewModel: viewModel,
                serverAddress: serverAddress
              )
            } else if viewModel.playbackState.isAvailable {
              nowPlayingView
            } else {
              idleView
            }

            if let errorMessage = viewModel.errorMessage {
              errorView(message: errorMessage)
            }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 24)
        }
      }
      .navigationTitle("Macリモコン")
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
    }
    .onAppear {
      scrubPosition = viewModel.playbackState.currentTime
      volume = viewModel.playbackState.volume
      viewModel.start(serverAddress: serverAddress)
    }
    .onChange(of: serverAddress) { _, address in
      viewModel.start(serverAddress: address)
    }
    .onDisappear {
      viewModel.stop()
    }
    .onChange(of: viewModel.playbackState.currentTime) { _, currentTime in
      if !isScrubbing { scrubPosition = currentTime }
    }
    .onChange(of: viewModel.playbackState.volume) { _, newVolume in
      if !isAdjustingVolume { volume = newVolume }
    }
  }

  private var unavailableServerView: some View {
    statusCard(
      icon: "wifi.slash",
      title: "Macが見つかりません",
      message: "Mac側でサーバーを起動し，iPhoneを同じWi-Fiへ接続してください．"
    )
  }

  private var idleView: some View {
    VStack(spacing: 20) {
      statusCard(
        icon: "display",
        title: "再生待機中",
        message: """
          アルバムで動画を長押しし，「Macで再生」を選ぶとここから操作できます．
          差分動画は，アルバムの「差分動画を探す」で Mac を選んで再生すると，\
          ここから見せる1本を切り替えられます．
          """
      )
      Button {
        navState.selectedTab = 2
      } label: {
        Label("動画を選ぶ", systemImage: "square.stack.fill")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.appGold)
    }
  }

  private var nowPlayingView: some View {
    VStack(spacing: 24) {
      chapterTimelineView
      playbackInformation
      timelineControl
      transportControls
      volumeControl
      closeButton
    }
  }

  private var chapterTimelineView: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("シーンから移動", systemImage: "rectangle.stack.fill")
          .font(.headline)
          .foregroundStyle(.white)
        Spacer()
        Text("10分割")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.appGold)
      }

      ScrollView(.horizontal) {
        LazyHStack(spacing: 12) {
          ForEach(Array(chapterTimes.enumerated()), id: \.offset) { _, time in
            RemoteChapterThumbnailView(
              url: chapterThumbnailURL(at: time),
              isCurrent: isCurrentChapter(time),
              timeText: timeText(time)
            ) {
              scrubPosition = time
              Task { await viewModel.send(action: .seekTo, value: time) }
            }
          }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var playbackInformation: some View {
    VStack(spacing: 8) {
      Text(viewModel.playbackState.title ?? "再生中の動画")
        .font(.title3.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.center)
      Label(
        viewModel.playbackState.isPlaying ? "Macで再生中" : "一時停止中",
        systemImage: viewModel.playbackState.isPlaying ? "play.fill" : "pause.fill"
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(Color.appGold)
    }
  }

  private var timelineControl: some View {
    VStack(spacing: 6) {
      Slider(
        value: $scrubPosition,
        in: 0...max(viewModel.playbackState.duration, 0.1),
        onEditingChanged: { editing in
          isScrubbing = editing
          if !editing {
            Task { await viewModel.send(action: .seekTo, value: scrubPosition) }
          }
        }
      )
      .tint(Color.appGold)
      HStack {
        Text(timeText(scrubPosition))
        Spacer()
        Text("−" + timeText(max(viewModel.playbackState.duration - scrubPosition, 0)))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.white.opacity(0.65))
    }
  }

  private var transportControls: some View {
    HStack(spacing: 18) {
      controlButton(
        icon: "backward.end.fill",
        accessibilityLabel: "前の動画",
        isEnabled: viewModel.playbackState.canPlayPrevious
      ) {
        await viewModel.send(action: .previous)
      }
      controlButton(icon: "gobackward.10", accessibilityLabel: "10秒戻る") {
        await viewModel.send(action: .seekBy, value: -10)
      }
      Button {
        Task { await viewModel.send(action: .togglePlayback) }
      } label: {
        Image(systemName: viewModel.playbackState.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 28, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: primaryControlButtonSize, height: primaryControlButtonSize)
          .background(Color.appGold, in: Circle())
      }
      .accessibilityLabel(viewModel.playbackState.isPlaying ? "一時停止" : "再生")
      controlButton(icon: "goforward.10", accessibilityLabel: "10秒進む") {
        await viewModel.send(action: .seekBy, value: 10)
      }
      controlButton(
        icon: "forward.end.fill",
        accessibilityLabel: "次の動画",
        isEnabled: viewModel.playbackState.canPlayNext
      ) {
        await viewModel.send(action: .next)
      }
    }
  }

  private var volumeControl: some View {
    HStack(spacing: 14) {
      Button {
        Task { await viewModel.send(action: .toggleMute) }
      } label: {
        Image(systemName: viewModel.playbackState.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
          .frame(width: 28)
      }
      .foregroundStyle(viewModel.playbackState.isMuted ? Color.appGold : .white)
      .accessibilityLabel(viewModel.playbackState.isMuted ? "ミュートを解除" : "ミュート")

      Slider(
        value: $volume,
        in: 0...1,
        onEditingChanged: { editing in
          isAdjustingVolume = editing
          if !editing {
            Task { await viewModel.send(action: .setVolume, value: volume) }
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
      Task { await viewModel.send(action: .close) }
    } label: {
      Label("Macのプレイヤーを閉じる", systemImage: "xmark.circle")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
    .buttonStyle(.bordered)
  }

  private func statusCard(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 18) {
      Image(systemName: icon)
        .font(.system(size: 56, weight: .light))
        .foregroundStyle(Color.appGold)
      Text(title)
        .font(.title2.weight(.bold))
        .foregroundStyle(.white)
      Text(message)
        .font(.body)
        .foregroundStyle(.white.opacity(0.68))
        .multilineTextAlignment(.center)
        .lineSpacing(4)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 36)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
  }

  private func errorView(message: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.white)
      Spacer(minLength: 0)
      Button("再試行") {
        Task { await viewModel.refresh(showLoading: true) }
      }
      .font(.subheadline.weight(.bold))
      .foregroundStyle(Color.appGold)
    }
    .padding(16)
    .background(Color.red.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
  }

  private func controlButton(
    icon: String,
    accessibilityLabel: String,
    isEnabled: Bool = true,
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
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.3)
    .accessibilityLabel(accessibilityLabel)
  }

  private var chapterTimes: [Double] {
    let duration = viewModel.playbackState.duration
    guard duration.isFinite, duration > 0 else { return [] }
    return (0..<chapterCount).map { index in
      duration * Double(index) / Double(chapterCount)
    }
  }

  private func chapterThumbnailURL(at time: Double) -> URL? {
    guard let serverAddress,
          let videoID = viewModel.playbackState.videoID else { return nil }
    return ServerAuth.mediaURL(
      address: serverAddress,
      path: "/thumbnail/\(videoID)",
      query: [
        URLQueryItem(name: "time", value: String(format: "%.3f", time)),
        URLQueryItem(name: "original", value: "true"),
        URLQueryItem(name: "max", value: "480")
      ]
    )
  }

  private func isCurrentChapter(_ chapterTime: Double) -> Bool {
    let duration = viewModel.playbackState.duration
    guard duration.isFinite, duration > 0 else { return false }
    let interval = duration / Double(chapterCount)
    let currentTime = viewModel.playbackState.currentTime
    return currentTime >= chapterTime && currentTime < chapterTime + interval
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
