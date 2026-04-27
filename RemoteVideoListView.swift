import SwiftUI
import AVKit
import UIKit
import Photos
import PhotosUI
#if canImport(AppKit)
import AppKit
#endif



// 再生履歴管理クラス
class PlaybackHistoryManager {
    static let shared = PlaybackHistoryManager()
    private let historyKey = "playback_history_ids"
    private let maxHistoryCount = 50
    
    func saveLastPlayed(id: String) {
        var ids = getHistoryIDs()
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        }
        ids.insert(id, at: 0)
        if ids.count > maxHistoryCount {
            ids = Array(ids.prefix(maxHistoryCount))
        }
        UserDefaults.standard.set(ids, forKey: historyKey)
    }
    
    func getHistoryIDs() -> [String] {
        return UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }
    
    func removeHistory(id: String) {
        var ids = getHistoryIDs()
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            UserDefaults.standard.set(ids, forKey: historyKey)
        }
    }
    
    func getLastPlayedID() -> String? {
        return getHistoryIDs().first
    }
}


struct RemoteVideoListView: View {
    let serverName: String
    let serverAddress: String
    let albumID: String
    let allServerAlbums: [RemoteAlbumInfo]
    
    @State private var videos: [RemoteVideoInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    
    @State private var videoToPlay: RemoteVideoInfo?
    @State private var playingVideoID: String?
    @State private var photoToView: RemoteVideoInfo? // URLから動画情報本体を持つように修正
    @State private var videoForInfoSheet: RemoteVideoInfo?
    
    @State private var gridColumnCount: Int = 3
    @State private var lastPlayedID: String?
    
    @AppStorage("isListViewMode") private var isListViewMode = false
    
    @State private var isSelectionMode = false
    @State private var selectedVideoIDs = Set<String>()
    @State private var showMoveTargetSheet = false
    
    @State private var showServerMediaPicker = false
    @State private var isUploading = false
    
    @EnvironmentObject var downloadManager: DownloadManager
    

    enum SortOrder: String, CaseIterable {
        case importDescending = "追加日が新しい順"
        case importAscending = "追加日が古い順"
        case creationDescending = "撮影日が新しい順"
        case creationAscending = "撮影日が古い順"
        case durationDescending = "長さが長い順"
        case durationAscending = "長さが短い順"
    }
    @State private var currentSortOrder: SortOrder = .importDescending

    private let primaryDarkColor = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accentGlowColor = Color(red: 0.85, green: 0.73, blue: 0.45)

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.10, green: 0.10, blue: 0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: gridColumnCount) }

    private var sortedAndFilteredVideos: [RemoteVideoInfo] {
        let filtered = searchText.isEmpty ? videos : videos.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        
        if albumID == "HISTORY" {
            return filtered
        }
        
        switch currentSortOrder {
        case .importDescending: return filtered.sorted { $0.importDate > $1.importDate }
        case .importAscending: return filtered.sorted { $0.importDate < $1.importDate }
        case .creationDescending: return filtered.sorted { ($0.creationDate ?? $0.importDate) > ($1.creationDate ?? $1.importDate) }
        case .creationAscending: return filtered.sorted { ($0.creationDate ?? $0.importDate) < ($1.creationDate ?? $1.importDate) }
        case .durationDescending: return filtered.sorted { $0.duration > $1.duration }
        case .durationAscending: return filtered.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        ZStack {
            backgroundGradient
            
            Group {
                if isLoading {
                    ProgressView().tint(accentGlowColor).scaleEffect(1.2)
                }
                else if let errorMessage = errorMessage { placeholderView(icon: "exclamationmark.triangle.fill", title: "エラーが発生しました", message: errorMessage) }
                else if videos.isEmpty { placeholderView(icon: "server.rack", title: "メディアがありません", message: albumID == "HISTORY" ? "再生履歴はありません。" : "右上のアップロードボタンから\n動画や写真を追加してください。") }
                else {
                    if isListViewMode {
                        videoList
                    } else {
                        videoGrid
                    }
                }
            }
            
            if isUploading {
                ZStack {
                    Color.black.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 24) {
                        ProgressView().scaleEffect(1.5).tint(accentGlowColor)
                        Text("サーバーへアップロード中...")
                            .foregroundColor(.white)
                            .font(.headline.weight(.medium))
                            .tracking(1.0)
                    }
                    .padding(40)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                }
            }
            
            if isSelectionMode {
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button(action: deleteSelectedVideos) {
                            Text("\(selectedVideoIDs.count)件削除")
                                .font(.headline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(selectedVideoIDs.isEmpty ? Color.white.opacity(0.1) : Color.red.opacity(0.8))
                                .foregroundColor(selectedVideoIDs.isEmpty ? .gray : .white)
                                .cornerRadius(16)
                                .shadow(color: selectedVideoIDs.isEmpty ? .clear : Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                        }.disabled(selectedVideoIDs.isEmpty)
                        
                        if albumID != "HISTORY" {
                            Button(action: { showMoveTargetSheet = true }) {
                                Text("移動")
                                    .font(.headline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(selectedVideoIDs.isEmpty ? Color.white.opacity(0.1) : accentGlowColor)
                                    .foregroundColor(selectedVideoIDs.isEmpty ? .gray : primaryDarkColor)
                                    .cornerRadius(16)
                                    .shadow(color: selectedVideoIDs.isEmpty ? .clear : accentGlowColor.opacity(0.3), radius: 8, x: 0, y: 4)
                            }.disabled(selectedVideoIDs.isEmpty)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.white.opacity(0.1)), alignment: .top)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .navigationTitle(isSelectionMode ? "\(selectedVideoIDs.count)件選択" : serverName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "検索")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(primaryDarkColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelectionMode {
                    Button(selectedVideoIDs.count == videos.count ? "選択解除" : "すべて選択") {
                        if selectedVideoIDs.count == videos.count { selectedVideoIDs.removeAll() } else { selectedVideoIDs = Set(videos.map { $0.id }) }
                    }.foregroundColor(accentGlowColor)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelectionMode {
                    Button("完了") { isSelectionMode = false; selectedVideoIDs.removeAll() }
                        .font(.body.weight(.bold))
                        .foregroundColor(accentGlowColor)
                } else {
                    if albumID != "HISTORY" {
                        Button(action: { showServerMediaPicker = true }) {
                            Image(systemName: "icloud.and.arrow.up").foregroundColor(accentGlowColor)
                        }
                    }
                    
                    Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isListViewMode.toggle() } }) {
                        Image(systemName: isListViewMode ? "square.grid.2x2" : "list.bullet")
                            .foregroundColor(accentGlowColor)
                    }
                    
                    Button(action: { withAnimation { isSelectionMode = true } }) { Text("選択").foregroundColor(accentGlowColor) }.disabled(videos.isEmpty)
                    
                    if albumID != "HISTORY" {
                        Menu {
                            Picker("並び替え", selection: $currentSortOrder) { ForEach(SortOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) } }
                        } label: { Image(systemName: "arrow.up.arrow.down.circle").foregroundColor(accentGlowColor) }
                    }
                }
            }
        }
        .sheet(isPresented: $showMoveTargetSheet) { moveTargetSheet }
        .sheet(isPresented: $showServerMediaPicker) { ServerMediaPicker { urls in handlePickedMedia(urls: urls) } }
        .fullScreenCover(item: $videoToPlay) { video in
            let onlyVideos = sortedAndFilteredVideos.filter { !$0.isPhoto }
            if let initialIndex = onlyVideos.firstIndex(where: { $0.id == video.id }) {
                DraggablePlayerView(
                    videos: onlyVideos,
                    initialIndex: initialIndex,
                    serverAddress: serverAddress,
                    videoToPlay: $videoToPlay,
                    playingVideoID: $playingVideoID
                )
                .onAppear { if let id = playingVideoID { lastPlayedID = id } }
                .onDisappear { lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
            } else {
                DraggablePlayerView(
                    videos: [video],
                    initialIndex: 0,
                    serverAddress: serverAddress,
                    videoToPlay: $videoToPlay,
                    playingVideoID: $playingVideoID
                )
                .onAppear { if let id = playingVideoID { lastPlayedID = id } }
                .onDisappear { lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
            }
        }
        .fullScreenCover(item: $photoToView) { photo in
            let onlyPhotos = sortedAndFilteredVideos.filter { $0.isPhoto }
            if let initialIndex = onlyPhotos.firstIndex(where: { $0.id == photo.id }) {
                RemotePhotoViewer(
                    photos: onlyPhotos,
                    initialIndex: initialIndex,
                    serverAddress: serverAddress,
                    isPresented: Binding(get: { photoToView != nil }, set: { if !$0 { photoToView = nil } }),
                    downloadManager: downloadManager
                )
            } else {
                RemotePhotoViewer(
                    photos: [photo],
                    initialIndex: 0,
                    serverAddress: serverAddress,
                    isPresented: Binding(get: { photoToView != nil }, set: { if !$0 { photoToView = nil } }),
                    downloadManager: downloadManager
                )
            }
        }
        .sheet(item: $videoForInfoSheet) { video in VideoInfoSheetView(video: video, serverAddress: serverAddress, downloadManager: downloadManager) }
        .task { if videos.isEmpty { await fetchVideosFromServer() }; lastPlayedID = PlaybackHistoryManager.shared.getLastPlayedID() }
        .onShake {
            playRandomVideo()
        }
    }
    

    private func playRandomVideo() {
        guard !isSelectionMode, !videos.isEmpty else { return }
        let onlyVideos = videos.filter { !$0.isPhoto }
        guard let randomVideo = onlyVideos.randomElement() else { return }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        playingVideoID = randomVideo.id
        PlaybackHistoryManager.shared.saveLastPlayed(id: randomVideo.id)
        videoToPlay = randomVideo
    }
    

    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(sortedAndFilteredVideos) { video in thumbnailCell(for: video) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .padding(.bottom, isSelectionMode ? 100 : 0)
        }
        .refreshable { await fetchVideosFromServer() }
    }

    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sortedAndFilteredVideos) { video in
                    listRow(for: video)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, isSelectionMode ? 100 : 0)
        }
        .refreshable { await fetchVideosFromServer() }
    }

    @ViewBuilder
    private func thumbnailCell(for video: RemoteVideoInfo) -> some View {
        let isLastPlayed = video.id == lastPlayedID
        ZStack(alignment: .topTrailing) {
            RemoteVideoThumbnailView(thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!, duration: video.duration)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(isLastPlayed ? accentGlowColor : Color.white.opacity(0.15), lineWidth: isLastPlayed ? 2.5 : 0.5))
                .opacity(isSelectionMode && selectedVideoIDs.contains(video.id) ? 0.6 : 1.0)
            
            if isSelectionMode {
                let isSelected = selectedVideoIDs.contains(video.id)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.bold)).foregroundColor(isSelected ? accentGlowColor : .white)
                    .padding(8)
                    .background(Group { if !isSelected { Color.black.opacity(0.4).clipShape(Circle()) } })
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleVideoTap(video) }
        .contextMenu { videoContextMenu(video) }
    }
    

    @ViewBuilder
    private func listRow(for video: RemoteVideoInfo) -> some View {
        let isLastPlayed = video.id == lastPlayedID
        HStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                RemoteVideoThumbnailView(thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!, duration: video.duration)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(isLastPlayed ? accentGlowColor : Color.white.opacity(0.15), lineWidth: isLastPlayed ? 2 : 0.5))
                
                if isSelectionMode {
                    let isSelected = selectedVideoIDs.contains(video.id)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.bold)).foregroundColor(isSelected ? accentGlowColor : .white)
                        .padding(4).background(Group { if !isSelected { Color.black.opacity(0.4).clipShape(Circle()) } })
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(video.filename)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                Text(video.importDate, style: .date)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    
                if !video.isPhoto {
                    HStack(spacing: 4) {
                        Image(systemName: "film.fill").font(.system(size: 10))
                        Text("Video").font(.caption2.weight(.medium))
                    }
                    .foregroundColor(accentGlowColor.opacity(0.9))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.fill").font(.system(size: 10))
                        Text("Photo").font(.caption2.weight(.medium))
                    }
                    .foregroundColor(Color.orange.opacity(0.9))
                }
            }
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.2))
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .opacity(isSelectionMode && selectedVideoIDs.contains(video.id) ? 0.7 : 1.0)
        .onTapGesture { handleVideoTap(video) }
        .contextMenu { videoContextMenu(video) }
    }
    
    private func handleVideoTap(_ video: RemoteVideoInfo) {
        if isSelectionMode {
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id) }
        } else {
            if video.isPhoto {
                photoToView = video
            } else {
                playingVideoID = video.id
                PlaybackHistoryManager.shared.saveLastPlayed(id: video.id)
                videoToPlay = video
            }
        }
    }
    
    @ViewBuilder
    private func videoContextMenu(_ video: RemoteVideoInfo) -> some View {
        Button { videoForInfoSheet = video } label: { Label("詳細情報", systemImage: "info.circle") }
        Button { if let url = URL(string: "\(serverAddress)/video/\(video.id)") { downloadManager.startDownload(url: url, filename: video.filename, isPhoto: video.duration == 0) } } label: { Label("保存", systemImage: "square.and.arrow.down") }
        
        if serverName != "ALL VIDEOS" && serverName != "ALL PHOTOS" {
            if albumID == "HISTORY" {
                Button(role: .destructive) {
                    PlaybackHistoryManager.shared.removeHistory(id: video.id)
                    Task { await fetchVideosFromServer() }
                } label: { Label("履歴から削除", systemImage: "minus.circle") }
            } else {
                Button(role: .destructive) { deleteSingleVideo(id: video.id) } label: { Label("アルバムから外す", systemImage: "minus.circle") }
            }
        }
    }

    private var moveTargetSheet: some View {
        NavigationView {
            List(allServerAlbums.filter { $0.id != albumID }) { album in
                Button(action: { showMoveTargetSheet = false; executeMove(to: album.id) }) {
                    HStack { Image(systemName: album.type == "photo" ? "photo.on.rectangle.fill" : "folder.fill").foregroundColor(accentGlowColor); Text(album.name).foregroundColor(.white) }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(primaryDarkColor.ignoresSafeArea())
            .navigationTitle("移動先を選択").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(primaryDarkColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showMoveTargetSheet = false }.foregroundColor(accentGlowColor) } }
        }
    }
    

    private func fetchVideosFromServer() async {
        isLoading = true
        defer { isLoading = false }
        
        if albumID == "HISTORY" {
            guard let allVideosAlbum = allServerAlbums.first(where: { $0.name == "ALL VIDEOS" }),
                  let url = URL(string: "\(serverAddress)/albums/\(allVideosAlbum.id)/videos") else {
                errorMessage = "履歴を取得できません"
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let allVideos = try decoder.decode([RemoteVideoInfo].self, from: data)
                
                let historyIDs = PlaybackHistoryManager.shared.getHistoryIDs()
                var historyVideos: [RemoteVideoInfo] = []
                for id in historyIDs {
                    if let video = allVideos.first(where: { $0.id == id }) {
                        historyVideos.append(video)
                    }
                }
                self.videos = historyVideos
            } catch {
                errorMessage = "履歴取得失敗: \(error.localizedDescription)"
            }
        } else {
            guard let url = URL(string: "\(serverAddress)/albums/\(albumID)/videos") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.videos = try decoder.decode([RemoteVideoInfo].self, from: data)
            } catch {
                errorMessage = "取得失敗: \(error.localizedDescription)"
            }
        }
    }
    
    private func executeMove(to targetID: String) { let ids = Array(selectedVideoIDs); Task { _ = try? await ServerAPI.moveVideos(serverAddress: serverAddress, videoIDs: ids, sourceAlbumID: albumID, targetAlbumID: targetID); isSelectionMode = false; selectedVideoIDs.removeAll(); await fetchVideosFromServer() } }
    
    private func deleteSelectedVideos() {
        let ids = Array(selectedVideoIDs)
        if albumID == "HISTORY" {
            for id in ids { PlaybackHistoryManager.shared.removeHistory(id: id) }
            isSelectionMode = false
            selectedVideoIDs.removeAll()
            Task { await fetchVideosFromServer() }
        } else {
            Task { _ = try? await ServerAPI.deleteVideos(serverAddress: serverAddress, videoIDs: ids, albumID: albumID); isSelectionMode = false; selectedVideoIDs.removeAll(); await fetchVideosFromServer() }
        }
    }
    
    private func deleteSingleVideo(id: String) { Task { _ = try? await ServerAPI.deleteVideos(serverAddress: serverAddress, videoIDs: [id], albumID: albumID); await fetchVideosFromServer() } }
    private func handlePickedMedia(urls: [URL]) { isUploading = true; Task { for fileURL in urls { _ = try? await ServerAPI.uploadMedia(serverAddress: serverAddress, fileURL: fileURL, albumID: albumID); try? FileManager.default.removeItem(at: fileURL); try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }; isUploading = false; await fetchVideosFromServer() } }
    
    private func placeholderView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(accentGlowColor.opacity(0.8))
                .shadow(color: accentGlowColor.opacity(0.3), radius: 10, x: 0, y: 0)
            
            Text(title).font(.title2.weight(.bold)).foregroundColor(.white).tracking(1.0)
            Text(message).font(.subheadline).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center).padding(.horizontal, 40).lineSpacing(6)
        }
        .padding()
    }
}



