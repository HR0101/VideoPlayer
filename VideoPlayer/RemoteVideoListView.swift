import SwiftUI
import AVKit
import UIKit

// ===================================
//  RemoteVideoListView.swift (リトライ機能強化版)
// ===================================

// ★ 新規追加: 自動リトライ機能付き画像ビュー
struct RetryableRemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    
    // アニメーション用
    @State private var opacity: Double = 0
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(opacity)
            } else {
                // ロード中プレースホルダー
                ZStack {
                    Color(red: 0.15, green: 0.15, blue: 0.15)
                    ProgressView().tint(.white)
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        if image != nil { return } // 読み込み済みならスキップ
        
        Task {
            // キャッシュを無視して最新を取得（サーバー側で生成完了しているかもしれないため）
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else { return }
                
                if httpResponse.statusCode == 200 {
                    // 成功: 画像を表示
                    if let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            withAnimation(.easeIn(duration: 0.3)) {
                                self.image = uiImage
                                self.opacity = 1.0
                            }
                        }
                    }
                } else if httpResponse.statusCode == 202 {
                    // 202 Accepted: サーバーで生成中 -> 少し待ってリトライ
                    // プレースホルダーデータが入っている場合は一旦それを表示してもいいが、
                    // ここでは完了までローディングを維持しつつリトライする
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機
                    loadImage()
                } else {
                    // その他のエラー: 少し待ってリトライ（通信エラー等）
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    loadImage()
                }
            } catch {
                // 通信エラー時もリトライ
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                loadImage()
            }
        }
    }
}

struct RemoteVideoListView: View {
    let serverName: String
    let serverAddress: String
    let albumID: String
    
    @State private var videos: [RemoteVideoInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    
    @State private var videoToPlay: IdentifiableURL?
    
    // 画像ビューアー用
    @State private var isPhotoViewerPresented = false
    @State private var viewerPhotos: [RemoteVideoInfo] = []
    @State private var viewerInitialIndex: Int = 0
    
    @State private var videoForInfoSheet: RemoteVideoInfo?
    
    enum SortOrder: String, CaseIterable {
        case dateDescending = "新しい順"
        case dateAscending = "古い順"
        case durationDescending = "長い順"
        case durationAscending = "短い順"
    }
    @State private var currentSortOrder: SortOrder = .dateDescending
    @State private var isRefreshing = false

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1)
    private let accentGlowColor = Color.cyan

