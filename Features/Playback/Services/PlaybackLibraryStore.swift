import Foundation

final class PlaybackHistoryManager {
  static let shared = PlaybackHistoryManager()

  private let historyKey = "playback_history_ids"
  private let maxHistoryCount = 50

  func saveLastPlayed(id: String) {
    var ids = getHistoryIDs()
    if let index = ids.firstIndex(of: id) {
      ids.remove(at: index)
    }
    ids.insert(id, at: 0)
    if ids.count > maxHistoryCount {
      ids = Array(ids.prefix(maxHistoryCount))
    }
    UserDefaults.standard.set(ids, forKey: historyKey)
  }

  func getHistoryIDs() -> [String] {
    UserDefaults.standard.stringArray(forKey: historyKey) ?? []
  }

  func removeHistory(id: String) {
    var ids = getHistoryIDs()
    if let index = ids.firstIndex(of: id) {
      ids.remove(at: index)
      UserDefaults.standard.set(ids, forKey: historyKey)
    }
  }

  func getLastPlayedID() -> String? {
    getHistoryIDs().first
  }
}

@MainActor
final class FavoritesManager: ObservableObject {
  static let shared = FavoritesManager()

  private let key = "favorite_media_ids"
  @Published private(set) var ids: Set<String> = []

  private init() {
    ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  func isFavorite(_ id: String) -> Bool {
    ids.contains(id)
  }

  func toggle(_ id: String) {
    if ids.contains(id) {
      ids.remove(id)
    } else {
      ids.insert(id)
    }
    persist()
  }

  func remove(_ id: String) {
    ids.remove(id)
    persist()
  }

  private func persist() {
    UserDefaults.standard.set(Array(ids), forKey: key)
  }
}

struct ShortsFavoriteClip: Codable, Identifiable {
  let id: UUID
  let videoID: String
  let startTime: Double
  let endTime: Double
  let addedAt: Date
}

@MainActor
final class ShortsFavoritesManager: ObservableObject {
  static let shared = ShortsFavoritesManager()

  private let key = "shorts_favorite_clips"
  @Published private(set) var clips: [ShortsFavoriteClip] = []

  private init() {
    guard
      let data = UserDefaults.standard.data(forKey: key),
      let decoded = try? JSONDecoder().decode([ShortsFavoriteClip].self, from: data)
    else {
      return
    }
    clips = decoded
  }

  func addClip(videoID: String, startTime: Double, endTime: Double) {
    let clip = ShortsFavoriteClip(
      id: UUID(),
      videoID: videoID,
      startTime: startTime,
      endTime: endTime,
      addedAt: Date()
    )
    clips.insert(clip, at: 0)
    persist()
  }

  func removeClip(id: UUID) {
    clips.removeAll { $0.id == id }
    persist()
  }

  func isFavorite(videoID: String, startTime: Double) -> Bool {
    clips.contains {
      $0.videoID == videoID && abs($0.startTime - startTime) < 0.5
    }
  }

  func getClipId(videoID: String, startTime: Double) -> UUID? {
    clips.first {
      $0.videoID == videoID && abs($0.startTime - startTime) < 0.5
    }?.id
  }

  private func persist() {
    guard let encoded = try? JSONEncoder().encode(clips) else {
      return
    }
    UserDefaults.standard.set(encoded, forKey: key)
  }
}