struct ServerMediaPicker: UIViewControllerRepresentable {
    let onMediaPicked: ([URL]) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController { var config = PHPickerConfiguration(photoLibrary: .shared()); config.filter = .any(of: [.videos, .images]); config.selectionLimit = 0; config.preferredAssetRepresentationMode = .current; let picker = PHPickerViewController(configuration: config); picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ServerMediaPicker
        private var pickedURLs: [URL] = []
        private let queue = DispatchQueue(label: "pickedURLs.queue")
        init(_ parent: ServerMediaPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true); guard !results.isEmpty else { return }; self.pickedURLs = []; let group = DispatchGroup()
            for result in results {
                group.enter(); let provider = result.itemProvider
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in self?.processURL(url, group: group) } }
                else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in self?.processURL(url, group: group) } }
                else { group.leave() }
            }
            group.notify(queue: .main) { if !self.pickedURLs.isEmpty { self.parent.onMediaPicked(self.pickedURLs) } }
        }
        private func processURL(_ url: URL?, group: DispatchGroup) {
            defer { group.leave() }; guard let sourceURL = url else { return }
            let tempDir = FileManager.default.temporaryDirectory; let uniqueDir = tempDir.appendingPathComponent(UUID().uuidString)
            do { try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true); let finalURL = uniqueDir.appendingPathComponent(sourceURL.lastPathComponent); try FileManager.default.copyItem(at: sourceURL, to: finalURL); queue.sync { self.pickedURLs.append(finalURL) } } catch { print("Copy error: \(error)") }
        }
    }
}

