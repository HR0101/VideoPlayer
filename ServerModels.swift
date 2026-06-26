import Foundation
import Network
import MediaServerKit

// MARK: - 認証ヘルパー
enum ServerAuth {
    private static let prefix = "serverPIN_"

    static func key(for address: String) -> String {
        if let url = URL(string: address), let host = url.host { return prefix + host }
        return prefix + address
    }

    static func pin(for address: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key(for: address))
        return (v?.isEmpty == false) ? v : nil
    }

    static func setPIN(_ pin: String, for address: String) {
        UserDefaults.standard.set(pin, forKey: key(for: address))
    }

    static func clear(for address: String) {
        UserDefaults.standard.removeObject(forKey: key(for: address))
    }

    /// JSON系リクエスト用: PINをヘッダに付与
    static func request(_ url: URL, address: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let pin = pin(for: address) { req.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }
        return req
    }

    /// AsyncImage / AVPlayer はヘッダを付けられないため pin をクエリパラメータに付与
    static func mediaURL(address: String, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: address + path) else { return nil }
        var items = query
        if let pin = pin(for: address) { items.append(URLQueryItem(name: "pin", value: pin)) }
        if !items.isEmpty { comps.queryItems = items }
        return comps.url
    }

    /// 同時再生・スライドショーの起動直前に呼ぶ。対象動画の先頭へ小さな Range リクエストを投げ、
    /// 外付けHDDのスピンアップ（スリープ復帰）や初回TCP接続のコストを先に済ませておく。
    /// これをやらないと、コールド状態のサーバーに複数本同時アクセスした際に
    /// 最初の数本が初回アクセスのレイテンシで再生開始に失敗する。
    static func prewarm(address: String, videoIDs: [String]) {
        for id in videoIDs {
            guard let url = mediaURL(address: address, path: "/video/\(id)") else { continue }
            Task.detached {
                var req = URLRequest(url: url)
                req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.timeoutInterval = 30
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }
}

// MARK: - 再生履歴管理
class PlaybackHistoryManager {
    static let shared = PlaybackHistoryManager()
    private let historyKey = "playback_history_ids"
    private let maxHistoryCount = 50

    func saveLastPlayed(id: String) {
        var ids = getHistoryIDs()
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) }
        ids.insert(id, at: 0)
        if ids.count > maxHistoryCount { ids = Array(ids.prefix(maxHistoryCount)) }
        UserDefaults.standard.set(ids, forKey: historyKey)
    }

    func getHistoryIDs() -> [String] {
        return UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    func removeHistory(id: String) {
        var ids = getHistoryIDs()
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            UserDefaults.standard.set(ids, forKey: historyKey)
        }
    }

    func getLastPlayedID() -> String? { getHistoryIDs().first }
}

// MARK: - お気に入り管理
@MainActor
final class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    private let key = "favorite_media_ids"
    @Published private(set) var ids: Set<String> = []

    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func isFavorite(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
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

// MARK: - ショート用お気に入り管理
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
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ShortsFavoriteClip].self, from: data) {
            clips = decoded
        }
    }

    func addClip(videoID: String, startTime: Double, endTime: Double) {
        let newClip = ShortsFavoriteClip(id: UUID(), videoID: videoID, startTime: startTime, endTime: endTime, addedAt: Date())
        clips.insert(newClip, at: 0)
        persist()
    }
    
    func removeClip(id: UUID) {
        clips.removeAll { $0.id == id }
        persist()
    }
    
    func isFavorite(videoID: String, startTime: Double) -> Bool {
        clips.contains { $0.videoID == videoID && abs($0.startTime - startTime) < 0.5 }
    }
    
    func getClipId(videoID: String, startTime: Double) -> UUID? {
        clips.first(where: { $0.videoID == videoID && abs($0.startTime - startTime) < 0.5 })?.id
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(clips) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

// MARK: - API通信マネージャー
class ServerAPI {

    static func createAlbum(serverAddress: String, name: String, type: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/albums/create") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }
        let body = ["name": name, "type": type]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func deleteAlbum(serverAddress: String, albumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/albums/\(albumID)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func moveVideos(serverAddress: String, videoIDs: [String], sourceAlbumID: String, targetAlbumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/move") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }

        struct MoveReq: Codable { let videoIds: [String]; let sourceAlbumId: String; let targetAlbumId: String }
        let body = MoveReq(videoIds: videoIDs, sourceAlbumId: sourceAlbumID, targetAlbumId: targetAlbumID)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func deleteVideos(serverAddress: String, videoIDs: [String], albumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/deleteVideos") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }

        struct DelReq: Codable { let videoIds: [String]; let albumId: String }
        let body = DelReq(videoIds: videoIDs, albumId: albumID)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // URLSessionUploadTaskを使用してメモリを節約
    static func uploadMedia(serverAddress: String, fileURL: URL, albumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/upload") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let filename = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "upload"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue(albumID, forHTTPHeaderField: "X-Album-Id")
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - Bonjour / Server Discovery

struct DiscoveredServer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let service: NetService
    var address: String?
}

@MainActor
class ServerBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var discoveredServers: [DiscoveredServer] = []
    private let browser = NetServiceBrowser()

    override init() {
        super.init()
        browser.delegate = self
    }

    func startBrowsing() {
        discoveredServers.removeAll()
        browser.searchForServices(ofType: "_myvideoserver._tcp.", inDomain: "local.")
    }

    func stopBrowsing() {
        browser.stop()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let newServer = DiscoveredServer(name: service.name, service: service)
        if !discoveredServers.contains(where: { $0.name == newServer.name }) {
            discoveredServers.append(newServer)
            service.delegate = self
            service.resolve(withTimeout: 5.0)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        discoveredServers.removeAll { $0.service == service }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName,
              let index = discoveredServers.firstIndex(where: { $0.service == sender }) else { return }

        let port = sender.port
        let addressString = "http://\(host):\(port)"

        DispatchQueue.main.async {
            guard self.discoveredServers.indices.contains(index) else { return }
            self.discoveredServers[index].address = addressString
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        discoveredServers.removeAll { $0.service == sender }
    }
}

// MARK: - Server Data Models
// RemoteAlbumInfo / RemoteVideoInfo は MediaServerKit に集約（Mac サーバーと共有）

@MainActor
class ServerManager: ObservableObject {
    @Published var server: DiscoveredServer?
    @Published var albums: [RemoteAlbumInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authRequired = false

    private(set) var currentAddress: String?

    func updateServer(_ newServer: DiscoveredServer?) {
        guard let newServer = newServer, let address = newServer.address else {
            self.server = nil
            self.albums = []
            return
        }

        if self.server?.id != newServer.id || self.albums.isEmpty {
            self.server = newServer
            Task {
                await fetchAlbums(serverAddress: address)
            }
        }
    }

    func submitPIN(_ pin: String) {
        guard let address = currentAddress else { return }
        ServerAuth.setPIN(pin, for: address)
        authRequired = false
        Task { await fetchAlbums(serverAddress: address) }
    }

    func fetchAlbums(serverAddress: String) async {
        currentAddress = serverAddress
        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "\(serverAddress)/albums") else {
            errorMessage = "無効なサーバーアドレスです。"
            isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                self.authRequired = true
                self.albums = []
                self.isLoading = false
                return
            }
            self.authRequired = false
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.albums = try decoder.decode([RemoteAlbumInfo].self, from: data)
        } catch {
            errorMessage = "サーバーアルバムの取得に失敗しました。"
        }
        isLoading = false
    }
}
