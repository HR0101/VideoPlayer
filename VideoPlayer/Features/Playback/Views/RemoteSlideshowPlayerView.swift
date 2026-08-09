import SwiftUI
import AVKit
import MediaServerKit

struct SmartVideoPanView: View {
    let player: AVPlayer
    let videoSize: CGSize
    let scaleParam: Double
    
    var body: some View {
        if scaleParam > 0 {
            GeometryReader { geo in
                let viewAspect = geo.size.width / geo.size.height
                let videoAspect = videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : viewAspect
                
                let fillScale: CGFloat = {
                    if videoAspect > viewAspect {
                        return geo.size.height / (geo.size.width / videoAspect)
                    } else {
                        return geo.size.width / (geo.size.height * videoAspect)
                    }
                }()
                
                let finalScale: CGFloat = 1.0 + (fillScale - 1.0) * CGFloat(scaleParam)
                
                PlayerLayerView(player: player, videoGravity: .resizeAspect)
                    .scaleEffect(finalScale)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            PlayerLayerView(player: player, videoGravity: .resizeAspect)
        }
    }
}

private struct FullVideoLaunchRequest: Identifiable {
    let id = UUID()
    let video: RemoteVideoInfo
    let startTime: Double
}

struct RemoteShortsPlayerView: View {
    @StateObject private var model: RemoteShortsViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var navState: AppNavigationState
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: FullVideoLaunchRequest? = nil
    @State private var pageDragOffset: CGFloat = 0
    @State private var isPageTransitioning = false
    @State private var transitionCoverVideo: RemoteVideoInfo?
    
    let videos: [RemoteVideoInfo]
    let allServerAlbums: [RemoteAlbumInfo]
    let initialVideoToPlay: RemoteVideoInfo?
    let initialStartTime: Double?
    var onPlayStateChanged: ((Bool) -> Void)?

    init(videos: [RemoteVideoInfo], serverAddress: String, allServerAlbums: [RemoteAlbumInfo], initialVideoToPlay: RemoteVideoInfo? = nil, initialStartTime: Double? = nil, onPlayStateChanged: ((Bool) -> Void)? = nil) {
        _model = StateObject(wrappedValue: RemoteShortsViewModel(videos: videos, serverAddress: serverAddress, initialVideo: initialVideoToPlay, initialStartTime: initialStartTime))
        self.videos = videos
        self.allServerAlbums = allServerAlbums
        self.initialVideoToPlay = initialVideoToPlay
        self.initialStartTime = initialStartTime
        self.onPlayStateChanged = onPlayStateChanged
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.currentVideo == nil {
                ProgressView().tint(.white)
            } else {
                GeometryReader { geo in
                    ZStack {
                        shortsAdjacentPreviewPages(pageHeight: geo.size.height)
                        currentShortsPage
                            .offset(y: pageDragOffset)
                        if let transitionCoverVideo {
                            ShortsPreviewPage(video: transitionCoverVideo, serverAddress: model.serverAddress)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                .ignoresSafeArea()
            }
        }
        // Vertical swipe to change video
        .gesture(
            DragGesture()
                .onChanged { value in
                    updatePageDrag(value)
                }
                .onEnded { value in
                    finishPageDrag(value)
                }
        )
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.shutdown()
        }
        .toolbar(model.isPlaying ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.isPlaying) { _, isPlaying in
            onPlayStateChanged?(isPlaying)
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading {
                hideTransitionCoverSoon()
            }
        }
        // Sheet for details
        .sheet(isPresented: $showInfoSheet, onDismiss: { if !model.isPlaying { model.togglePlay() } }) {
            if let v = model.currentVideo {
                VideoInfoSheetView(video: v, serverAddress: model.serverAddress, downloadManager: DownloadManager())
            }
        }
        // Fullscreen for jump to original
        .fullScreenCover(item: $jumpToFullVideo, onDismiss: { if !model.isPlaying { model.togglePlay() } }) { request in
            let v = request.video
            NavigationStack {
                RemoteVideoListView(
                    serverName: allServerAlbums.first(where: { $0.id == v.parentAlbumID })?.name ?? "動画",
                    serverAddress: model.serverAddress,
                    albumID: v.parentAlbumID ?? "ALL VIDEOS",
                    allServerAlbums: allServerAlbums,
                    initialVideoToPlay: v,
                    initialStartTime: request.startTime,
                    isPresentedFromShorts: true
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(" ") {
                            jumpToFullVideo = nil
                        }
                        .foregroundColor(.appGold)
                    }
                }
            }
            .presentationBackground(.clear)
        }
        .onChange(of: videos) { _, newVideos in
            model.updateVideos(newVideos)
        }
        .onChange(of: navState.shortsJumpTrigger) { _, _ in
            if let target = navState.targetShortsVideo {
                model.jumpToVideo(target)
            }
        }
    }

