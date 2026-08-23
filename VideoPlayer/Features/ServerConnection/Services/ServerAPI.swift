import Foundation
import MediaServerKit

// MARK: - API通信マネージャー
enum ServerAPI {

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

    static func deleteVideosCompletely(serverAddress: String, videoIDs: [String]) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/deleteVideosCompletely") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let pin = ServerAuth.pin(for: serverAddress) { request.setValue(pin, forHTTPHeaderField: "X-Auth-PIN") }

        struct DelReq: Codable { let videoIds: [String] }
        let body = DelReq(videoIds: videoIDs)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // URLSessionUploadTaskを使用してメモリを節約
    static func uploadMedia(serverAddress: String, fileURL: URL, albumID: String) async throws -> Bool {
        guard let url = URL(string: "\(serverAddress)/upload") else { return false }

        // サーバー（Swifter）はボディを全てメモリへ展開してから処理するため、
        // 上限超過のファイルを送りつけるとサーバー側でメモリ枯渇の危険がある。
        // 上限は /server/status で公開されているので、送信前にこちらで弾く。
        if let limit = await fetchMaxUploadBytes(serverAddress: serverAddress), limit > 0 {
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize > limit {
                print("⚠️ [UPLOAD] \(fileURL.lastPathComponent) はサーバーの上限（\(limit) bytes）を超えているため送信しません")
                return false
            }
        }

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

    /// 差分動画の探索結果を取り出す。
    ///
    /// 検出はサーバー側で行う。実ファイルを持っているのは Mac だけで、
    /// フレームを時刻ぴったりで何枚も起こす処理をこちらへ持ってくる術がない。
    /// 指紋づくりに時間がかかるぶん `state` が `scanning` で返ることがあるので、
    /// `ready` になるまで少し間を空けて何度か呼ぶ（`groups` は途中でも入っている）。
    static func fetchVariantScan(
        serverAddress: String,
        albumID: String
    ) async throws -> RemoteVariantScanResult {
        guard let url = URL(string: "\(serverAddress)/albums/\(albumID)/variants") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(
            for: ServerAuth.request(url, address: serverAddress)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteVariantScanResult.self, from: data)
    }

    /// サーバーが受け付けるアップロード上限（バイト）。取得できなければ nil（チェックはスキップ）。
    private static func fetchMaxUploadBytes(serverAddress: String) async -> Int? {
        struct StatusData: Codable { let maxUploadBytes: Int? }
        guard let url = URL(string: "\(serverAddress)/server/status") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress)),
              let status = try? JSONDecoder().decode(StatusData.self, from: data) else { return nil }
        return status.maxUploadBytes
    }
}
