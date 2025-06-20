import SwiftUI
import AVFoundation

// ===================================
//  VideoGridView.swift
// ===================================
// アルバム内のビデオをグリッド表示します。
// ツールバーの定義を単一のモディファイアに統合し、安定性を向上させました。

struct VideoGridView: View {
    let albumType: AlbumType
    let albumName: String
    @ObservedObject var videoManager: VideoManager
    @EnvironmentObject var appSettings: AppSettings
    
    @State private var videoMetadatas: [VideoMetadata] = []
    @State private var videoToPlay: IdentifiableURL?
    @State private var showDocumentPicker = false
    @State private var showEmptyTrashAlert = false
    
    @State private var isSelectionMode = false
    @State private var selectedVideos = Set<URL>()
    
    @State private var sortOrder: SortOrder = .byDateAdded

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    
    private var sortedVideos: [VideoMetadata] {
        switch sortOrder {
        case .byDateAdded:
            return videoMetadatas.sorted { $0.dateAdded > $1.dateAdded }
        case .byCreationDate:
            return videoMetadatas.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .byName:
            return videoMetadatas.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        }
    }

    var body: some View {
        ZStack {
            // Main Content
            VStack {
                if videoMetadatas.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(sortedVideos) { metadata in
                                thumbnailView(for: metadata)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedVideos.count)件を選択中" : albumName)
            .navigationBarTitleDisplayMode(.inline)
            // ----- TOOLBAR REFACTORED -----
            // ツールバーの定義を一つにまとめ、条件分岐を内部で行うように変更
            .toolbar {
                // Top Toolbar Content
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelectionMode {
                        Button("キャンセル") {
                            isSelectionMode = false
                            selectedVideos.removeAll()
                        }
                    } else {
                        if albumType == .trash {
                            Button("ごみ箱を空にする") {
                                showEmptyTrashAlert = true
                            }.disabled(videoMetadatas.isEmpty)
                        } else {
                            Button(action: { showDocumentPicker = true }) { Image(systemName: "plus") }
                            Menu { menuContent } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                            Button("選択") { isSelectionMode = true }.disabled(videoMetadatas.isEmpty)
                        }
                    }
                }
                
                // Bottom Toolbar Content (Conditional)
                if isSelectionMode {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button(action: deleteSelectedVideos) {
                            Image(systemName: "trash")
                        }.disabled(selectedVideos.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                let importAlbumName = albumType == .all ? "マイアルバム" : albumName
                DocumentPicker(albumName: importAlbumName, videoManager: videoManager, onDismiss: loadVideos)
            }
            .fullScreenCover(item: $videoToPlay) { identifiableUrl in
                PlayerView(url: identifiableUrl.url, videoToPlay: $videoToPlay)
            }
            .onAppear(perform: loadVideos)
            .disabled(showEmptyTrashAlert)
            .blur(radius: showEmptyTrashAlert ? 5 : 0)

            // Custom Alert Implementation
            if showEmptyTrashAlert {
                CustomTrashAlertView(isPresented: $showEmptyTrashAlert, onConfirm: emptyTrash)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: showEmptyTrashAlert)
    }
    
    // mainToolbar と bottomToolbar は .toolbar { ... } 内に統合されたため不要になりました.
    
    @ViewBuilder
    private var menuContent: some View {
        Picker("並べ替え", selection: $sortOrder) {
            ForEach(SortOrder.allCases) { order in
                Text(order.rawValue).tag(order)
            }
        }
        Divider()
        Picker("サムネイル", selection: $appSettings.thumbnailOption) {
            ForEach(ThumbnailOption.allCases) { option in
                Text(option.description).tag(option)
            }
        }
    }

    // MARK: - Subviews & Logic
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("ビデオがありません").font(.headline)
            if albumType != .trash && albumType != .all {
                Text("右上の「＋」ボタンからビデオをインポートしてください").font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }
    
    @ViewBuilder
    private func thumbnailView(for metadata: VideoMetadata) -> some View {
        ZStack(alignment: .topTrailing) {
            LocalVideoThumbnailView(url: metadata.url)
                .onTapGesture {
                    if isSelectionMode {
                        toggleSelection(for: metadata.url)
                    } else {
                        self.videoToPlay = IdentifiableURL(url: metadata.url)
                    }
                }
            if isSelectionMode {
                if selectedVideos.contains(metadata.url) {
                    ZStack {
                        Color.black.opacity(0.5)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding(4)
                    }
                    .cornerRadius(8)
                } else {
                    Image(systemName: "circle")
                        .font(.title)
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
            }
        }
        .cornerRadius(8)
    }

    private func toggleSelection(for url: URL) {
        if selectedVideos.contains(url) {
            selectedVideos.remove(url)
        } else {
            selectedVideos.insert(url)
        }
    }
    
    private func exitSelectionMode() {
        isSelectionMode = false
        selectedVideos.removeAll()
    }

    private func deleteSelectedVideos() {
        withAnimation {
            for url in selectedVideos {
                if albumType == .trash {
                    videoManager.deletePermanently(url: url)
                } else {
                    videoManager.moveVideoToTrash(url: url)
                }
            }
            exitSelectionMode()
            loadVideos()
        }
    }
    
    private func loadVideos() {
        Task {
            let urls = videoManager.fetchVideos(for: albumType)
            var metadatas: [VideoMetadata] = []
            for url in urls {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    let asset = AVURLAsset(url: url)
                    var creationDate: Date?
                    if #available(iOS 15.0, *) {
                        creationDate = try? await asset.load(.creationDate)?.dateValue
                    } else {
                        let metadata = try? await asset.load(.metadata)
                        creationDate = metadata?.first(where: { $0.commonKey == .commonKeyCreationDate })?.dateValue
                    }
                    
                    metadatas.append(VideoMetadata(url: url, dateAdded: resourceValues.contentModificationDate ?? .distantPast, creationDate: creationDate))
                } catch {
                    print("Error loading metadata for \(url.lastPathComponent): \(error)")
                }
            }
            self.videoMetadatas = metadatas
        }
    }
    
    private func emptyTrash() {
        videoManager.emptyTrash()
        loadVideos()
    }
}

// MARK: - Custom Alert View

private struct CustomTrashAlertView: View {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    var body: some View {
        Color.black.opacity(0.4)
            .edgesIgnoringSafeArea(.all)
            .onTapGesture { isPresented = false }

        VStack(spacing: 15) {
            Text("ごみ箱を空にしますか？")
                .font(.headline)
                .padding(.top)

            Text("この操作は取り消せません。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Divider()

            HStack {
                Button {
                    onConfirm()
                    isPresented = false
                } label: {
                    Text("空にする")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .foregroundColor(.red)

                Divider()

                Button {
                    isPresented = false
                } label: {
                    Text("キャンセル")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 280)
        .background(.thinMaterial)
        .cornerRadius(14)
        .shadow(radius: 10)
    }
}

// MARK: - Player Related Views

struct PlayerView: View {
    let url: URL
    @Binding var videoToPlay: IdentifiableURL?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(1.0 - Double(abs(dragOffset.height) / 500))
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                CustomVideoPlayerContainer(videoURL: url)
                    .scaleEffect(max(0.8, 1 - (abs(dragOffset.height) / 800)))
            }
            .offset(y: dragOffset.height)
            .opacity(1.0 - Double(abs(dragOffset.height) / 300))
        }
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    if abs(dragOffset.height) > 100 {
                        videoToPlay = nil
                    } else {
                        withAnimation(.spring()) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .transition(.move(edge: .bottom))
    }
}
