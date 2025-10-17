import SwiftUI
import AVKit
import UIKit // シェイクジェスチャーの検知に必要

// ===================================
//  RemoteVideoListView.swift (撮影日時での並び替え対応版)
// ===================================

struct RemoteVideoInfo: Codable, Identifiable, Hashable {
    let id: String
    let filename: String
    let duration: TimeInterval
    let importDate: Date
    // ★ 追加: 撮影日時
    let creationDate: Date?
}

private struct RemoteVideoThumbnailView: View {
    let thumbnailURL: URL
    let duration: TimeInterval
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))

            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Image(systemName: "wifi.exclamationmark").font(.title3).foregroundColor(.secondary)
                default:
                    ProgressView()
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 {
                Text(formatDuration(duration))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
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

// ★ 新規追加: 動画情報シート
private struct VideoInfoSheetView: View {
    let video: RemoteVideoInfo
    let serverAddress: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // 大きめのサムネイル
                RemoteVideoThumbnailView(
                    thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!,
                    duration: video.duration
                )
                .aspectRatio(16/9, contentMode: .fit)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding(.horizontal)

                // 動画情報
                VStack(alignment: .leading, spacing: 15) {
                    Text("ファイル名")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(video.filename)
                        .font(.headline)
                    
                    Divider()

                    HStack {
                        VStack(alignment: .leading) {
                            Text("長さ")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatDuration(video.duration))
                                .font(.subheadline)
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("インポート日")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(video.importDate, style: .date)
                                .font(.subheadline)
                        }
                    }
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("詳細情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
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

struct RemoteVideoListView: View {
    let serverName: String
    let serverAddress: String
    let albumID: String
    
    @State private var videos: [RemoteVideoInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var videoToPlay: IdentifiableURL?
    @State private var searchText = ""
    
    // ★ 追加: 長押しで表示する動画情報を保持
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

    private var sortedAndFilteredVideos: [RemoteVideoInfo] {
        let filtered = searchText.isEmpty ? videos : videos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        switch currentSortOrder {
        case .dateDescending:
            // ★ 修正: 撮影日時があればそれを優先し、なければインポート日時で並び替え
            return filtered.sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .dateAscending:
            // ★ 修正: 撮影日時があればそれを優先し、なければインポート日時で並び替え
            return filtered.sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .durationDescending:
            return filtered.sorted { $0.duration > $1.duration }
        case .durationAscending:
            return filtered.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            Group {
                if isLoading || isRefreshing {
                    ProgressView()
                } else if let errorMessage = errorMessage {
                    placeholderView(icon: "xmark.icloud.fill", title: "エラー", message: errorMessage)
                } else if videos.isEmpty {
                    placeholderView(icon: "film.fill", title: "動画がありません", message: "Macサーバーアプリに動画をインポートしてください。")
                } else {
                    videoGrid
                }
            }
        }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "ビデオを検索")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    Task {
                        await fetchVideosFromServer()
                    }
                }) {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                
                Menu {
                    Picker("並び替え", selection: $currentSortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("並び替え", systemImage: "arrow.up.arrow.down.circle")
                }
            }
        }
        .fullScreenCover(item: $videoToPlay) { identifiableUrl in
            DraggablePlayerView(url: identifiableUrl.url, videoToPlay: $videoToPlay)
        }
        // ★ 追加: 動画情報シート
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
        // ★ 修正: Buttonをジェスチャーを持つビューに変更
        RemoteVideoThumbnailView(
            thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!,
            duration: video.duration
        )
        .onTapGesture {
            if let videoURL = URL(string: "\(serverAddress)/video/\(video.id)") {
                self.videoToPlay = IdentifiableURL(url: videoURL)
            }
        }
        .onLongPressGesture {
            self.videoForInfoSheet = video
        }
    }

    private func placeholderView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 50)).foregroundColor(.secondary)
            Text(title).font(.title2.weight(.bold))
            Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
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
        do {
            errorMessage = nil
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.videos = try decoder.decode([RemoteVideoInfo].self, from: data)
        } catch {
            errorMessage = "動画リストの取得に失敗しました。\n\(error.localizedDescription)"
        }
    }

    private func playRandomVideo() {
        guard videoToPlay == nil else { return }
        
        guard let randomVideo = sortedAndFilteredVideos.randomElement() else {
            print("ランダム再生するビデオがありません。")
            return
        }
        
        if let videoURL = URL(string: "\(serverAddress)/video/\(randomVideo.id)") {
            self.videoToPlay = IdentifiableURL(url: videoURL)
        }
    }
}

// MARK: - Shake Gesture Components

private class ShakeDetectingUIView: UIView {
    var onShake: () -> Void = {}

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake()
        }
        super.motionEnded(motion, with: event)
    }
}

private struct ShakeDetector: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeDetectingUIView {
        let view = ShakeDetectingUIView()
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeDetectingUIView, context: Context) {
        uiView.onShake = onShake
    }
}

private struct ShakeViewModifier: ViewModifier {
    let onShake: () -> Void

    func body(content: Content) -> some View {
        content.background(ShakeDetector(onShake: onShake).frame(width: 0, height: 0))
    }
}

extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        self.modifier(ShakeViewModifier(onShake: action))
    }
}


