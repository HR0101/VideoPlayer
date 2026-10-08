import SwiftUI
import AVKit

// MARK: - Reusable UI Components

/// AlbumListViewの行コンポーネント
struct AlbumRow: View {
    let albumType: AlbumType

    var body: some View {
        HStack {
            Image(systemName: albumType.systemIcon ?? "folder")
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
            Text(albumType.displayName)
        }
    }
}

// MARK: LocalVideoThumbnailView
/// ビデオURLからサムネイルを非同期で生成して表示するビュー (エラー修正版)
struct LocalVideoThumbnailView: View {
    let videoURL: URL
    @EnvironmentObject var appSettings: AppSettings
    
    @State private var thumbnailImage: UIImage?
    @State private var duration: TimeInterval?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // サムネイル生成中はプレースホルダーを表示
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                ProgressView()
            }
            
            if let duration = duration {
                Text(duration.formattedString)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(4)
            }
        }
        // .taskモディファイアを使用して非同期処理を実行.
        // idが変わるとタスクがキャンセルされ、再実行される.
        .task(id: appSettings.thumbnailOption) {
            await generateThumbnail()
        }
    }
    
    @MainActor // この関数内の状態更新がすべてメインスレッドで行われることを保証
    private func generateThumbnail() async {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        let time = appSettings.thumbnailOption.time
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            self.thumbnailImage = UIImage(cgImage: cgImage)
            
            // ビデオの長さを非同期で取得
            let durationValue = try? await asset.load(.duration)
            self.duration = durationValue?.seconds
            
        } catch {
            print("サムネイルの生成に失敗しました: \(error.localizedDescription)")
            self.thumbnailImage = UIImage(systemName: "exclamationmark.triangle")
        }
    }
}


// MARK: - Helper Views & Extensions

/// ビューが空の状態を示すための汎用ビュー
struct EmptyStateView: View {
    let message: String
    let systemImage: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text(message)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