    private var sortedAndFilteredVideos: [RemoteVideoInfo] {
        let filtered = searchText.isEmpty ? videos : videos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        switch currentSortOrder {
        case .dateDescending:
            return filtered.sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .dateAscending:
            return filtered.sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .durationDescending:
            return filtered.sorted { $0.duration > $1.duration }
        case .durationAscending:
            return filtered.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        ZStack {
            primaryDarkColor.ignoresSafeArea()
            Group {
                if isLoading || isRefreshing {
                    ProgressView().tint(.white)
                } else if let errorMessage = errorMessage {
                    placeholderView(icon: "xmark.icloud.fill", title: "エラー", message: errorMessage)
                } else if videos.isEmpty {
                    placeholderView(icon: "film.fill", title: "メディアがありません", message: "Macサーバーアプリに動画や画像をインポートしてください。")
                } else {
                    videoGrid
                }
            }
        }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "検索")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(primaryDarkColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: { Task { await fetchVideosFromServer() } }) {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                        .foregroundColor(accentGlowColor)
                }
                Menu {
                    Picker("並び替え", selection: $currentSortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("並び替え", systemImage: "arrow.up.arrow.down.circle")
                        .foregroundColor(accentGlowColor)
                }
            }
        }
        .fullScreenCover(item: $videoToPlay) { identifiableUrl in
            DraggablePlayerView(url: identifiableUrl.url, videoToPlay: $videoToPlay)
        }
        .fullScreenCover(isPresented: $isPhotoViewerPresented) {
            RemotePhotoViewer(
                videos: viewerPhotos,
                serverAddress: serverAddress,
                initialIndex: viewerInitialIndex,
                isPresented: $isPhotoViewerPresented
            )
        }
        .sheet(item: $videoForInfoSheet) { video in
            VideoInfoSheetView(video: video, serverAddress: serverAddress)
        }
        .task {
            if videos.isEmpty {
                isLoading = true
                await fetchVideosFromServer()
                isLoading = false
            }
        }
        .onShake(perform: playRandomVideo)
    }
    
    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(sortedAndFilteredVideos) { video in
                    thumbnailCell(for: video)
                }
            }
        }
        .refreshable { await fetchVideosFromServer() }
    }
    
    @ViewBuilder
    private func thumbnailCell(for video: RemoteVideoInfo) -> some View {
        // ★ 修正: RetryableRemoteImageを使用
        RemoteVideoThumbnailView(
            thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!,
            duration: video.duration,
            isPhoto: video.isPhoto
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if video.isPhoto {
                let photos = sortedAndFilteredVideos.filter { $0.isPhoto }
                if let index = photos.firstIndex(where: { $0.id == video.id }) {
                    self.viewerPhotos = photos
                    self.viewerInitialIndex = index
                    self.isPhotoViewerPresented = true
                }
            } else {
                if let videoURL = URL(string: "\(serverAddress)/video/\(video.id)") {
                    self.videoToPlay = IdentifiableURL(url: videoURL)
                }
            }
        }
        .onLongPressGesture {
            self.videoForInfoSheet = video
        }
    }

    private func placeholderView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 50))
                .foregroundColor(.white.opacity(0.6))
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
        .padding()
    }
    
    private func fetchVideosFromServer() async {
        isRefreshing = true
        defer { isRefreshing = false }
        
        guard let url = URL(string: "\(serverAddress)/albums/\(albumID)/videos") else {
            errorMessage = "無効なURLです。"
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        
        do {
            errorMessage = nil
            let (data, _) = try await session.data(from: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.videos = try decoder.decode([RemoteVideoInfo].self, from: data)
        } catch {
            errorMessage = "リストの取得に失敗しました。\n\(error.localizedDescription)"
        }
    }

    private func playRandomVideo() {
        guard videoToPlay == nil && !isPhotoViewerPresented else { return }
        let movieVideos = sortedAndFilteredVideos.filter { !$0.isPhoto }
        guard let randomVideo = movieVideos.randomElement() else { return }
        
        if let videoURL = URL(string: "\(serverAddress)/video/\(randomVideo.id)") {
            self.videoToPlay = IdentifiableURL(url: videoURL)
        }
    }
}

// MARK: - Subviews & Components

private struct RemoteVideoThumbnailView: View {
    let thumbnailURL: URL
    let duration: TimeInterval
    let isPhoto: Bool
    
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1)
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(primaryDarkColor.opacity(0.8))

            // ★ 修正: 標準のAsyncImageではなく、リトライ機能付きのカスタムビューを使用
            RetryableRemoteImage(url: thumbnailURL)
        }
        .aspectRatio(1, contentMode: .fit)
        .cornerRadius(12)
        .clipped()
        .shadow(color: Color.black.opacity(0.4), radius: 6, x: 3, y: 3)
        .shadow(color: Color.white.opacity(0.05), radius: 3, x: -1, y: -1)
        
        .overlay(alignment: .bottomTrailing) {
            // ★ 修正: isPhotoの場合はバッジを表示しない
            if !isPhoto && duration > 0 {
                Text(formatDuration(duration))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial.opacity(0.8))
                    .cornerRadius(4)
                    .padding(4)
            }
        }
    }
    
    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        let minutes = secondsInt / 60
        let seconds = secondsInt % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct DraggablePlayerView: View {
    let url: URL
    @Binding var videoToPlay: IdentifiableURL?
    @StateObject private var playerManager: PlayerManager
    @State private var dragOffset: CGSize = .zero

    init(url: URL, videoToPlay: Binding<IdentifiableURL?>) {
        self.url = url
        self._videoToPlay = videoToPlay
        self._playerManager = StateObject(wrappedValue: PlayerManager(videoURL: url))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1.0 - Double(abs(dragOffset.height) / 500))
            VStack {
                VideoPlayer(player: playerManager.player)
                    .scaleEffect(max(0.8, 1 - (abs(dragOffset.height) / 800)))
            }
            .offset(y: dragOffset.height)
            .opacity(1.0 - Double(abs(dragOffset.height) / 300))
        }
        .edgesIgnoringSafeArea(.all)
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    if abs(dragOffset.height) > 100 {
                        playerManager.shutdown()
                        videoToPlay = nil
                    } else {
                        withAnimation(.spring()) { dragOffset = .zero }
                    }
                }
        )
        .onDisappear {
            playerManager.shutdown()
        }
        .persistentSystemOverlays(.hidden)
    }
}

