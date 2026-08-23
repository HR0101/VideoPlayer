import Foundation

// MARK: - Mac で走っている差分切り替え再生の状態（リモコン側の写し）
//
// 映像は Mac が出す。iPhone が持つのは「何本の差分があって、いまどれを見せているか」だけ。
// 差分そのものを受け取らないので、iPhone 内で完結する `RemoteVariantPlayerViewModel`
// のような本数の上限（無線越しの帯域とデコーダ）はここには効かない。

struct RemoteVariantState: Codable, Equatable, Sendable {
  struct Item: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
  }

  let isAvailable: Bool
  let variants: [Item]
  let activeIndex: Int
  let currentTime: Double
  let duration: Double
  let isPlaying: Bool
  let hasReachedEnd: Bool
  let isAutoSwitching: Bool
  let secondsUntilSwitch: Double
  let minInterval: Double
  let maxInterval: Double
  let avoidsImmediateRepeat: Bool
  let volume: Double
  let isMuted: Bool

  nonisolated static let idle = RemoteVariantState(
    isAvailable: false,
    variants: [],
    activeIndex: 0,
    currentTime: 0,
    duration: 0,
    isPlaying: false,
    hasReachedEnd: false,
    isAutoSwitching: false,
    secondsUntilSwitch: 0,
    minInterval: 0,
    maxInterval: 0,
    avoidsImmediateRepeat: true,
    volume: 1,
    isMuted: false
  )

  var activeVariant: Item? {
    variants.indices.contains(activeIndex) ? variants[activeIndex] : nil
  }
}

enum RemoteVariantControlAction: String, Codable, Sendable {
  case play
  case pause
  case togglePlayback
  case seekTo
  case seekBy
  /// `value` に差分の番号（0 始まり）。
  case showVariant
  case nextVariant
  case previousVariant
  case randomVariant
  case setAutoSwitching
  case setMinInterval
  case setMaxInterval
  case setAvoidsImmediateRepeat
  case setVolume
  case toggleMute
  case close
}

struct RemoteVariantControlCommand: Codable, Sendable {
  let action: RemoteVariantControlAction
  let value: Double?
}

struct RemoteVariantOpenCommand: Codable, Sendable {
  let videoIDs: [String]
}