private struct RemoteVideoThumbnailView: View {
    let thumbnailURL: URL
    let duration: TimeInterval
    private let primaryDarkColor = Color(red: 0.08, green: 0.08, blue: 0.1)
    
    var body: some View {
        ZStack {
            Rectangle().fill(primaryDarkColor)
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                case .failure: Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.2))
                default: ProgressView().tint(Color(red: 0.85, green: 0.73, blue: 0.45))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit).cornerRadius(16).clipped().shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 4)
        .overlay(alignment: .bottom) { if duration > 0 { LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.7)]), startPoint: .top, endPoint: .bottom).frame(height: 40) } }
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 { Text(formatDuration(duration)).font(.caption2.weight(.bold)).foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 4).background(.ultraThinMaterial.opacity(0.9)).cornerRadius(6).padding(8) }
        }
    }
    private func formatDuration(_ totalSeconds: TimeInterval) -> String { let secondsInt = Int(totalSeconds); return String(format: "%d:%02d", secondsInt / 60, secondsInt % 60) }
}

private struct DraggablePlayerView: View {
    let videos: [RemoteVideoInfo]
    let serverAddress: String
    
    @Binding var videoToPlay: RemoteVideoInfo?
    @Binding var playingVideoID: String?
    
    @State private var currentIndex: Int
    @StateObject private var playerManager: PlayerManager
    @State private var dragOffset: CGSize = .zero
    @State private var selectedQuality: String = "original"
    
