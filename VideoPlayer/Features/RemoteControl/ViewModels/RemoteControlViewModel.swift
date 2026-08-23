import Foundation

@MainActor
final class RemoteControlViewModel: ObservableObject {
  @Published private(set) var playbackState = RemotePlaybackState.idle
  /// Mac で差分切り替え再生が動いていれば、こちらが `isAvailable` になる。
  /// 通常再生とは別のプレイヤーなので状態も別に持ち、リモコンの見た目を切り替える。
  @Published private(set) var variantState = RemoteVariantState.idle
  @Published private(set) var isLoading = false
  @Published private(set) var isSendingCommand = false
  @Published var errorMessage: String?

  private let pollingIntervalNanoseconds: UInt64 = 1_000_000_000
  private let openRefreshDelayNanoseconds: UInt64 = 350_000_000
  private var pollingTask: Task<Void, Never>?
  private var serverAddress: String?

  func start(serverAddress: String?) {
    guard self.serverAddress != serverAddress || pollingTask == nil else { return }
    stop()
    self.serverAddress = serverAddress
    guard serverAddress != nil else {
      playbackState = .idle
      errorMessage = nil
      return
    }

    pollingTask = Task { [weak self] in
      guard let self else { return }
      await self.refresh(showLoading: true)
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: self.pollingIntervalNanoseconds)
        guard !Task.isCancelled else { return }
        await self.refresh(showLoading: false)
      }
    }
  }

  func stop() {
    pollingTask?.cancel()
    pollingTask = nil
  }

  func refresh(showLoading: Bool = false) async {
    guard let serverAddress else {
      playbackState = .idle
      variantState = .idle
      return
    }
    if showLoading { isLoading = true }
    defer { if showLoading { isLoading = false } }

    // 通常再生と差分切り替え再生は別のプレイヤーなので、1 回の更新で両方を見に行く。
    // 順番待ちさせると更新が 2 倍もたつくため、並べて投げて両方そろってから反映する。
    async let playback = RemoteControlService.fetchState(serverAddress: serverAddress)
    async let variant = RemoteControlService.fetchVariantState(serverAddress: serverAddress)

    do {
      let (fetchedPlayback, fetchedVariant) = try await (playback, variant)
      playbackState = fetchedPlayback
      variantState = fetchedVariant
      errorMessage = nil
    } catch {
      errorMessage = displayMessage(for: error)
    }
  }

  func send(action: RemoteControlAction, value: Double? = nil) async {
    guard let serverAddress, !isSendingCommand else { return }
    isSendingCommand = true
    defer { isSendingCommand = false }

    do {
      playbackState = try await RemoteControlService.send(
        RemoteControlCommand(action: action, value: value),
        serverAddress: serverAddress
      )
      errorMessage = nil
    } catch {
      errorMessage = displayMessage(for: error)
    }
  }

  // MARK: - 差分切り替え再生

  func sendVariant(action: RemoteVariantControlAction, value: Double? = nil) async {
    guard let serverAddress, !isSendingCommand else { return }
    isSendingCommand = true
    defer { isSendingCommand = false }

    do {
      variantState = try await RemoteControlService.sendVariant(
        RemoteVariantControlCommand(action: action, value: value),
        serverAddress: serverAddress
      )
      errorMessage = nil
    } catch {
      errorMessage = displayMessage(for: error)
    }
  }

  /// 選んだ差分を Mac の全画面で走らせる。以後の切り替えは iPhone のリモコンから。
  @discardableResult
  func openVariantOnMac(
    videoIDs: [String],
    serverAddress: String
  ) async -> Bool {
    guard !isSendingCommand else { return false }
    self.serverAddress = serverAddress
    isSendingCommand = true
    defer { isSendingCommand = false }

    do {
      try await RemoteControlService.openVariant(
        videoIDs: videoIDs,
        serverAddress: serverAddress
      )
      errorMessage = nil
      // Mac 側がプレイヤーを組み立てるのを少し待ってから状態を引き直す。
      try? await Task.sleep(nanoseconds: openRefreshDelayNanoseconds)
      if let refreshed = try? await RemoteControlService.fetchVariantState(
        serverAddress: serverAddress
      ) {
        variantState = refreshed
      }
      return true
    } catch {
      errorMessage = displayMessage(for: error)
      return false
    }
  }

  @discardableResult
  func openOnMac(
    videoID: String,
    albumID: String?,
    serverAddress: String
  ) async -> Bool {
    guard !isSendingCommand else { return false }
    self.serverAddress = serverAddress
    isSendingCommand = true
    defer { isSendingCommand = false }

    do {
      try await RemoteControlService.open(
        videoID: videoID,
        albumID: albumID,
        serverAddress: serverAddress
      )
      errorMessage = nil
      try? await Task.sleep(nanoseconds: openRefreshDelayNanoseconds)
      if let refreshedState = try? await RemoteControlService.fetchState(
        serverAddress: serverAddress
      ) {
        playbackState = refreshedState
      }
      return true
    } catch {
      errorMessage = displayMessage(for: error)
      return false
    }
  }

  private func displayMessage(for error: Error) -> String {
    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription {
      return description
    }
    return "Macとの通信に失敗しました．同じWi-Fiに接続されているか確認してください．"
  }
}
