import Foundation
import MediaServerKit

@MainActor
final class RemoteVideoListViewModel: ObservableObject {
    @Published var videos: [RemoteVideoInfo] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var currentSortOrder: RemoteSortOrder = .importDescending

    func sortedAndFilteredVideos(for albumID: String) -> [RemoteVideoInfo] {
        let uniqueVideos = uniqueVideosByID(videos)
        let filtered = searchText.isEmpty ? uniqueVideos : uniqueVideos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        if albumID == "HISTORY" || albumID == "FAVORITES" || albumID == "HOME" {
            return filtered
        }

        switch currentSortOrder {
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
        }
    }

    func fetchVideos(serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        isLoading = true
        defer { isLoading = false }

        if albumID == "HISTORY" {
            do {
                let allVideos = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums)
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
                let allMedia = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums)
                let favIDs = FavoritesManager.shared.ids
                videos = allMedia.filter { favIDs.contains($0.id) }
            } catch {
                errorMessage = "お気に入り取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "SHORTS" {
            do {
                videos = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, includePhotos: false)
            } catch {
                errorMessage = "ショート取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "SHORTS_FAVORITES" {
            do {
                let allMedia = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, includePhotos: false)
                let favVideoIDs = Set(ShortsFavoritesManager.shared.clips.map { $0.videoID })
                videos = allMedia.filter { favVideoIDs.contains($0.id) }
            } catch {
                errorMessage = "ショートお気に入り取得失敗: \(error.localizedDescription)"
            }
        } else if albumID == "HOME" {
            do {
                videos = try await fetchAllMedia(serverAddress: serverAddress, allServerAlbums: allServerAlbums, includePhotos: false).shuffled()
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
        await fetchVideos(serverAddress: serverAddress, albumID: sourceAlbumID, allServerAlbums: allServerAlbums)
    }

    func deleteVideos(ids: [String], serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        _ = try? await ServerAPI.deleteVideos(serverAddress: serverAddress, videoIDs: ids, albumID: albumID)
        await fetchVideos(serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
    }

    func uploadMedia(items: [PickedMediaItem], serverAddress: String, albumID: String, allServerAlbums: [RemoteAlbumInfo]) async {
        for item in items {
            _ = try? await ServerAPI.uploadMedia(serverAddress: serverAddress, fileURL: item.tempURL, albumID: albumID)
        }
        await fetchVideos(serverAddress: serverAddress, albumID: albumID, allServerAlbums: allServerAlbums)
    }

    private func fetchAllMedia(serverAddress: String, allServerAlbums: [RemoteAlbumInfo], includePhotos: Bool = true) async throws -> [RemoteVideoInfo] {
        let libraryAlbums = allServerAlbums.filter { $0.name == "ALL VIDEOS" || (includePhotos && $0.name == "ALL PHOTOS") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var all: [RemoteVideoInfo] = []
        for album in libraryAlbums {
            guard let url = URL(string: "\(serverAddress)/albums/\(album.id)/videos") else { continue }
            let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
            all.append(contentsOf: try decoder.decode([RemoteVideoInfo].self, from: data))
        }
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
