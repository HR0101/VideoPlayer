import SwiftUI
import AVFoundation

// ===================================
//  VideoGridView.swift (デザイン修正版)
// ===================================
// アルバム内のビデオをグリッド表示します。

private struct VideoThumbnailPreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Custom Views (Player and Alert)

private struct PlayerView: View {
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
        // ★ 修正: ZStack全体でセーフエリアを無視する
        .edgesIgnoringSafeArea(.all)
        .simultaneousGesture(
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
        .persistentSystemOverlays(.hidden)
    }
}

private struct CustomTrashAlertView: View {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
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

                    // ★ 修正: DividerをHStack内で使用
                    Color.gray.opacity(0.5).frame(width: 1, height: 40)

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
}


struct VideoGridView: View {
    private enum DragSelectionState {
        case inactive, selecting, deselecting, scrolling
    }

    let albumType: AlbumType
    let albumName: String
    @ObservedObject var videoManager: VideoManager
    @EnvironmentObject var appSettings: AppSettings

    @State private var videoMetadatas: [VideoMetadata] = []
    @State private var videoToPlay: IdentifiableURL?

    @State private var showImportOptions = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false

    @State private var showEmptyTrashAlert = false

    @State private var isSelectionMode = false
    @State private var selectedVideos = Set<URL>()

    @State private var sortOrder: SortOrder = .byDateAdded

    @State private var searchText = ""

    @State private var thumbnailFrames: [URL: CGRect] = [:]
    @State private var dragSelectedURLs = Set<URL>()
    @State private var dragSelectionMode: DragSelectionState = .inactive
    @GestureState private var dragValue: DragGesture.Value? = nil
    
    // ★ 追加: カスタムカラー定義
    private let primaryDarkColor = Color(red: 0.1, green: 0.1, blue: 0.1)
    private let accentGlowColor = Color.cyan


    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var filteredAndSortedVideos: [VideoMetadata] {
        let filtered: [VideoMetadata]
        if searchText.isEmpty {
            filtered = videoMetadatas
        } else {
            filtered = videoMetadatas.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(searchText) }
        }
        
