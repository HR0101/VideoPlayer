import Foundation

private struct PlaybackSyncProgressEntry: Codable {
  var t: Double
  var at: Double
}

private struct PlaybackSyncMarkEntry: Codable {
  var on: Bool
  var at: Double
}

private struct PlaybackSyncShortMarkEntry: Codable {
  var on: Bool
  var t: Double
  var at: Double
}

private struct PlaybackSyncHistoryEntry: Codable {
  var id: String
  var at: Double
}

private struct PlaybackSyncDocument: Codable {
  var schemaVersion = 1
  var updatedAt: Double = 0
  var progress: [String: PlaybackSyncProgressEntry] = [:]
  var favorites: [String: PlaybackSyncMarkEntry] = [:]
  var history: [PlaybackSyncHistoryEntry] = []
  var historyRemoved: [String: Double] = [:]
  var shortsFavs: [String: PlaybackSyncShortMarkEntry] = [:]

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    progress = try container.decodeIfPresent(
      [String: PlaybackSyncProgressEntry].self,
      forKey: .progress
    ) ?? [:]
    favorites = try container.decodeIfPresent(
      [String: PlaybackSyncMarkEntry].self,
      forKey: .favorites
    ) ?? [:]
    history = try container.decodeIfPresent(
      [PlaybackSyncHistoryEntry].self,
      forKey: .history
    ) ?? []
    historyRemoved = try container.decodeIfPresent(
      [String: Double].self,
      forKey: .historyRemoved
    ) ?? [:]
    shortsFavs = try container.decodeIfPresent(
      [String: PlaybackSyncShortMarkEntry].self,
      forKey: .shortsFavs
    ) ?? [:]
  }
}

/// Web・iOS・Androidで視聴状態を共有する同期サービスです．
/// 通信に失敗してもローカル保存は維持し，次回接続時にLWWで再マージします．
@MainActor
final class PlaybackSyncService {
  static let shared = PlaybackSyncService()

  private let documentKey = "playback_sync_document_v1"
  private let historyKey = "playback_history_ids"
  private let favoritesKey = "favorite_media_ids"
  private let shortsFavoritesKey = "shorts_favorite_clips"
  private let maxHistoryCount = 200
  private let progressUpdateInterval: Double = 4_000
  private let pushDelayNanoseconds: UInt64 = 1_500_000_000

  private var document: PlaybackSyncDocument
  private var serverAddress: String?
  private var pushTask: Task<Void, Never>?
  private var generation = 0

  private init() {
    if
      let data = UserDefaults.standard.data(forKey: documentKey),
      let decoded = try? JSONDecoder().decode(PlaybackSyncDocument.self, from: data)
    {
      document = decoded
    } else {
      document = Self.makeMigratedDocument(
        historyKey: historyKey,
        favoritesKey: favoritesKey,
        shortsFavoritesKey: shortsFavoritesKey
      )
      persistDocument()
    }
  }

  func connect(serverAddress: String) async {
    self.serverAddress = serverAddress
    pushTask?.cancel()

    guard let url = URL(string: "\(serverAddress)/sync") else { return }
    do {
      let (data, response) = try await URLSession.shared.data(
        for: ServerAuth.request(url, address: serverAddress)
      )
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
      let remote = try JSONDecoder().decode(PlaybackSyncDocument.self, from: data)
      document = merge(document, remote)
      applyDocument()
      persistDocument()
      await pushNow()
    } catch {
      // LAN切断中はローカル状態を維持し，次回の接続で再同期します．
    }
  }

  func resumeTime(videoID: String) -> Double? {
    guard let time = document.progress[videoID]?.t, time.isFinite, time > 1 else {
      return nil
    }
    return time
  }

  func recordProgress(videoID: String, time: Double, force: Bool = false) {
    guard time.isFinite, time >= 0 else { return }
    let now = Self.nowMilliseconds
    if !force, let previous = document.progress[videoID] {
      let elapsed = now - previous.at
      if elapsed < progressUpdateInterval || abs(previous.t - time) < 2 { return }
    }
    document.progress[videoID] = PlaybackSyncProgressEntry(t: time, at: now)
    markDirty()
  }