    private var currentShortsPage: some View {
        ZStack {
            SmartVideoPanView(player: model.player, videoSize: model.videoSize, scaleParam: appSettings.shortsVideoFillScale)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isPageTransitioning else { return }
                    model.togglePlay()
                }
            
            if model.isLoading {
                ProgressView().tint(.white).scaleEffect(1.5)
            }
            
            if !model.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.8))
                    .allowsHitTesting(false)
            }

            VStack {
                Group {
                    HStack {
                        Button(action: {
                            model.pause()
                            if navState.selectedTab == 1 {
                                navState.selectedTab = 0
                            } else {
                                dismiss()
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                                Text(" ")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        Spacer()
                        if model.currentVideo != nil {
                            Button(action: {
                                model.pause()
                                showInfoSheet = true
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "ellipsis.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                    Text(" ")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                }
                            }
                        }
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)

                    Spacer()

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let v = model.currentVideo {
                                Text(v.filename.cleanVideoTitle)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .shadow(radius: 2)
                                
                                Text(v.importDate, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        
                        Spacer()
                        
                        VStack(spacing: 24) {
                            if let v = model.currentVideo {
                                Button(action: {
                                    Haptics.light()
                                    let isShortsFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                    if isShortsFav {
                                        if let clipId = shortsFavorites.getClipId(videoID: v.id, startTime: model.clipStartTime) {
                                            shortsFavorites.removeClip(id: clipId)
                                        }
                                    } else {
                                        shortsFavorites.addClip(videoID: v.id, startTime: model.clipStartTime, endTime: model.clipStartTime + model.clipDuration)
                                        if !favorites.isFavorite(v.id) {
                                            favorites.toggle(v.id)
                                        }
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        let isFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                        Image(systemName: isFav ? "heart.fill" : "heart")
                                            .font(.title)
                                            .foregroundColor(isFav ? .pink : .white)
                                            .shadow(radius: 2)
                                        Text("いいね")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                }
                                
                                Button(action: {
                                    let startTime = model.currentPlaybackTime
                                    model.pause()
                                    jumpToFullVideo = FullVideoLaunchRequest(video: v, startTime: startTime)
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "play.tv.fill")
                                            .font(.title)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                        Text("本編へ")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
                .opacity(model.isPlaying ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isPlaying)
                
                EfficientShortsSeekBar(
                    progress: model.progress,
                    onScrubUpdate: { percent in model.fastSeek(to: percent) },
                    onScrubEnd: { percent in model.seek(to: percent) },
                    isScrubbing: $model.isScrubbing
                )
                .frame(height: 44)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func shortsAdjacentPreviewPages(pageHeight: CGFloat) -> some View {
        if pageDragOffset > 0, let previous = model.previousPreviewVideo {
            ShortsPreviewPage(video: previous, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset - pageHeight)
        }
        if pageDragOffset < 0, let next = model.nextPreviewVideo {
            ShortsPreviewPage(video: next, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset + pageHeight)
        }
    }

    private func updatePageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else { return }
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        pageDragOffset = value.translation.height
    }

    private func finishPageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else {
            resetPageDrag()
            return
        }
        let threshold: CGFloat = 70
        let predictedHeight = value.predictedEndTranslation.height
        let predictedWidth = value.predictedEndTranslation.width
        guard abs(predictedHeight) > abs(predictedWidth) else {
            resetPageDrag()
            return
        }
        if predictedHeight < -threshold {
            completePageTransition(toNext: true)
        } else if predictedHeight > threshold {
            completePageTransition(toNext: false)
        } else {
            resetPageDrag()
        }
    }

    private func completePageTransition(toNext: Bool) {
        isPageTransitioning = true
        let target = toNext ? -UIScreen.main.bounds.height : UIScreen.main.bounds.height
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            pageDragOffset = target
        }
        let coverVideo = toNext ? model.nextPreviewVideo : model.previousPreviewVideo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            transitionCoverVideo = coverVideo
            if toNext {
                model.next()
            } else {
                model.previous()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageDragOffset = 0
            }
            isPageTransitioning = false
            hideTransitionCoverSoon()
        }
    }

    private func resetPageDrag() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
            pageDragOffset = 0
        }
    }

    private func hideTransitionCoverSoon() {
        guard transitionCoverVideo != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !model.isLoading else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                transitionCoverVideo = nil
            }
        }
    }
}

// MARK: - お気に入りショート用プレイヤーモデル
// MARK: - お気に入りショート用プレイヤービュー
struct RemoteShortsFavoritesPlayerView: View {
    @StateObject private var model: RemoteShortsFavoritesViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appSettings: AppSettings
    
    @ObservedObject private var favorites = FavoritesManager.shared
    @ObservedObject private var shortsFavorites = ShortsFavoritesManager.shared
    @State private var showInfoSheet = false
    @State private var jumpToFullVideo: RemoteVideoInfo? = nil
    @State private var pageDragOffset: CGFloat = 0
    @State private var isPageTransitioning = false
    @State private var transitionCoverVideo: RemoteVideoInfo?
    
    let allServerAlbums: [RemoteAlbumInfo]
    var onPlayStateChanged: ((Bool) -> Void)?

    init(videos: [RemoteVideoInfo], serverAddress: String, allServerAlbums: [RemoteAlbumInfo], initialIndex: Int = 0, onPlayStateChanged: ((Bool) -> Void)? = nil) {
        _model = StateObject(wrappedValue: RemoteShortsFavoritesViewModel(videos: videos, serverAddress: serverAddress, initialIndex: initialIndex))
        self.allServerAlbums = allServerAlbums
        self.onPlayStateChanged = onPlayStateChanged
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.currentVideo == nil {
                if shortsFavorites.clips.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "heart.slash")
                            .font(.system(size: 64))
                            .foregroundColor(.white.opacity(0.3))
                        Text("お気に入りショートはありません")
                            .font(.title3.weight(.medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                GeometryReader { geo in
                    ZStack {
                        shortsAdjacentPreviewPages(pageHeight: geo.size.height)
                        currentFavoriteShortsPage
                            .offset(y: pageDragOffset)
                        if let transitionCoverVideo {
                            ShortsPreviewPage(video: transitionCoverVideo, serverAddress: model.serverAddress)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                .ignoresSafeArea()
            }
        }
        // Vertical swipe to change video
        .gesture(
            DragGesture()
                .onChanged { value in
                    updatePageDrag(value)
                }
                .onEnded { value in
                    finishPageDrag(value)
                }
        )
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
        .toolbar(model.isPlaying ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.isPlaying) { _, isPlaying in
            onPlayStateChanged?(isPlaying)
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading {
                hideTransitionCoverSoon()
            }
        }
    }

    private var currentFavoriteShortsPage: some View {
        ZStack {
            SmartVideoPanView(player: model.player, videoSize: model.videoSize, scaleParam: appSettings.shortsVideoFillScale)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isPageTransitioning else { return }
                    model.togglePlay()
                }
            
            if model.isLoading {
                ProgressView().tint(.white).scaleEffect(1.5)
            }
            
            if !model.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.8))
                    .allowsHitTesting(false)
            }

            VStack {
                if !model.isPlaying {
                    HStack {
                        Button(action: {
                            model.pause()
                            dismiss()
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                                Text(" ")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)
                }
                
                Group {
                    Spacer()

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let v = model.currentVideo {
                                Text(v.filename.cleanVideoTitle)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .shadow(radius: 2)
                            }
                        }
                        
                        Spacer()
                        
                        VStack(spacing: 24) {
                            if let v = model.currentVideo {
                                Button(action: {
                                    Haptics.light()
                                    let isShortsFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                    if isShortsFav, let clipId = shortsFavorites.getClipId(videoID: v.id, startTime: model.clipStartTime) {
                                        shortsFavorites.removeClip(id: clipId)
                                        if shortsFavorites.clips.isEmpty {
                                            dismiss()
                                        }
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        let isFav = shortsFavorites.isFavorite(videoID: v.id, startTime: model.clipStartTime)
                                        Image(systemName: isFav ? "heart.fill" : "heart")
                                            .font(.title)
                                            .foregroundColor(isFav ? .pink : .white)
                                            .shadow(radius: 2)
                                        Text("いいね")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
                .opacity(model.isPlaying ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isPlaying)
                
                EfficientShortsSeekBar(
                    progress: model.progress,
                    onScrubUpdate: { percent in model.fastSeek(to: percent) },
                    onScrubEnd: { percent in model.seek(to: percent) },
                    isScrubbing: $model.isScrubbing
                )
                .frame(height: 44)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func shortsAdjacentPreviewPages(pageHeight: CGFloat) -> some View {
        if pageDragOffset > 0, let previous = model.previousPreviewVideo {
            ShortsPreviewPage(video: previous, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset - pageHeight)
        }
        if pageDragOffset < 0, let next = model.nextPreviewVideo {
            ShortsPreviewPage(video: next, serverAddress: model.serverAddress)
                .offset(y: pageDragOffset + pageHeight)
        }
    }

    private func updatePageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else { return }
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        pageDragOffset = value.translation.height
    }

    private func finishPageDrag(_ value: DragGesture.Value) {
        guard !model.isScrubbing, !isPageTransitioning else {
            resetPageDrag()
            return
        }
        let threshold: CGFloat = 70
        let predictedHeight = value.predictedEndTranslation.height
        let predictedWidth = value.predictedEndTranslation.width
        guard abs(predictedHeight) > abs(predictedWidth) else {
            resetPageDrag()
            return
        }
        if predictedHeight < -threshold {
            completePageTransition(toNext: true)
        } else if predictedHeight > threshold {
            completePageTransition(toNext: false)
        } else {
            resetPageDrag()
        }
    }

    private func completePageTransition(toNext: Bool) {
        isPageTransitioning = true
        let target = toNext ? -UIScreen.main.bounds.height : UIScreen.main.bounds.height
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            pageDragOffset = target
        }
        let coverVideo = toNext ? model.nextPreviewVideo : model.previousPreviewVideo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            transitionCoverVideo = coverVideo
            if toNext {
                model.next()
            } else {
                model.previous()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageDragOffset = 0
            }
            isPageTransitioning = false
            hideTransitionCoverSoon()
        }
    }

    private func resetPageDrag() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
            pageDragOffset = 0
        }
    }

    private func hideTransitionCoverSoon() {
        guard transitionCoverVideo != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !model.isLoading else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                transitionCoverVideo = nil
            }
        }
    }
}

struct ShortsPreviewPage: View {
    let video: RemoteVideoInfo
    let serverAddress: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(video.id)", query: [URLQueryItem(name: "original", value: "true")])) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                case .failure:
                    Image(systemName: "film")
                        .font(.system(size: 60, weight: .light))
                        .foregroundColor(.white.opacity(0.35))
                default:
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(video.filename.cleanVideoTitle)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(radius: 2)
                        Text(video.importDate, style: .date)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 68)
            }
        }
    }
}

struct EfficientShortsSeekBar: View {
    let progress: Double
    let onScrubUpdate: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    @Binding var isScrubbing: Bool
    
    @State private var localProgress: Double = 0
    
    var body: some View {
        GeometryReader { geo in
            let displayProgress = isScrubbing ? localProgress : progress
            
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 6)
                    .overlay(
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(displayProgress), height: 6),
                        alignment: .leading
                    )
                Spacer()
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                        }
                        let percent = max(0, min(1, value.location.x / geo.size.width))
                        localProgress = percent
                        onScrubUpdate(percent)
                    }
                    .onEnded { value in
                        let percent = max(0, min(1, value.location.x / geo.size.width))
                        onScrubEnd(percent)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isScrubbing = false
                        }
                    }
            )
        }
    }
}
