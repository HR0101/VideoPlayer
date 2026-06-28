import SwiftUI
import MediaServerKit
import AVFoundation

class AppNavigationState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var targetShortsVideo: RemoteVideoInfo? = nil
    @Published var shortsJumpTrigger: UUID = UUID()
}

@main
struct VideoPlayerApp: App {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var serverBrowser = ServerBrowser()
    @StateObject private var serverManager = ServerManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var navState = AppNavigationState()

    init() {
        // 動画アプリとして、端末のサイレント（消音）スイッチに関係なく音声を再生する。
        // これを設定しないと既定が .soloAmbient になり、消音モード時にアプリ全体で音が出なくなる。
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession の設定に失敗: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                MainTabView()
                    .environmentObject(appSettings)
                    .environmentObject(serverBrowser)
                    .environmentObject(serverManager)
                    .environmentObject(downloadManager)
                    .environmentObject(navState)

                if downloadManager.isDownloading || downloadManager.successMessage != nil || downloadManager.errorMessage != nil {
                    DownloadStatusOverlay()
                        .environmentObject(downloadManager)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(100)
                }
            }
        }
    }
}

struct DownloadStatusOverlay: View {
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        VStack(spacing: 10) {
            if let errorMsg = downloadManager.errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMsg)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { withAnimation { downloadManager.errorMessage = nil } }) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: AppTheme.radiusM)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                )
                .environment(\.colorScheme, .dark)
                .padding(.horizontal)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation { downloadManager.errorMessage = nil }
                    }
                }
            }

            if let successMsg = downloadManager.successMessage {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: successMsg)
                    Text(successMsg)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(14)
                .glassCard(cornerRadius: AppTheme.radiusM)
                .environment(\.colorScheme, .dark)
                .padding(.horizontal)
            }

            if downloadManager.isDownloading {
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("ダウンロード中…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.appTextSecondary)
                            Spacer()
                            Text("\(Int(downloadManager.progress * 100))%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.appGold)
                        }

                        Text(downloadManager.currentFilename)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        ProgressView(value: downloadManager.progress)
                            .progressViewStyle(.linear)
                            .tint(Color.appGold)
                    }

                    Button(action: { downloadManager.cancelDownload() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: AppTheme.radiusM)
                .environment(\.colorScheme, .dark)
                .padding(.horizontal)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: downloadManager.isDownloading)
    }
}