private struct RemotePhotoViewer: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String
    let initialIndex: Int
    @Binding var isPresented: Bool
    
    @State private var currentIndex: Int
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    init(videos: [RemoteVideoInfo], serverAddress: String, initialIndex: Int, isPresented: Binding<Bool>) {
        self.videos = videos
        self.serverAddress = serverAddress
        self.initialIndex = initialIndex
        self._isPresented = isPresented
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    private var currentURL: URL? {
        guard videos.indices.contains(currentIndex) else { return nil }
        return URL(string: "\(serverAddress)/video/\(videos[currentIndex].id)")
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                let delta = val / lastScale
                                lastScale = val
                                scale *= delta
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                                if scale < 1.0 { withAnimation { scale = 1.0 } }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { val in
                                if scale > 1 {
                                    offset = CGSize(width: lastOffset.width + val.translation.width,
                                                    height: lastOffset.height + val.translation.height)
                                } else {
                                    offset = val.translation
                                }
                            }
                            .onEnded { val in
                                if scale > 1 {
                                    lastOffset = offset
                                } else {
                                    if val.translation.height > 100 {
                                        isPresented = false
                                    } else {
                                        withAnimation { offset = .zero }
                                    }
                                }
                            }
                    )
            } else if isLoading {
                VStack {
                    ProgressView().tint(.white)
                    Text("画像を読み込み中...")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.top, 8)
                }
            } else if let errorMessage = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.yellow)
                    Text("画像を読み込めませんでした")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button(action: { Task { await loadImage(isRetry: true) } }) {
                        Text("再試行")
                            .fontWeight(.bold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
            }
            
            if scale == 1.0 {
                HStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: UIScreen.main.bounds.width / 3)
                        .onTapGesture {
                            if currentIndex > 0 {
                                withAnimation {
                                    currentIndex -= 1
                                    resetZoom()
                                }
                            }
                        }
                    Spacer()
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: UIScreen.main.bounds.width / 3)
                        .onTapGesture {
                            if currentIndex < videos.count - 1 {
                                withAnimation {
                                    currentIndex += 1
                                    resetZoom()
                                }
                            }
                        }
                }
            }
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
            }
            
            if !isLoading {
                VStack {
                    Spacer()
                    Text("\(currentIndex + 1) / \(videos.count)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                }
            }
        }
        .task { await loadImage() }
        .onChange(of: currentIndex) { _ in Task { await loadImage() } }
    }
    
    private func resetZoom() {
        scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
    }
    
    private func loadImage(isRetry: Bool = false) async {
        guard let url = currentURL else { return }
        
        isLoading = true
        errorMessage = nil
        image = nil
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("close", forHTTPHeaderField: "Connection")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "NetworkError", code: 0, userInfo: [NSLocalizedDescriptionKey: "サーバーエラー"])
            }
            
            guard let loadedImage = UIImage(data: data) else {
                throw NSError(domain: "ImageError", code: 0, userInfo: [NSLocalizedDescriptionKey: "画像データ破損"])
            }
            
            self.image = loadedImage
            
        } catch {
            let nsError = error as NSError
            if nsError.code == -1005 && !isRetry {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await loadImage(isRetry: true)
                return
            }
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct VideoInfoSheetView: View {
    let video: RemoteVideoInfo
    let serverAddress: String
    @Environment(\.dismiss) var dismiss
    
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    RemoteVideoThumbnailView(
                        thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!,
                        duration: video.duration,
                        isPhoto: video.isPhoto
                    )
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(16)
                    .shadow(radius: 8)
                    .padding(.horizontal)
                    .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 15) {
                        InfoRow(title: "ファイル名", value: video.filename, isMain: true)
                        Divider().background(Color.gray.opacity(0.3))
                        HStack {
                            if !video.isPhoto {
                                VStack(alignment: .leading) {
                                    Text("長さ").font(.caption).foregroundColor(.secondary)
                                    Text(formatDuration(video.duration)).font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                            }
                            VStack(alignment: .leading) {
                                Text("インポート日").font(.caption).foregroundColor(.secondary)
                                Text(video.importDate, style: .date).font(.subheadline.weight(.semibold))
                            }
                            if !video.isPhoto { Spacer() }
                        }
                        if let creationDate = video.creationDate {
                            Divider().background(Color.gray.opacity(0.3))
                            VStack(alignment: .leading) {
                                Text("撮影日時").font(.caption).foregroundColor(.secondary)
                                Text(creationDate, style: .date).font(.subheadline.weight(.semibold))
                            }
                        }
                        Divider().background(Color.gray.opacity(0.3))
                        InfoRow(title: "種類", value: video.isPhoto ? "画像" : "動画", isMain: false)
                    }
                    .padding(20)
                    .background(.thickMaterial)
                    .cornerRadius(16)
                    .padding(.horizontal)
                    Spacer()
                }
            }
            .background(primaryDarkColor.ignoresSafeArea())
            .navigationTitle("詳細情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(primaryDarkColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") { dismiss() }.foregroundColor(.cyan)
                }
            }
        }
    }
    
    private struct InfoRow: View {
        let title: String
        let value: String
        var isMain: Bool = false
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(isMain ? .headline.weight(.bold) : .subheadline.weight(.semibold))
            }
        }
    }
    
    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        let hours = secondsInt / 3600
        let minutes = (secondsInt % 3600) / 60
        let seconds = secondsInt % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Shake Gesture Components
private class ShakeDetectingUIView: UIView {
    var onShake: () -> Void = {}
    override var canBecomeFirstResponder: Bool { return true }
    override func didMoveToWindow() { super.didMoveToWindow(); self.becomeFirstResponder() }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake() }
        super.motionEnded(motion, with: event)
    }
}
private struct ShakeDetector: UIViewRepresentable {
    let onShake: () -> Void
    func makeUIView(context: Context) -> ShakeDetectingUIView {
        let view = ShakeDetectingUIView(); view.onShake = onShake; return view
    }
    func updateUIView(_ uiView: ShakeDetectingUIView, context: Context) { uiView.onShake = onShake }
}
private struct ShakeViewModifier: ViewModifier {
    let onShake: () -> Void
    func body(content: Content) -> some View { content.background(ShakeDetector(onShake: onShake).frame(width: 0, height: 0)) }
}
extension View {
    func onShake(perform action: @escaping () -> Void) -> some View { self.modifier(ShakeViewModifier(onShake: action)) }
}
