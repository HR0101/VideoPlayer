import SwiftUI
import AVKit

// ===================================
//  LocalVideoThumbnailView.swift
// ===================================
// ローカルのビデオURLからサムネイルを生成して表示します。

struct LocalVideoThumbnailView: View {
    let url: URL
    @EnvironmentObject var appSettings: AppSettings
    @State private var thumbnail: UIImage?
    @State private var duration: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .center) {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .foregroundColor(.gray.opacity(0.3))
                        .overlay(ProgressView())
                }
            }
            
            if let duration = duration {
                Text(duration)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0))
                    .cornerRadius(4)
                    .padding(4)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .aspectRatio(1, contentMode: .fit)
        .onAppear(perform: generateThumbnailAndDuration)
        .onChange(of: appSettings.thumbnailOption) { _ in generateThumbnailAndDuration() }
    }

    private func generateThumbnailAndDuration() {
        let asset = AVURLAsset(url: url)
        Task {
            let loadedDuration = try? await asset.load(.duration)
            let formattedDuration = formatDuration(loadedDuration)
            
            var time: CMTime
            switch appSettings.thumbnailOption {
            case .initial:
                time = CMTime(seconds: 1, preferredTimescale: 60)
            case .threeSeconds:
                time = CMTime(seconds: 3, preferredTimescale: 60)
            case .tenSeconds:
                time = CMTime(seconds: 10, preferredTimescale: 60)
            case .midpoint:
                let durationSeconds = loadedDuration?.seconds ?? 0
                time = CMTime(seconds: durationSeconds / 2, preferredTimescale: 60)
            case .random:
                let durationSeconds = loadedDuration?.seconds ?? 1
                let randomSecond = Double.random(in: 0...max(0, durationSeconds - 1))
                time = CMTime(seconds: randomSecond, preferredTimescale: 60)
            }
            
            let generatedThumbnail = await ThumbnailGenerator.generateThumbnail(for: asset, at: time)
            
            await MainActor.run {
                self.thumbnail = generatedThumbnail
                self.duration = formattedDuration
            }
        }
    }

    private func formatDuration(_ cmTime: CMTime?) -> String {
        guard let cmTime = cmTime, !CMTimeGetSeconds(cmTime).isNaN else { return "" }
        let totalSeconds = Int(CMTimeGetSeconds(cmTime))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
