// ===================================
//  LocalVideoThumbnailView.swift
// ===================================
// ローカルのビデオURLからサムネイルを生成して表示します。

import SwiftUI
import AVKit

struct LocalVideoThumbnailView: View {
    let url: URL
    // isFavorite プロパティを削除
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
            
            VStack(spacing: 2) {
                Spacer()
                HStack {
                    // isFavorite のアイコン表示ロジックを削除
                    Spacer()
                    if let duration = duration {
                        Text(duration).font(.caption2.bold()).foregroundColor(.white)
                    }
                }
            }
            .padding(4)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
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
            
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            
            var time: CMTime
            switch appSettings.thumbnailOption {
            case .initial:
                time = CMTime(seconds: 1, preferredTimescale: 60)
            case .threeSeconds:
                time = CMTime(seconds: 3, preferredTimescale: 60)
            case .tenSeconds:
                time = CMTime(seconds: 10, preferredTimescale: 60)
            case .midpoint:
                if let videoDuration = loadedDuration, videoDuration.seconds > 0 {
                    time = CMTime(seconds: videoDuration.seconds / 2, preferredTimescale: 60)
                } else { time = CMTime(seconds: 1, preferredTimescale: 60) }
            case .random:
                if let videoDuration = loadedDuration, videoDuration.seconds > 1 {
                    let randomSecond = Double.random(in: 0...max(0, videoDuration.seconds - 1))
                    time = CMTime(seconds: randomSecond, preferredTimescale: 60)
                } else { time = CMTime(seconds: 0, preferredTimescale: 60) }
            }
            
            let cgImage = try? await generator.image(at: time).image
            await MainActor.run {
                if let cgImage = cgImage { self.thumbnail = UIImage(cgImage: cgImage) }
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