  func clearProgress(videoID: String) {
    document.progress[videoID] = PlaybackSyncProgressEntry(t: 0, at: Self.nowMilliseconds)
    markDirty()
  }

  func recordHistory(videoID: String) {
    let now = Self.nowMilliseconds
    document.history.removeAll { $0.id == videoID }
    document.history.insert(PlaybackSyncHistoryEntry(id: videoID, at: now), at: 0)
    if document.history.count > maxHistoryCount {
      document.history = Array(document.history.prefix(maxHistoryCount))
    }
    markDirty()
  }

  func removeHistory(videoID: String) {
    let now = Self.nowMilliseconds
    document.history.removeAll { $0.id == videoID }
    document.historyRemoved[videoID] = now
    markDirty()
  }

  func setFavorite(videoID: String, isFavorite: Bool) {
    document.favorites[videoID] = PlaybackSyncMarkEntry(
      on: isFavorite,
      at: Self.nowMilliseconds
    )
    markDirty()
  }

  func setShortFavorite(videoID: String, startTime: Double, isFavorite: Bool) {
    document.shortsFavs[videoID] = PlaybackSyncShortMarkEntry(
      on: isFavorite,
      t: startTime,
      at: Self.nowMilliseconds
    )
    markDirty()
  }

  private func markDirty() {
    generation += 1
    persistDocument()
    guard serverAddress != nil else { return }
    pushTask?.cancel()
    pushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: pushDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await pushNow()
    }
  }

  private func pushNow() async {
    guard let serverAddress, let url = URL(string: "\(serverAddress)/sync") else { return }
    let sentGeneration = generation
    do {
      var request = ServerAuth.request(url, address: serverAddress, method: "PUT")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(document)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
      let remote = try JSONDecoder().decode(PlaybackSyncDocument.self, from: data)
      document = merge(document, remote)
      applyDocument()
      persistDocument()
      if generation != sentGeneration {
        markDirty()
      }
    } catch {
      // 次のローカル更新またはサーバー再接続時に再送します．
    }
  }

  private func merge(
    _ local: PlaybackSyncDocument,
    _ remote: PlaybackSyncDocument
  ) -> PlaybackSyncDocument {
    var result = local
    result.updatedAt = max(local.updatedAt, remote.updatedAt)

    for (id, entry) in remote.progress where entry.at > (result.progress[id]?.at ?? -1) {
      result.progress[id] = entry
    }
    for (id, entry) in remote.favorites where entry.at > (result.favorites[id]?.at ?? -1) {
      result.favorites[id] = entry
    }
    for (id, entry) in remote.shortsFavs where entry.at > (result.shortsFavs[id]?.at ?? -1) {
      result.shortsFavs[id] = entry
    }
    for (id, removedAt) in remote.historyRemoved
      where removedAt > (result.historyRemoved[id] ?? -1)
    {
      result.historyRemoved[id] = removedAt
    }

    var newestHistory: [String: Double] = [:]
    for entry in local.history + remote.history where !entry.id.isEmpty {
      newestHistory[entry.id] = max(newestHistory[entry.id] ?? -1, entry.at)
    }
    result.history = newestHistory
      .filter { id, playedAt in playedAt > (result.historyRemoved[id] ?? -1) }
      .map { PlaybackSyncHistoryEntry(id: $0.key, at: $0.value) }
      .sorted { $0.at > $1.at }
    if result.history.count > maxHistoryCount {
      result.history = Array(result.history.prefix(maxHistoryCount))
    }
    return result
  }

  private func applyDocument() {
    let historyIDs = document.history.map(\.id)
    let favoriteIDs = Set(
      document.favorites.compactMap { $0.value.on ? $0.key : nil }
    )
    let clips = document.shortsFavs.compactMap { videoID, entry -> ShortsFavoriteClip? in
      guard entry.on else { return nil }
      return ShortsFavoriteClip(
        id: UUID(),
        videoID: videoID,
        startTime: entry.t,
        endTime: entry.t + 15,
        addedAt: Date(timeIntervalSince1970: entry.at / 1_000)
      )
    }.sorted { $0.addedAt > $1.addedAt }

    PlaybackHistoryManager.shared.replaceFromSync(historyIDs)
    FavoritesManager.shared.replaceFromSync(favoriteIDs)
    ShortsFavoritesManager.shared.replaceFromSync(clips)
  }

  private func persistDocument() {
    guard let data = try? JSONEncoder().encode(document) else { return }
    UserDefaults.standard.set(data, forKey: documentKey)
  }

  private static var nowMilliseconds: Double {
    Date().timeIntervalSince1970 * 1_000
  }

  private static func makeMigratedDocument(
    historyKey: String,
    favoritesKey: String,
    shortsFavoritesKey: String
  ) -> PlaybackSyncDocument {
    var migrated = PlaybackSyncDocument()
    let history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    migrated.history = history.enumerated().map { index, id in
      PlaybackSyncHistoryEntry(id: id, at: Double(history.count - index))
    }
    for id in UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [] {
      migrated.favorites[id] = PlaybackSyncMarkEntry(on: true, at: 1)
    }
    if
      let data = UserDefaults.standard.data(forKey: shortsFavoritesKey),
      let clips = try? JSONDecoder().decode([ShortsFavoriteClip].self, from: data)
    {
      for clip in clips {
        migrated.shortsFavs[clip.videoID] = PlaybackSyncShortMarkEntry(
          on: true,
          t: clip.startTime,
          at: clip.addedAt.timeIntervalSince1970 * 1_000
        )
      }
    }
    return migrated
  }
}

