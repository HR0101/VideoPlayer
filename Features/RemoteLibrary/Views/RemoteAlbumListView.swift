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

struct AlbumNode: Identifiable {
    let id: String
    let name: String
    var album: RemoteAlbumInfo?
    var children: [AlbumNode]?

    var totalVideoCount: Int {
        let ownCount = album?.videoCount ?? 0
        let childCount = children?.reduce(0) { $0 + $1.totalVideoCount } ?? 0
        return ownCount + childCount
    }

    /// 自身のアルバム、無ければ子孫を辿って最初に見つかった代表サムネイルの動画ID。
    /// 子アルバムを持つフォルダノードの表紙サムネイルに使う。
    var coverVideoID: String? {
        if let id = album?.coverVideoID { return id }
        guard let children else { return nil }
        for child in children {
            if let id = child.coverVideoID { return id }
        }
        return nil
    }
}

struct RemoteAlbumFolderView: View {
    let title: String
    let serverAddress: String
    let parentAlbum: RemoteAlbumInfo?
    let nodes: [AlbumNode]
    let allAlbums: [RemoteAlbumInfo]
    let icon: String
    let color: Color

    @AppStorage("remoteAlbumFolderIsGridMode") private var isGridMode = true

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)
    ]

    var body: some View {
        Group {
            if isGridMode {
                gridContent
            } else {
                listContent
            }
        }
        .background(AppBackground())
        .navigationTitle(title)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isGridMode.toggle()
                } label: {
                    Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(isGridMode ? "リスト表示に切り替え" : "グリッド表示に切り替え")
            }
        }
    }

    private var listContent: some View {
        List {
            if let album = parentAlbum, album.videoCount > 0 {
                parentAlbumRow(album: album)
            }

            ForEach(nodes) { node in
                NodeRowView(node: node, serverAddress: serverAddress, allAlbums: allAlbums, icon: icon, color: color)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                if let album = parentAlbum, album.videoCount > 0 {
                    RemoteAlbumFolderGridCell(
                        title: "このフォルダ内",
                        count: album.videoCount,
                        cover: .album(coverVideoID: album.coverVideoID, serverAddress: serverAddress, icon: icon, color: color),
                        destination: AnyView(RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: album.id, allServerAlbums: allAlbums))
                    )
                }

                ForEach(nodes) { node in
                    RemoteAlbumFolderGridNodeCell(node: node, serverAddress: serverAddress, allAlbums: allAlbums, icon: icon, color: color)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private func parentAlbumRow(album: RemoteAlbumInfo) -> some View {
        NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: album.id, allServerAlbums: allAlbums)) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)
                Text("このフォルダ内のメディア")
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
}

struct RemoteAlbumFolderGridNodeCell: View {
    let node: AlbumNode
    let serverAddress: String
    let allAlbums: [RemoteAlbumInfo]
    let icon: String
    let color: Color

    var body: some View {
        if let children = node.children, !children.isEmpty {
            RemoteAlbumFolderGridCell(
                title: node.name,
                count: node.totalVideoCount,
                cover: .folder(coverVideoID: node.coverVideoID, serverAddress: serverAddress, color: .orange),
                destination: AnyView(RemoteAlbumFolderView(title: node.name, serverAddress: serverAddress, parentAlbum: node.album, nodes: children, allAlbums: allAlbums, icon: icon, color: color))
            )
        } else if let album = node.album, album.videoCount > 0 {
            RemoteAlbumFolderGridCell(
                title: node.name,
                count: album.videoCount,
                cover: .album(coverVideoID: album.coverVideoID, serverAddress: serverAddress, icon: icon, color: color),
                destination: AnyView(RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: album.id, allServerAlbums: allAlbums))
            )
        }
    }
}

struct RemoteAlbumFolderGridCell: View {
    enum Cover {
        case album(coverVideoID: String?, serverAddress: String, icon: String, color: Color)
        case folder(coverVideoID: String?, serverAddress: String, color: Color)

        var isFolder: Bool {
            if case .folder = self { return true }
            return false
        }
    }

    let title: String
    let count: Int
    let cover: Cover
    let destination: AnyView

    var body: some View {
        NavigationLink(destination: destination) {
            coverView
                .aspectRatio(1, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .overlay(AppTheme.bottomScrim)
                .overlay(alignment: .bottomLeading) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    CountBadge(count: count)
                        .padding(10)
                }
                .overlay(alignment: .topLeading) {
                    if cover.isFolder {
                        FolderBadge()
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PressableCardStyle())
    }

    @ViewBuilder
    private var coverView: some View {
        switch cover {
        case .album(let coverVideoID, let serverAddress, let icon, let color):
            ServerAlbumCoverView(serverAddress: serverAddress, coverVideoID: coverVideoID, icon: icon, color: color)
        case .folder(let coverVideoID, let serverAddress, let color):
            ServerFolderCoverView(serverAddress: serverAddress, coverVideoID: coverVideoID, color: color)
        }
    }
}

struct NodeRowView: View {
    let node: AlbumNode
    let serverAddress: String
    let allAlbums: [RemoteAlbumInfo]
    let icon: String
    let color: Color

    var body: some View {
        if let children = node.children, !children.isEmpty {
            NavigationLink(destination: RemoteAlbumFolderView(title: node.name, serverAddress: serverAddress, parentAlbum: node.album, nodes: children, allAlbums: allAlbums, icon: icon, color: color)) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.yellow)
                        .frame(width: 24)
                    Text(node.name)
                        .foregroundColor(.primary)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(node.totalVideoCount)")
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
        } else if let album = node.album, album.videoCount > 0 {
            NavigationLink(destination: RemoteVideoListView(serverName: album.name, serverAddress: serverAddress, albumID: album.id, allServerAlbums: allAlbums)) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .frame(width: 24)
                    Text(node.name)
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
    }
}