        switch sortOrder {
        case .byDateAdded:
            return filtered.sorted { $0.dateAdded > $1.dateAdded }
        case .byCreationDate:
            return filtered.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .byName:
            return filtered.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        case .byLengthDescending:
            return filtered.sorted { $0.duration > $1.duration }
        case .byLengthAscending:
            return filtered.sorted { $0.duration < $1.duration }
        }
    }

    private var allVideosSelected: Bool {
        !filteredAndSortedVideos.isEmpty && selectedVideos.count == filteredAndSortedVideos.count
    }

    var body: some View {
        ZStack {
            // ★ 追加: 背景色をAlbumListViewと統一
            primaryDarkColor.ignoresSafeArea()
            
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(filteredAndSortedVideos) { metadata in
                                thumbnailView(for: metadata)
                                    .id(metadata.id)
                            }
                        }
                    }
                    .onPreferenceChange(VideoThumbnailPreferenceKey.self) { frames in
                        self.thumbnailFrames = frames
                    }
                }

                if isSelectionMode {
                    if albumType == .trash {
                        restoreButton
                    } else {
                        deleteButton
                    }
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedVideos.count)件を選択中" : albumName)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "ビデオを検索")
            // ★ 修正: ナビゲーションバーのカスタムをAlbumListViewと統一
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(primaryDarkColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                toolbarContent()
            }
            .sheet(isPresented: $showPhotoPicker) {
                let importAlbumName = albumType == .all ? "マイアルバム" : albumName
                PhotoPicker(albumName: importAlbumName, videoManager: videoManager, onDismiss: loadVideos)
            }
            .sheet(isPresented: $showDocumentPicker) {
                let importAlbumName = albumType == .all ? "マイアルバム" : albumName
                DocumentPicker(albumName: importAlbumName, videoManager: videoManager, onDismiss: loadVideos)
            }
            .fullScreenCover(item: $videoToPlay) { identifiableUrl in
                PlayerView(url: identifiableUrl.url, videoToPlay: $videoToPlay)
            }
            .onAppear(perform: loadVideos)
            .blur(radius: showEmptyTrashAlert ? 5 : 0)
            .disabled(showEmptyTrashAlert)
            .scrollDisabled(dragSelectionMode == .selecting || dragSelectionMode == .deselecting)
            .gesture(
                isSelectionMode ?
                DragGesture(minimumDistance: 5.0, coordinateSpace: .global)
                    .updating($dragValue) { value, state, _ in
                        state = value
                    }
                : nil
            )
            .onChange(of: dragValue) { oldValue, newValue in
                handleDragChange(from: oldValue, to: newValue)
            }
            .confirmationDialog("ビデオをインポート", isPresented: $showImportOptions, titleVisibility: .visible) {
                Button("写真ライブラリ") { showPhotoPicker = true }
                Button("ファイル") { showDocumentPicker = true }
                Button("キャンセル", role: .cancel) {}
            }

            if showEmptyTrashAlert {
                CustomTrashAlertView(isPresented: $showEmptyTrashAlert, onConfirm: emptyTrash)
            }
        }
        .animation(.easeInOut, value: showEmptyTrashAlert)
        .animation(.default, value: isSelectionMode)
    }

    // MARK: - Subviews
    
    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelectionMode {
                Button(allVideosSelected ? "選択を解除" : "すべて選択", action: toggleSelectAll)
                    .disabled(filteredAndSortedVideos.isEmpty)
                    .foregroundColor(accentGlowColor)
            }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
            if isSelectionMode {
                Button("キャンセル", action: exitSelectionMode)
                    .foregroundColor(accentGlowColor)
            } else {
                HStack {
                    if albumType == .trash {
                        Button("ごみ箱を空にする") {
                            showEmptyTrashAlert = true
                        }.disabled(videoMetadatas.isEmpty)
                         .foregroundColor(.red)
                    } else {
                        Button(action: { showImportOptions = true }) {
                            Image(systemName: "plus")
                                .foregroundColor(accentGlowColor)
                        }
                        Menu { menuContent } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(accentGlowColor)
                        }
                        Button("選択") { isSelectionMode = true }
                            .disabled(videoMetadatas.isEmpty)
                            .foregroundColor(accentGlowColor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        Button(action: deleteSelectedVideos) {
            Text("\(selectedVideos.count)件を削除")
                .fontWeight(.bold)
                .padding()
                .frame(maxWidth: .infinity)
                .background(selectedVideos.isEmpty ? Color.gray.opacity(0.5) : Color.red)
                .foregroundColor(.white)
                .cornerRadius(10)
        }
        .disabled(selectedVideos.isEmpty)
        .padding()
        // ★ 修正: よりモダンなぼかし効果
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var restoreButton: some View {
        Button(action: restoreSelectedVideos) {
            Text("\(selectedVideos.count)件を元に戻す")
                .fontWeight(.bold)
                .padding()
                .frame(maxWidth: .infinity)
                .background(selectedVideos.isEmpty ? Color.gray.opacity(0.5) : accentGlowColor)
                .foregroundColor(.white)
                .cornerRadius(10)
        }
        .disabled(selectedVideos.isEmpty)
        .padding()
        // ★ 修正: よりモダンなぼかし効果
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

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

    @ViewBuilder
    private func thumbnailView(for metadata: VideoMetadata) -> some View {
        ZStack(alignment: .topTrailing) {
            LocalVideoThumbnailView(url: metadata.url)
                .contextMenu {
                    if albumType == .trash {
                        Button { restoreSingleVideo(at: metadata.url) } label: { Label("元に戻す", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button(role: .destructive) { deleteSingleVideo(at: metadata.url) } label: { Label("削除", systemImage: "trash") }
                    }
                }
            
            // ★ 追加: ネオ・モーフィズム風の影
            .shadow(color: Color.black.opacity(0.4), radius: 6, x: 3, y: 3)
            .shadow(color: Color.white.opacity(0.05), radius: 3, x: -1, y: -1)

            if isSelectionMode && selectedVideos.contains(metadata.url) {
                Color.black.opacity(0.4)
            }
            
            if isSelectionMode {
                let isSelected = selectedVideos.contains(metadata.url)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    // ★ 修正: 選択時を鮮やかな色に
                    .font(.title2.weight(.bold))
                    .foregroundColor(isSelected ? accentGlowColor : .white)
                    .padding(5)
                    .background(
                        Group {
                            if !isSelected {
                                Color.black.opacity(0.5).clipShape(Circle())
                            }
                        }
                    )
                    // ★ 修正: 右上に少し寄せる
                    .offset(x: -2, y: 2)
            }
        }
        // ★ 修正: 角を大きく丸める
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                toggleSelection(for: metadata.url)
            } else {
                self.videoToPlay = IdentifiableURL(url: metadata.url)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: VideoThumbnailPreferenceKey.self,
                    value: [metadata.url: geo.frame(in: .global)]
                )
            }
        )
    }

    // MARK: - Logic
    
    private func handleDragChange(from oldValue: DragGesture.Value?, to newValue: DragGesture.Value?) {
        guard let value = newValue else {
            dragSelectionMode = .inactive
            dragSelectedURLs.removeAll()
            return
        }

        if oldValue == nil {
            if abs(value.translation.width) > abs(value.translation.height) {
                guard let url = thumbnailFrames.first(where: { $1.contains(value.startLocation) })?.key else {
                    dragSelectionMode = .scrolling
                    return
                }
                dragSelectionMode = selectedVideos.contains(url) ? .deselecting : .selecting
            } else {
                dragSelectionMode = .scrolling
            }
        }

        if dragSelectionMode == .selecting || dragSelectionMode == .deselecting {
            processDragSelection(location: value.location, isAdding: dragSelectionMode == .selecting)
        }
    }

    private func processDragSelection(location: CGPoint, isAdding: Bool) {
        guard let url = thumbnailFrames.first(where: { $1.contains(location) })?.key else { return }
        guard !dragSelectedURLs.contains(url) else { return }
        
        dragSelectedURLs.insert(url)
        
        if isAdding {
            selectedVideos.insert(url)
        } else {
            selectedVideos.remove(url)
        }
    }

    private func toggleSelectAll() {
        if allVideosSelected {
            selectedVideos.removeAll()
        } else {
            selectedVideos = Set(filteredAndSortedVideos.map { $0.url })
        }
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

    private func deleteSingleVideo(at url: URL) {
        withAnimation {
            if albumType == .trash {
                videoManager.deletePermanently(url: url)
            } else {
                videoManager.moveVideoToTrash(url: url)
            }
            loadVideos()
        }
    }

    private func restoreSelectedVideos() {
        withAnimation {
            for url in selectedVideos {
                videoManager.restoreVideoFromTrash(url: url)
            }
            exitSelectionMode()
            loadVideos()
        }
    }

    private func restoreSingleVideo(at url: URL) {
        withAnimation {
            videoManager.restoreVideoFromTrash(url: url)
            loadVideos()
        }
    }

    private func loadVideos() {
        Task {
            let urls = videoManager.fetchVideos(for: albumType)
            var metadatas: [VideoMetadata] = []
            for url in urls {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    let asset = AVURLAsset(url: url)
                    
                    let duration = try? await asset.load(.duration)
                    let durationInSeconds = duration?.seconds ?? 0
                    
                    var creationDate: Date?
                    if #available(iOS 15.0, *) {
                        creationDate = try? await asset.load(.creationDate)?.dateValue
                    } else {
                        creationDate = resourceValues.creationDate
                    }
                    
                    metadatas.append(VideoMetadata(url: url,
                                                   dateAdded: resourceValues.contentModificationDate ?? .distantPast,
                                                   creationDate: creationDate,
                                                   duration: durationInSeconds))
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
