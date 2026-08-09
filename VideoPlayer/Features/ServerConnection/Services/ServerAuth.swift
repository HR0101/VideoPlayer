import Foundation

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
