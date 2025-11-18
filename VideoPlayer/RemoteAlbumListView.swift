import SwiftUI

// ===================================
//  RemoteAlbumListView.swift (修正版)
// ===================================

/// サーバー上のアルバムを一覧表示するView
struct RemoteAlbumListView: View {
    let serverName: String
    let serverAddress: String
    
    @State private var albums: [RemoteAlbumInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("アルバムを読み込み中...")
            } else if let errorMessage = errorMessage {
                Text(errorMessage)
            } else {
                List(albums) { album in
                    NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: album.id)) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.yellow)
                            Text(album.name)
                        }
                    }
                }
            }
        }
        .navigationTitle(serverName)
        .task {
            await fetchAlbumsFromServer()
        }
    }
    
    private func fetchAlbumsFromServer() async {
        guard let url = URL(string: "\(serverAddress)/albums") else {
            errorMessage = "無効なサーバーアドレスです。"
            isLoading = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            self.albums = try JSONDecoder().decode([RemoteAlbumInfo].self, from: data)
        } catch {
            errorMessage = "アルバムリストの取得に失敗しました。\n\(error.localizedDescription)"
        }
        isLoading = false
    }
}
