import Foundation

enum RemoteControlServiceError: LocalizedError {
  case invalidServerAddress
  case authenticationRequired
  case invalidResponse
  case serverRejected(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidServerAddress:
      return "サーバーアドレスが正しくありません．"
    case .authenticationRequired:
      return "MacサーバーのPIN認証が必要です．アルバムタブでPINを入力してください．"
    case .invalidResponse:
      return "Macサーバーから正しい応答を受信できませんでした．"
    case .serverRejected(_, let message):
      return message
    }
  }
}

enum RemoteControlService {
  private static let requestTimeout: TimeInterval = 10

  static func fetchState(serverAddress: String) async throws -> RemotePlaybackState {
    let request = try makeRequest(
      serverAddress: serverAddress,
      path: "/remote/playback",
      method: "GET"
    )
    let data = try await execute(request)
    do {
      return try JSONDecoder().decode(RemotePlaybackState.self, from: data)
    } catch {
      throw RemoteControlServiceError.invalidResponse
    }
  }

  static func send(
    _ command: RemoteControlCommand,
    serverAddress: String
  ) async throws -> RemotePlaybackState {
    var request = try makeRequest(
      serverAddress: serverAddress,
      path: "/remote/playback/command",
      method: "POST"
    )
    request.httpBody = try JSONEncoder().encode(command)
    let data = try await execute(request)
    do {
      return try JSONDecoder().decode(RemotePlaybackState.self, from: data)
    } catch {
      throw RemoteControlServiceError.invalidResponse
    }
  }

  static func open(
    videoID: String,
    albumID: String?,
    serverAddress: String
  ) async throws {
    var request = try makeRequest(
      serverAddress: serverAddress,
      path: "/remote/playback/open",
      method: "POST"
    )
    request.httpBody = try JSONEncoder().encode(
      RemotePlaybackOpenCommand(videoID: videoID, albumID: albumID)
    )
    _ = try await execute(request)
  }

  private static func makeRequest(
    serverAddress: String,
    path: String,
    method: String
  ) throws -> URLRequest {
    guard let url = URL(string: serverAddress + path) else {
      throw RemoteControlServiceError.invalidServerAddress
    }
    var request = ServerAuth.request(url, address: serverAddress, method: method)
    request.timeoutInterval = requestTimeout
    if method != "GET" {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private static func execute(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw RemoteControlServiceError.invalidResponse
    }
    if httpResponse.statusCode == 401 {
      throw RemoteControlServiceError.authenticationRequired
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let serverMessage = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let message = serverMessage.flatMap { message in
        message.isEmpty ? nil : message
      } ?? "Macサーバーが操作を受け付けませんでした．"
      throw RemoteControlServiceError.serverRejected(
        statusCode: httpResponse.statusCode,
        message: message
      )
    }
    return data
  }
}
