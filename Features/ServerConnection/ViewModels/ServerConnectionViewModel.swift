import Foundation
import MediaServerKit

// MARK: - Server Data Models
// RemoteAlbumInfo / RemoteVideoInfo は MediaServerKit に集約（Mac サーバーと共有）

@MainActor
final class ServerConnectionViewModel: ObservableObject {
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
                // サムネイルには Cache-Control（1時間）が付いているため、認証が無効になっても
                // キャッシュ済み画像は表示され続けてしまう。認証切れを検知したこのタイミングで
                // HTTPキャッシュを破棄し、「締め出されたのに画像だけ見える」状態を防ぐ。
                URLCache.shared.removeAllCachedResponses()
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
