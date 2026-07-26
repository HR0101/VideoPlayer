import Foundation
import MediaServerKit

@MainActor
final class RemoteVideoListViewModel: ObservableObject {
    @Published var videos: [RemoteVideoInfo] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var searchText = ""

    /// ホーム/ショート/お気に入り/履歴タブは全件リストを共有するため、
    /// タブを行き来するたびにMB級のJSONを再取得しないよう短期キャッシュする。
    /// 引っ張って更新（forceRefresh）とメディアの追加・削除で無効化される。
    private struct AllMediaCacheEntry {
        let videos: [RemoteVideoInfo]
        let fetchedAt: Date
    }
    private static var allMediaCache: [String: AllMediaCacheEntry] = [:]
    private static let allMediaCacheTTL: TimeInterval = 60

    static func invalidateAllMediaCache() {
        allMediaCache.removeAll()
    }

    func sortedAndFilteredVideos(for albumID: String, sortOrder: RemoteSortOrder) -> [RemoteVideoInfo] {
        let uniqueVideos = uniqueVideosByID(videos)
        let filtered = searchText.isEmpty ? uniqueVideos : uniqueVideos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        if albumID == "HISTORY" || albumID == "FAVORITES" || albumID == "HOME" {
            return filtered
        }

        switch sortOrder {
        case .importDescending:
            return filtered.sorted { $0.importDate > $1.importDate }
        case .importAscending:
            return filtered.sorted { $0.importDate < $1.importDate }
        case .creationDescending:
            return filtered.sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .creationAscending:
            return filtered.sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .durationDescending:
            return filtered.sorted { $0.duration > $1.duration }
        case .durationAscending:
            return filtered.sorted { $0.duration < $1.duration }
        case .nameAscending:
            return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .nameDescending:
            return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        case .lastOpenedDescending:
            // サーバーが古く accessDate を送らない場合は .distantPast 扱いで末尾に寄る。
            return filtered.sorted { ($0.accessDate ?? .distantPast) > ($1.accessDate ?? .distantPast) }
        case .lastOpenedAscending:
            return filtered.sorted { ($0.accessDate ?? .distantPast) < ($1.accessDate ?? .distantPast) }
        case .modifiedDescending:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .modifiedAscending:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        case .sizeDescending:
            return filtered.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeAscending:
            return filtered.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    func fetchVideos(serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo], forceRefresh: Bool = false) async {
        isLoading = true
        // 前回のエラーを消してから取得する。残したままだと成功後もバナーが出続ける。
        errorMessage = nil
        defer { isLoading = false }

        if albumID == "HISTORY" {
            do {
                let allVideos = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, forceRefresh: forceRefresh)
                let historyIDs = PlaybackHistoryManager.shared.getHistoryIDs()
                var historyVideos: [RemoteVideoInfo] = []
                for id in historyIDs {
                    if let video = allVideos.first(where: { $0.id == id }) {
                        historyVideos.append(video)
                    }
                }
                videos = historyVideos
            } catch {
                errorMessage = "履歴取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "FAVORITES" {
            do {
                let allMedia = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, forceRefresh: forceRefresh)
                let favIDs = FavoritesManager.shared.ids
                videos = allMedia.filter { favIDs.contains($0.id) }
            } catch {
                errorMessage = "お気に入り取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "SHORTS" {
            do {
                videos = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, includePhotos: false, forceRefresh: forceRefresh)
            } catch {
                errorMessage = "ショート取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "SHORTS_FAVORITES" {
            do {
                let allMedia = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, includePhotos: false, forceRefresh: forceRefresh)
                let favVideoIDs = Set(ShortsFavoritesManager.shared.clips.map { $0.videoID })
                videos = allMedia.filter { favVideoIDs.contains($0.id) }
            } catch {
                errorMessage = "ショートお気に入り取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "HOME" {
            do {
                videos = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, includePhotos: false, forceRefresh: forceRefresh).shuffled()
            } catch {
                errorMessage = "おすすめ取得失敗: \(error.localizedDescription)"
            }
        } else {
            guard let url = URL(string: "\(serverAddress)/albums/\(albumID)/videos") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                videos = try decoder.decode([RemoteVideoInfo].self, from: data)
            } catch {
                errorMessage = "取得失敗: \(error.localizedDescription)"
            }
        }
        
        prewarmFirstVideo(serverAddress: serverAddress)
    }

    func moveVideos(ids: [String], serverAddress: String, sourceAlbumID: String, targetAlbumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        _ = try? await ServerAPI.moveVideos(serverAddress: serverAddress, videoIDs: ids, sourceAlbumID: sourceAlbumID, targetAlbumID: targetAlbumID)
        Self.invalidateAllMediaCache()
        await fetchVideos(serverAddress: serverAddress, albumID: sourceAlbumID, allServerAlbums: allServerAlbums)
    }

    func deleteVideos(ids: [String], serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        _ = try? await ServerAPI.deleteVideos(serverAddress: serverAddress, videoIDs: ids, albumID: albumID)
        Self.invalidateAllMediaCache()
        await fetchVideos(serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
    }

    func deleteVideosCompletely(ids: [String], serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        _ = try? await ServerAPI.deleteVideosCompletely(serverAddress: serverAddress, videoIDs: ids)
        Self.invalidateAllMediaCache()
        await fetchVideos(serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
    }

    func uploadMedia(items: [PickedMediaItem], serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        for item in items {
            _ = try? await ServerAPI.uploadMedia(serverAddress: serverAddress, fileURL: item.tempURL, albumID: albumID)
        }
        Self.invalidateAllMediaCache()
        await fetchVideos(serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
    }

    private func fetchAllMedia(serverAddress: String, allServerAlbums: [RemoteAlbumInfo], includePhotos: Bool = true, forceRefresh: Bool = false) async throws -> [RemoteVideoInfo] {
        let cacheKey = "\(serverAddress)|photos:\(includePhotos)"
        if !forceRefresh,
           let entry = Self.allMediaCache[cacheKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.allMediaCacheTTL {
            return entry.videos
        }

        let libraryAlbums = allServerAlbums.filter { $0.name == "ALL VIDEOS" || (includePhotos && $0.name == "ALL PHOTOS") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var all: [RemoteVideoInfo] = []
        for album in libraryAlbums {
            guard let url = URL(string: "\(serverAddress)/albums/\(album.id)/videos") else { continue }
            let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
            all.append(contentsOf: try decoder.decode([RemoteVideoInfo].self, from: data))
        }
        // allServerAlbums がまだ届いていない起動直後は libraryAlbums が空になり、結果も必ず空になる。
        // これをキャッシュすると、後から allServerAlbums が届いて再取得しても空のキャッシュを
        // 返し続けてしまう（ホーム/ショートタブが「メディアがありません」に固定される原因だった）。
        guard !libraryAlbums.isEmpty else { return all }
        Self.allMediaCache[cacheKey] = AllMediaCacheEntry(videos: all, fetchedAt: Date())
        return all
    }

    private func prewarmFirstVideo(serverAddress: String) {
        if let firstVid = videos.first(where: { !$0.isPhoto }),
           let wakeupURL = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(firstVid.id)") {
            Task.detached {
                var req = URLRequest(url: wakeupURL)
                req.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    private func uniqueVideosByID(_ source: [RemoteVideoInfo]) -> [RemoteVideoInfo] {
        var seenIDs = Set<String>()
        return source.filter { video in
            seenIDs.insert(video.id).inserted
        }
    }
}
