import Foundation
import Network

// ===================================
//  ServerModels.swift (修正版)
// ===================================
// サーバーとの通信や発見に関する、共有データモデルを全て定義します。

// MARK: - Bonjour / Server Discovery

/// 発見したサーバーの情報を保持するデータ形式
struct DiscoveredServer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let service: NetService
    var address: String?
}

/// Bonjourサービスを検索・解決するクラス
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
              let index = discoveredServers.firstIndex(where: { $0.service == sender }) else {
            return
        }
        
        // ★ 修正: ハードコードされたポート番号をやめ、Bonjourサービスから解決した正しいポート番号を使用します。
        let port = sender.port
        let addressString = "http://\(host):\(port)"
        
        // メインスレッドでdiscoveredServersを更新します
        DispatchQueue.main.async {
            // 配列のインデックスが存在するか再度確認
            guard self.discoveredServers.indices.contains(index) else { return }
            self.discoveredServers[index].address = addressString
            print("✅ サーバーを発見し、アドレスを解決しました: \(addressString)")
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("❌ サーバーのアドレス解決に失敗しました \(sender.name): \(errorDict)")
        // 解決に失敗したサーバーをリストから削除
        discoveredServers.removeAll { $0.service == sender }
    }
}

// MARK: - Server Data Models

/// サーバーから受け取るアルバム情報のデータ形式
struct RemoteAlbumInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    // ★ 追加: Macアプリから送られてくる動画の数
    let videoCount: Int
}

/// 発見したサーバーとそのアルバムを管理するためのクラス
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
            decoder.dateDecodingStrategy = .iso8601 // Mac側と日付の形式を合わせる
            self.albums = try decoder.decode([RemoteAlbumInfo].self, from: data)
        } catch {
            errorMessage = "サーバーアルバムの取得に失敗しました。"
            print(error.localizedDescription)
        }
        isLoading = false
    }
}
