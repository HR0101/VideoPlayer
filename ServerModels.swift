import Foundation
import Network

// ===================================
//  ServerModels.swift
// ===================================

// MARK: - 認証ヘルパー (サーバーごとのPINを保持)
enum ServerAuth {
    private static let prefix = "serverPIN_"

    /// アドレスからホスト単位の安定キーを生成 (ポートやパスの違いを無視)
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

    /// メディアURL用 (AsyncImage / AVPlayer はヘッダを付けられないため pin をクエリに付与)
    static func mediaURL(address: String, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: address + path) else { return nil }
        var items = query
        if let pin = pin(for: address) { items.append(URLQueryItem(name: "pin", value: pin)) }
        if !items.isEmpty { comps.queryItems = items }
        return comps.url
    }
}

// MARK: - お気に入り管理 (クライアント側・メディアIDで保持)
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

// MARK: - API通信マネージャー (NAS機能用)
class ServerAPI {
    
    /// アルバム作成
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
    
    /// アルバム削除
    static func deleteAlbum(serverAddress: String, albumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/albums/\(albumID)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    
    /// メディアの移動
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
    
    /// メディアの削除 (アルバムから外す)
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
    
    /// メディアのアップロード (URLSessionUploadTaskを使用してメモリを節約)
    static func uploadMedia(serverAddress: String, fileURL: URL, albumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/upload") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        // ヘッダーに情報を付与
        let filename = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "upload"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue(albumID, forHTTPHeaderField: "X-Album-Id")
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }
        
        // uploadタスクでファイルを送信
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

struct RemoteAlbumInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let videoCount: Int
    let type: String?
}

struct RemoteVideoInfo: Codable, Identifiable, Hashable {
    let id: String
    let filename: String
    let duration: TimeInterval
    let importDate: Date
    let creationDate: Date?
    let mediaType: String?
    
    var isPhoto: Bool {
        return mediaType == "photo"
    }
}

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

    /// ユーザーが入力したPINを保存し、再取得を試みる
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
