import Foundation

struct RemotePlaybackState: Codable, Equatable, Sendable {
  let isAvailable: Bool
  let videoID: String?
  let title: String?
  let currentTime: Double
  let duration: Double
  let isPlaying: Bool
  let volume: Double
  let isMuted: Bool
  let canPlayPrevious: Bool
  let canPlayNext: Bool

  nonisolated static let idle = RemotePlaybackState(
    isAvailable: false,
    videoID: nil,
    title: nil,
    currentTime: 0,
    duration: 0,
    isPlaying: false,
    volume: 1,
    isMuted: false,
    canPlayPrevious: false,
    canPlayNext: false
  )
}

enum RemoteControlAction: String, Codable, Sendable {
  case play
  case pause
  case togglePlayback
  case seekTo
  case seekBy
  case previous
  case next
  case setVolume
  case toggleMute
  case close
}

struct RemoteControlCommand: Codable, Sendable {
  let action: RemoteControlAction
  let value: Double?
}

struct RemotePlaybackOpenCommand: Codable, Sendable {
  let videoID: String
  let albumID: String?
}
