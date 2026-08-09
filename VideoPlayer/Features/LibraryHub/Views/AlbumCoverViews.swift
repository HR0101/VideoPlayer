import SwiftUI
import MediaServerKit

struct RadarPulseView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.appGold.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 50, height: 50)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 2.2)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.7),
                        value: animate
                    )
            }

            Image(systemName: "wifi")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(AppTheme.goldGradient)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .frame(width: 56, height: 56)
                .background(Color.appDarkSurface.opacity(0.8))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.appGold.opacity(0.3), lineWidth: 1))
        }
        .onAppear { animate = true }
    }
}

// MARK: - カバー表示用コンポーネント

struct LocalAlbumCoverView: View {
    let albumType: AlbumType
    let videoManager: LocalLibraryViewModel
    let icon: String
    let color: Color
    var onCount: ((Int) -> Void)? = nil

    @State private var coverURL: URL?
    @State private var hasFetched = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.appDarkSurface.ignoresSafeArea()

                if let url = coverURL {
                    LocalVideoThumbnailView(url: url)
                        .allowsHitTesting(false) // タップ判定を親に譲る
                } else {
                    Image(systemName: icon)
                        .font(.system(size: proxy.size.width * 0.34, weight: .light))
                        .foregroundStyle(color.opacity(0.5))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            if !hasFetched {
                hasFetched = true
                Task {
                    let urls = await videoManager.fetchVideos(for: albumType)
                    coverURL = urls.first
                    onCount?(urls.count)
                }
            }
        }
    }
}

struct ServerAlbumCoverView: View {
    let serverAddress: String
    /// `/albums` 応答に含まれる表紙用の動画ID。以前はここで全動画リストJSONを
    /// 取得して先頭IDだけ使っていたが、サーバーが返す値をそのまま使うことで
    /// アルバム画面表示時のMB級の通信を丸ごと省く。
    let coverVideoID: String?
    let icon: String
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.appDarkSurface.ignoresSafeArea()

                if let vid = coverVideoID {
                    AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(vid)")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        case .failure:
                            fallbackIcon(size: proxy.size.width * 0.34)
                        default:
                            SkeletonCard(cornerRadius: 0)
                        }
                    }
                } else {
                    fallbackIcon(size: proxy.size.width * 0.34)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func fallbackIcon(size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(color.opacity(0.5))
    }
}

/// フォルダ（子アルバムを持つノード）の表紙。既知の coverVideoID があれば
/// そのサムネイルを直接表示し、無ければ従来のフォルダアイコンにフォールバックする。
struct ServerFolderCoverView: View {
    let serverAddress: String
    let coverVideoID: String?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let vid = coverVideoID {
                    Color.appDarkSurface
                    AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(vid)")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        case .failure:
                            folderPlaceholder(size: proxy.size.width * 0.34)
                        default:
                            SkeletonCard(cornerRadius: 0)
                        }
                    }
                } else {
                    folderPlaceholder(size: proxy.size.width * 0.34)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func folderPlaceholder(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [color.opacity(0.35), Color.appDarkSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "folder.fill")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(color)
        }
    }
}

/// フォルダ（子アルバムを持つ）であることを示す小さな印。表紙の左上に重ねる。
struct FolderBadge: View {
    var body: some View {
        Image(systemName: "folder.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
