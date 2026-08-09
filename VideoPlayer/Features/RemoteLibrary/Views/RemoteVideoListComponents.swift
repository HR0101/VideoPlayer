import SwiftUI

struct RemoteVideoThumbnailView: View {
    let thumbnailURL: URL?
    let duration: TimeInterval
    var contentMode: ContentMode = .fill
    var forceSquare: Bool = true

    var body: some View {
        let content = ZStack {
            Rectangle().fill(Color.appDarkSurface)
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                case .failure:
                    Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.2))
                default:
                    SkeletonCard(cornerRadius: 0)
                }
            }
        }
        
        Group {
            if forceSquare {
                content.aspectRatio(1, contentMode: .fit)
            } else {
                content
            }
        }
        .overlay(alignment: .bottom) {
            if duration > 0 {
                LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.7)]), startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 4)
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 {
                Text(duration.mediaDurationText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