    @State private var showControls: Bool = true
    @State private var hideControlsTask: Task<Void, Never>? = nil
    
    init(videos: [RemoteVideoInfo], initialIndex: Int, serverAddress: String, videoToPlay: Binding<RemoteVideoInfo?>, playingVideoID: Binding<String?>) {
        self.videos = videos
        self._currentIndex = State(initialValue: initialIndex)
        self.serverAddress = serverAddress
        self._videoToPlay = videoToPlay
        self._playingVideoID = playingVideoID
        
        let initialVideo = videos[initialIndex]
        let url = URL(string: "\(serverAddress)/video/\(initialVideo.id)")!
        self._playerManager = StateObject(wrappedValue: PlayerManager(videoURL: url))
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 500))
            
            HStack {
                if currentIndex > 0 {
                    Image(systemName: "backward.end.alt.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(dragOffset.width > 50 ? min(1.0, Double(dragOffset.width - 50) / 100.0) : 0))
                        .padding(.leading, 40)
                }
                Spacer()
                if currentIndex < videos.count - 1 {
                    Image(systemName: "forward.end.alt.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(dragOffset.width < -50 ? min(1.0, Double(-dragOffset.width - 50) / 100.0) : 0))
                        .padding(.trailing, 40)
                }
            }
            
            VStack {
                VideoPlayer(player: playerManager.player)
                    .scaleEffect(max(0.8, 1 - (max(abs(dragOffset.width), max(0, dragOffset.height)) / 800)))
            }
            .offset(x: dragOffset.width, y: dragOffset.height > 0 ? dragOffset.height : 0)
            .opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 300))
            
            if showControls {
                VStack {
                    HStack {
                        Text(videos[currentIndex].filename)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.top, 60)
                            .padding(.leading, 20)
                            .shadow(radius: 2)
                        Spacer()
                    }
                    Spacer()
                }
                .transition(.opacity)
                
                VStack {
                    HStack {
                        Spacer()
                        Menu {
                            Button(action: { changeQuality("original") }) { if selectedQuality == "original" { Label("オリジナル", systemImage: "checkmark") } else { Text("オリジナル") } }
                            Button(action: { changeQuality("1080p") }) { if selectedQuality == "1080p" { Label("1080p (高画質軽量)", systemImage: "checkmark") } else { Text("1080p (高画質軽量)") } }
                            Button(action: { changeQuality("540p") }) { if selectedQuality == "540p" { Label("540p (データ節約)", systemImage: "checkmark") } else { Text("540p (データ節約)") } }
                        } label: {
                            HStack(spacing: 6) { Image(systemName: "line.3.horizontal.decrease.circle"); Text(qualityLabel(selectedQuality)).font(.subheadline.bold()) }
                            .padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial).overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5)).clipShape(Capsule()).shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2).foregroundColor(.white)
                        }.padding(.top, 50).padding(.trailing, 20)
                    }
                    Spacer()
                }
                .opacity(1.0 - Double(max(abs(dragOffset.width), max(0, dragOffset.height)) / 100)).transition(.opacity)
            }
            

            Group {
                Button("") { togglePlayPause() }.keyboardShortcut(.space, modifiers: [])
                Button("") { togglePlayPause() }.keyboardShortcut("k", modifiers: [])
                Button("") { seek(forward: true) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { seek(forward: true) }.keyboardShortcut("l", modifiers: [])
                Button("") { seek(forward: false) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { seek(forward: false) }.keyboardShortcut("j", modifiers: [])
                Button("") { adjustVolume(up: true) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { adjustVolume(up: false) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { toggleMute() }.keyboardShortcut("m", modifiers: [])
                Button("") { toggleFullScreen() }.keyboardShortcut("f", modifiers: [])
                Button("") { changeVideo(offset: -1) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { changeVideo(offset: 1) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("") { videoToPlay = nil }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .edgesIgnoringSafeArea(.all)
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    withAnimation { showControls.toggle() }
                    if showControls { startHideTimer() } else { hideControlsTask?.cancel() }
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    let w = dragOffset.width
                    let h = dragOffset.height
                    
                    if h > 100 && abs(h) > abs(w) {
                        playerManager.shutdown()
                        videoToPlay = nil
                    }
                    else if abs(w) > 100 && abs(w) > abs(h) {
                        if w < 0 {
                            changeVideo(offset: 1)
                        } else {
                            changeVideo(offset: -1)
                        }
                        withAnimation(.spring()) { dragOffset = .zero }
                    } else {
                        withAnimation(.spring()) { dragOffset = .zero }
                    }
                }
        )
        .onAppear { startHideTimer() }
        .onDisappear { playerManager.shutdown() }
        .persistentSystemOverlays(.hidden)
    }
    
    // ショートカット操作用関数
    private func togglePlayPause() {
        if playerManager.isPlaying {
            playerManager.player.pause()
        } else {
            playerManager.player.play()
        }
        showControls = true
        startHideTimer()
    }
    
    private func seek(forward: Bool) {
        let currentTime = playerManager.player.currentTime()
        let delta = CMTime(seconds: forward ? 10 : -10, preferredTimescale: 600)
        let newTime = CMTimeAdd(currentTime, delta)
        playerManager.player.seek(to: newTime)
        showControls = true
        startHideTimer()
    }
    
    private func adjustVolume(up: Bool) {
        let currentVolume = playerManager.player.volume
        let newVolume = max(0.0, min(1.0, Double(currentVolume) + (up ? 0.1 : -0.1)))
        playerManager.player.volume = Float(newVolume)
        showControls = true
        startHideTimer()
    }
    
    private func toggleMute() {
        playerManager.player.isMuted.toggle()
        showControls = true
        startHideTimer()
    }
    
    private func toggleFullScreen() {
        #if canImport(AppKit)
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.toggleFullScreen(nil)
        }
        #endif
    }
    
    private func qualityLabel(_ q: String) -> String { switch q { case "1080p": return "1080p"; case "540p": return "540p"; default: return "Original" } }
    
    private func changeQuality(_ q: String) {
        selectedQuality = q
        let currentVideo = videos[currentIndex]
        var components = URLComponents(string: "\(serverAddress)/video/\(currentVideo.id)")
        components?.queryItems = [URLQueryItem(name: "q", value: q)]
        if let newURL = components?.url {
            playerManager.changeQuality(to: newURL)
        }
        startHideTimer()
    }
    
    private func changeVideo(offset: Int) {
        let newIndex = currentIndex + offset
        guard newIndex >= 0 && newIndex < videos.count else { return }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        currentIndex = newIndex
        let newVideo = videos[newIndex]
        playingVideoID = newVideo.id
        PlaybackHistoryManager.shared.saveLastPlayed(id: newVideo.id)
        
        var components = URLComponents(string: "\(serverAddress)/video/\(newVideo.id)")
        components?.queryItems = [URLQueryItem(name: "q", value: selectedQuality)]
        if let newURL = components?.url {
            playerManager.changeVideo(to: newURL)
        }
        
        showControls = true
        startHideTimer()
    }
    
    private func startHideTimer() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { showControls = false }
            }
        }
    }
}

