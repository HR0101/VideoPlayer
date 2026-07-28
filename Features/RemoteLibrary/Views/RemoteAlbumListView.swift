import SwiftUI
import MediaServerKit

struct RemoteAlbumListView: View {
    let serverName: String
    let serverAddress: String

    @State private var albums: [RemoteAlbumInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let primaryDarkColor = Color.appDarkBackground

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
                            if let allPhotos = albums.first(where: { $0.name == "ALL PHOTOS" }) {
                                albumRow(album: allPhotos, icon: "photo.stack.fill", color: .orange)
                            }
                        }
                    }

                    let userAlbums = albums.filter {
                        $0.name != "ALL VIDEOS" &&
                        $0.name != "ALL PHOTOS" &&
                        $0.type != "mixed"
                    }

                    let photoAlbums = userAlbums.filter { $0.type == "photo" }
                    let photoAlbumNodes = buildAlbumTree(from: photoAlbums)
                    if !photoAlbumNodes.isEmpty {
                        Section("画像アルバム") {
                            ForEach(photoAlbumNodes) { node in
                                NodeRowView(node: node, serverAddress: serverAddress, allAlbums: albums, icon: "photo.on.rectangle.fill", color: .orange)
                            }
                        }
                    }

                    // typeがnilの古いアルバムは動画アルバムとして扱う
                    let videoAlbums = userAlbums.filter { ($0.type == "video" || $0.type == nil) && $0.videoCount > 0 }
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

    private func albumRow(album: RemoteAlbumInfo, icon: String, color: Color) -> some View {
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
                    .background(Color.appDarkElevated)
                    .cornerRadius(4)
            }
        }
        .listRowBackground(Color.appDarkSurface)
        .listRowSeparatorTint(Color.white.opacity(0.2))
    }

    private func buildAlbumTree(from albums: [RemoteAlbumInfo]) -> [AlbumNode] {
        class NodeBuilder {
            var id: String
            var name: String
            var album: RemoteAlbumInfo?
            var children: [String: NodeBuilder] = [:]

            init(id: String, name: String) {
                self.id = id
                self.name = name
            }

            func toTreeNode() -> AlbumNode {
                let sortedChildren = children.values.map { $0.toTreeNode() }.sorted { $0.name < $1.name }
                return AlbumNode(
                    id: id,
                    name: name,
                    album: album,
                    children: sortedChildren.isEmpty ? nil : sortedChildren
                )
            }
        }

        let root = NodeBuilder(id: "root", name: "root")

        for album in albums {
            let parts = album.name
                .components(separatedBy: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }

            var current = root
            var currentPath = ""

            for (index, part) in parts.enumerated() {
                currentPath += (currentPath.isEmpty ? "" : "/") + part
                if current.children[part] == nil {
                    current.children[part] = NodeBuilder(id: currentPath, name: part)
                }
                current = current.children[part]!
                if index == parts.count - 1 {
                    current.album = album
                }
            }
        }

        return root.children.values.map { $0.toTreeNode() }.sorted { $0.name < $1.name }
    }

    private func fetchAlbumsFromServer() async {
        guard let url = URL(string: "\(serverAddress)/albums") else {
            errorMessage = "無効なサーバーアドレスです。"
            isLoading = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: ServerAuth.request(url, address: serverAddress))
            self.albums = try JSONDecoder().decode([RemoteAlbumInfo].self, from: data)
        } catch {
            errorMessage = "アルバムリストの取得に失敗しました。\n\(error.localizedDescription)"
        }
        isLoading = false
    }
}
