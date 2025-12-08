import Foundation
import Network

// ===================================
//  ServerModels.swift
// ===================================

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
    // ★ ここが重要：サーバーからタイプを受け取る
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
    
    func fetchAlbums(serverAddress: String) async {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: "\(serverAddress)/albums") else {
            errorMessage = "無効なサーバーアドレスです。"
            isLoading = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.albums = try decoder.decode([RemoteAlbumInfo].self, from: data)
        } catch {
            errorMessage = "サーバーアルバムの取得に失敗しました。"
        }
        isLoading = false
    }
}