private struct RemotePhotoViewer: View {
    let photos: [RemoteVideoInfo]
    @State private var currentIndex: Int
    let serverAddress: String
    @Binding var isPresented: Bool
    var downloadManager: DownloadManager?
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    init(photos: [RemoteVideoInfo], initialIndex: Int, serverAddress: String, isPresented: Binding<Bool>, downloadManager: DownloadManager?) {
        self.photos = photos
        self._currentIndex = State(initialValue: initialIndex)
        self.serverAddress = serverAddress
        self._isPresented = isPresented
        self.downloadManager = downloadManager
    }
    
    var body: some View {
        let currentPhoto = photos[currentIndex]
        let url = URL(string: "\(serverAddress)/video/\(currentPhoto.id)")!
        
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: ProgressView().tint(.white)
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(MagnificationGesture()
                            .onChanged { val in let delta = val / lastScale; lastScale = val; scale *= delta }
                            .onEnded { _ in lastScale = 1.0; if scale < 1.0 { withAnimation { scale = 1.0 } } }
                        )
                        .simultaneousGesture(DragGesture()
                            .onChanged { val in
                                if scale > 1 {
                                    offset = CGSize(width: lastOffset.width + val.translation.width, height: lastOffset.height + val.translation.height)
                                } else {
                                    offset = val.translation
                                }
                            }
                            .onEnded { val in
                                if scale > 1 {
                                    lastOffset = offset
                                } else {
                                    if abs(val.translation.height) > 100 && abs(val.translation.height) > abs(val.translation.width) {
                                        isPresented = false
                                    } else if abs(val.translation.width) > 100 {
                                        if val.translation.width < 0 { changePhoto(offset: 1) } else { changePhoto(offset: -1) }
                                        withAnimation { offset = .zero }
                                    } else {
                                        withAnimation { offset = .zero }
                                    }
                                }
                            }
                        )
                        .contextMenu {
                            Button { downloadManager?.startDownload(url: url, filename: currentPhoto.filename, isPhoto: true) } label: { Label("写真アプリに保存", systemImage: "square.and.arrow.down") }
                        }
                case .failure: Text("画像の読み込みに失敗しました").foregroundColor(.white)
                @unknown default: EmptyView()
                }
            }
            
            HStack {
                if currentIndex > 0 {
                    Button(action: { changePhoto(offset: -1) }) {
                        Image(systemName: "chevron.left").font(.system(size: 40)).foregroundColor(.white.opacity(0.3)).padding()
                    }.buttonStyle(PlainButtonStyle())
                }
                Spacer()
                if currentIndex < photos.count - 1 {
                    Button(action: { changePhoto(offset: 1) }) {
                        Image(systemName: "chevron.right").font(.system(size: 40)).foregroundColor(.white.opacity(0.3)).padding()
                    }.buttonStyle(PlainButtonStyle())
                }
            }
            
            // 閉じるボタン
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundColor(.white.opacity(0.8)).padding()
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
            
            Group {
                Button("") { changePhoto(offset: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { changePhoto(offset: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { isPresented = false }.keyboardShortcut(.escape, modifiers: [])
                Button("") { toggleFullScreen() }.keyboardShortcut("f", modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }
    
    private func changePhoto(offset: Int) {
        let newIndex = currentIndex + offset
        if newIndex >= 0 && newIndex < photos.count {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            
            currentIndex = newIndex
            scale = 1.0
            self.offset = .zero
            lastOffset = .zero
        }
    }
    
    private func toggleFullScreen() {
        #if canImport(AppKit)
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.toggleFullScreen(nil)
        }
        #endif
    }
}

private struct VideoInfoSheetView: View {
    let video: RemoteVideoInfo; let serverAddress: String; @Environment(\.dismiss) var dismiss; var downloadManager: DownloadManager?
    private let bgGradient = LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.1, green: 0.1, blue: 0.14)], startPoint: .top, endPoint: .bottom)
    private let accentColor = Color(red: 0.85, green: 0.73, blue: 0.45)
    var body: some View { NavigationView { ScrollView { VStack(spacing: 24) { RemoteVideoThumbnailView(thumbnailURL: URL(string: "\(serverAddress)/thumbnail/\(video.id)")!, duration: video.duration).aspectRatio(16/9, contentMode: .fit).cornerRadius(20).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1)).shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 10).padding(.horizontal, 20).padding(.top, 24); Button(action: startDownload) { HStack { Image(systemName: "square.and.arrow.down"); Text("写真アプリに保存").fontWeight(.bold) }.frame(maxWidth: .infinity).padding().background(LinearGradient(colors: [accentColor, accentColor.opacity(0.8)], startPoint: .leading, endPoint: .trailing)).foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1)).cornerRadius(16).shadow(color: accentColor.opacity(0.2), radius: 8, x: 0, y: 4) }.padding(.horizontal, 20); VStack(alignment: .leading, spacing: 16) { InfoRow(title: "ファイル名", value: video.filename, isMain: true); Divider().background(Color.white.opacity(0.2)); HStack { if !video.isPhoto { VStack(alignment: .leading) { Text("長さ").font(.caption).foregroundColor(.white.opacity(0.6)); Text(formatDuration(video.duration)).font(.subheadline.weight(.semibold)).foregroundColor(.white) }; Spacer() }; VStack(alignment: .leading) { Text("インポート日").font(.caption).foregroundColor(.white.opacity(0.6)); Text(video.importDate, style: .date).font(.subheadline.weight(.semibold)).foregroundColor(.white) }; if !video.isPhoto { Spacer() } }; if let creationDate = video.creationDate { Divider().background(Color.white.opacity(0.2)); VStack(alignment: .leading) { Text("撮影日時").font(.caption).foregroundColor(.white.opacity(0.6)); Text(creationDate, style: .date).font(.subheadline.weight(.semibold)).foregroundColor(.white) } }; Divider().background(Color.white.opacity(0.2)); InfoRow(title: "種類", value: video.isPhoto ? "画像" : "動画", isMain: false) }.padding(24).background(.ultraThinMaterial).cornerRadius(24).overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 0.5)).padding(.horizontal, 20); Spacer(minLength: 40) } }.background(bgGradient.ignoresSafeArea()).navigationTitle("詳細情報").navigationBarTitleDisplayMode(.inline).toolbarColorScheme(.dark, for: .navigationBar).toolbarBackground(Color(red: 0.05, green: 0.05, blue: 0.08), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完了") { dismiss() }.font(.body.weight(.bold)).foregroundColor(accentColor) } } } }
    private func startDownload() { guard let url = URL(string: "\(serverAddress)/video/\(video.id)") else { return }; downloadManager?.startDownload(url: url, filename: video.filename, isPhoto: video.duration == 0); dismiss() }
    private struct InfoRow: View { let title: String; let value: String; var isMain: Bool = false; var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundColor(.white.opacity(0.6)); Text(value).font(isMain ? .headline.weight(.bold) : .subheadline.weight(.semibold)).foregroundColor(.white) } } }
    private func formatDuration(_ totalSeconds: TimeInterval) -> String { let s = Int(totalSeconds); return String(format: "%d:%02d", s / 60, s % 60) }
}

private class ShakeDetectingUIView: UIView {
    var onShake: () -> Void = {}
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { super.didMoveToWindow(); self.becomeFirstResponder() }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake() }
        super.motionEnded(motion, with: event)
    }
}
private struct ShakeDetector: UIViewRepresentable {
    let onShake: () -> Void
    func makeUIView(context: Context) -> ShakeDetectingUIView { let v = ShakeDetectingUIView(); v.onShake = onShake; return v }
    func updateUIView(_ uiView: ShakeDetectingUIView, context: Context) { uiView.onShake = onShake }
}
private struct ShakeViewModifier: ViewModifier {
    let onShake: () -> Void
    func body(content: Content) -> some View { content.background(ShakeDetector(onShake: onShake).frame(width: 0, height: 0)) }
}
extension View {
    func onShake(perform action: @escaping () -> Void) -> some View { self.modifier(ShakeViewModifier(onShake: action)) }
}
