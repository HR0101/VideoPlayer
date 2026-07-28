import SwiftUI
import MediaServerKit
import Photos

// MARK: - Information Sheet
struct VideoInfoSheetView: View {
    let video: RemoteVideoInfo
    let serverAddress: String
    @Environment(\.dismiss) var dismiss
    var downloadManager: DownloadManager?

    private let bgGradient = LinearGradient(
        colors: [Color.appDarkBackground, Color.appDarkSurface],
        startPoint: .top,
        endPoint: .bottom
    )
    private let accentColor = Color.appGold

    init(video: RemoteVideoInfo, serverAddress: String, downloadManager: DownloadManager? = nil) {
        self.video = video
        self.serverAddress = serverAddress
        self.downloadManager = downloadManager
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    RemoteVideoThumbnailView(
                        thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)"),
                        duration: video.duration
                    )
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 10)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                    Button(action: startDownload) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("写真アプリに保存").fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(AppTheme.goldGradient)
                        .foregroundColor(Color.appDarkBackground)
                        .clipShape(Capsule())
                        .shadow(color: accentColor.opacity(0.3), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(PressableCardStyle(scale: 0.97))
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 16) {
                        InfoRow(title: "ファイル名", value: video.filename, isMain: true)
                        Divider().background(Color.white.opacity(0.2))
                        HStack {
                            if !video.isPhoto {
                                VStack(alignment: .leading) {
                                    Text("長さ").font(.caption).foregroundColor(.white.opacity(0.6))
                                    Text(formatDuration(video.duration))
                                        .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                                }
                                Spacer()
                            }
                            VStack(alignment: .leading) {
                                Text("インポート日").font(.caption).foregroundColor(.white.opacity(0.6))
                                Text(video.importDate, style: .date)
                                    .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                            }
                            if !video.isPhoto { Spacer() }
                        }
                        if let creationDate = video.creationDate {
                            Divider().background(Color.white.opacity(0.2))
                            VStack(alignment: .leading) {
                                Text("撮影日時").font(.caption).foregroundColor(.white.opacity(0.6))
                                Text(creationDate, style: .date)
                                    .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                            }
                        }
                        Divider().background(Color.white.opacity(0.2))
                        InfoRow(title: "種類", value: video.isPhoto ? "画像" : "動画", isMain: false)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    .padding(.horizontal, 20)

                    Spacer(minLength: 40)
                }
            }
            .background(bgGradient.ignoresSafeArea())
            .navigationTitle("詳細情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") { dismiss() }
                        .font(.body.weight(.bold))
                        .foregroundColor(accentColor)
                }
            }
        }
    }

    private func startDownload() {
        guard let url = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(video.id)") else { return }
        downloadManager?.startDownload(url: url, filename: video.filename, isPhoto: video.duration == 0)
        dismiss()
    }

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let s = Int(totalSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private struct InfoRow: View {
        let title: String
        let value: String
        var isMain: Bool = false

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                Text(value)
                    .font(isMain ? .headline.weight(.bold) : .subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Shake Gesture Components
