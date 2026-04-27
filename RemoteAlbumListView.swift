import SwiftUI



struct RemoteAlbumListView: View {
    let serverName: String
    let serverAddress: String
    
    @State private var albums: [RemoteAlbumInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // 色定義
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1)
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("アルバムを読み込み中...")
                    .tint(.white)
            } else if let errorMessage = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .padding()
                    Text(errorMessage)
                }
                .foregroundColor(.white)
            } else {
                List {
                    
                    if let mixed = albums.first(where: { $0.name == "ALL VIDEOS" || $0.type == "mixed" }) {
                        Section("ライブラリ") {
                            albumRow(album: mixed, icon: "square.stack.fill", color: .yellow)
                        }
                    }
                    
                    let userAlbums = albums.filter { $0.name != "ALL VIDEOS" && $0.type != "mixed" }

                    let photoAlbums = userAlbums.filter { $0.type == "photo" }
                    if !photoAlbums.isEmpty {
                        Section("画像アルバム") {
                            ForEach(photoAlbums) { album in
                                albumRow(album: album, icon: "photo.on.rectangle.fill", color: .orange)
                            }
                        }
                    }
                    

                    let videoAlbums = userAlbums.filter { $0.type == "video" || $0.type == nil }
                    if !videoAlbums.isEmpty {
                        Section("動画アルバム") {
                            ForEach(videoAlbums) { album in
                                albumRow(album: album, icon: "folder.fill", color: .cyan)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(primaryDarkColor.ignoresSafeArea())
            }
        }
        .navigationTitle(serverName)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(primaryDarkColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .refreshable {
            await fetchAlbumsFromServer()
        }
        .task {
            await fetchAlbumsFromServer()
        }
    }
    
    // 行のデザインを統一
    private func albumRow(album: RemoteAlbumInfo, icon: String, color: Color) -> some View {
        // ★ 修正: allServerAlbums: albums を引数に追加しました
        NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: album.id, allServerAlbums: albums)) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)
                Text(album.name)
                    .foregroundColor(.primary)
                    .fontWeight(.medium)
                Spacer()
                Text("\(album.videoCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .listRowBackground(Color(white: 0.15))
        .listRowSeparatorTint(Color.white.opacity(0.2))
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
            for album in self.albums {
                print("📦 Album: \(album.name), Type: \(album.type ?? "nil")")
            }
        } catch {
            errorMessage = "アルバムリストの取得に失敗しました。\n\(error.localizedDescription)"
        }
        isLoading = false
    }
}