@MainActor
final class PlaybackHistoryManager {
  static let shared = PlaybackHistoryManager()

  private let historyKey = "playback_history_ids"
  private let maxHistoryCount = 50

  func saveLastPlayed(id: String) {
    var ids = getHistoryIDs()
    ids.removeAll { $0 == id }
    ids.insert(id, at: 0)
    if ids.count > maxHistoryCount {
      ids = Array(ids.prefix(maxHistoryCount))
    }
    UserDefaults.standard.set(ids, forKey: historyKey)
    PlaybackSyncService.shared.recordHistory(videoID: id)
  }

  func getHistoryIDs() -> [String] {
    UserDefaults.standard.stringArray(forKey: historyKey) ?? []
  }

  func removeHistory(id: String) {
    var ids = getHistoryIDs()
    guard ids.contains(id) else { return }
    ids.removeAll { $0 == id }
    UserDefaults.standard.set(ids, forKey: historyKey)
    PlaybackSyncService.shared.removeHistory(videoID: id)
  }

  func getLastPlayedID() -> String? {
    getHistoryIDs().first
  }

  fileprivate func replaceFromSync(_ ids: [String]) {
    UserDefaults.standard.set(Array(ids.prefix(maxHistoryCount)), forKey: historyKey)
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
    let isFavorite: Bool
    if ids.contains(id) {
      ids.remove(id)
      isFavorite = false
    } else {
      ids.insert(id)
      isFavorite = true
    }
    persist()
    PlaybackSyncService.shared.setFavorite(videoID: id, isFavorite: isFavorite)
  }

  func remove(_ id: String) {
    guard ids.remove(id) != nil else { return }
    persist()
    PlaybackSyncService.shared.setFavorite(videoID: id, isFavorite: false)
  }

  fileprivate func replaceFromSync(_ newIDs: Set<String>) {
    ids = newIDs
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
    PlaybackSyncService.shared.setShortFavorite(
      videoID: videoID,
      startTime: startTime,
      isFavorite: true
    )
  }

  func removeClip(id: UUID) {
    guard let clip = clips.first(where: { $0.id == id }) else { return }
    clips.removeAll { $0.id == id }
    persist()
    PlaybackSyncService.shared.setShortFavorite(
      videoID: clip.videoID,
      startTime: clip.startTime,
      isFavorite: false
    )
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

  fileprivate func replaceFromSync(_ newClips: [ShortsFavoriteClip]) {
    clips = newClips
    persist()
  }

  private func persist() {
    guard let encoded = try? JSONEncoder().encode(clips) else { return }
    UserDefaults.standard.set(encoded, forKey: key)
  }
}
