import Foundation

@MainActor
final class RemoteControlViewModel: ObservableObject {
  @Published private(set) var playbackState = RemotePlaybackState.idle
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
      return
    }
    if showLoading { isLoading = true }
    defer { if showLoading { isLoading = false } }

    do {
      playbackState = try await RemoteControlService.fetchState(
        serverAddress: serverAddress
      )
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
