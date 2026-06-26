import SwiftUI
import AVFoundation

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
            Color.black.opacity(0.55)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture { isPresented = false }

            VStack(spacing: 8) {
                Image(systemName: "trash.fill")
                    .font(.title2)
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.top, 22)
                    .padding(.bottom, 4)

                Text("ごみ箱を空にしますか？")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("この操作は取り消せません。")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.bottom, 16)

                Divider().background(Color.white.opacity(0.15))

                HStack(spacing: 0) {
                    Button {
                        onConfirm()
                        isPresented = false
                    } label: {
                        Text("空にする")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .foregroundStyle(.red)

                    Color.white.opacity(0.15).frame(width: 0.5, height: 46)

                    Button {
                        isPresented = false
                    } label: {
                        Text("キャンセル")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: 290)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous).strokeBorder(AppTheme.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
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
    @State private var hasLoaded = false
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
    
    private let primaryDarkColor = Color.appDarkBackground
    private let accentGlowColor  = Color.appGold


    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private func adaptiveColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if horizontalSizeClass == .regular {
            if width > 1100 { count = 7 }
            else if width > 900 { count = 6 }
            else if width > 600 { count = 5 }
            else { count = 4 }
        } else {
            count = 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 3), count: count)
    }

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
            AppBackground()

            ZStack(alignment: .bottom) {
                if hasLoaded && filteredAndSortedVideos.isEmpty {
                    emptyStateView
                } else {
                    ScrollViewReader { proxy in
                        GeometryReader { geo in
                            ScrollView {
                                LazyVGrid(columns: adaptiveColumns(for: geo.size.width), spacing: 3) {
                                    ForEach(filteredAndSortedVideos) { metadata in
                                        thumbnailView(for: metadata)
                                            .id(metadata.id)
                                    }
                                }
                                .padding(.horizontal, 3)
                                .padding(.top, 3)
                                .padding(.bottom, isSelectionMode ? 110 : 12)
                            }
                            .onPreferenceChange(VideoThumbnailPreferenceKey.self) { frames in
                                self.thumbnailFrames = frames
                            }
                        }
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

    /// 空のアルバム / 空のごみ箱の案内表示
    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: albumType == .trash ? "trash" : "film.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AppTheme.goldGradient)
                .shadow(color: Color.appGold.opacity(0.3), radius: 12)

            Text(albumType == .trash ? "ごみ箱は空です" : "ビデオがありません")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            if albumType != .trash {
                Text(searchText.isEmpty
                     ? "右上の＋ボタンから\n写真ライブラリやファイルを取り込めます"
                     : "「\(searchText)」に一致するビデオはありません")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        Button(action: { Haptics.warning(); deleteSelectedVideos() }) {
            Label("\(selectedVideos.count)件を削除", systemImage: "trash.fill")
                .font(.headline.weight(.bold))
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
                .background(
                    selectedVideos.isEmpty
                    ? AnyShapeStyle(Color.white.opacity(0.08))
                    : AnyShapeStyle(LinearGradient(colors: [.red, .red.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                )
                .foregroundStyle(selectedVideos.isEmpty ? Color.appTextTertiary : .white)
                .clipShape(Capsule())
                .shadow(color: selectedVideos.isEmpty ? .clear : .red.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(PressableCardStyle(scale: 0.97))
        .disabled(selectedVideos.isEmpty)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.white.opacity(0.1)), alignment: .top)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var restoreButton: some View {
        Button(action: { Haptics.success(); restoreSelectedVideos() }) {
            Label("\(selectedVideos.count)件を元に戻す", systemImage: "arrow.uturn.backward")
                .font(.headline.weight(.bold))
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
                .background(
                    selectedVideos.isEmpty
                    ? AnyShapeStyle(Color.white.opacity(0.08))
                    : AnyShapeStyle(AppTheme.goldGradient)
                )
                .foregroundStyle(selectedVideos.isEmpty ? Color.appTextTertiary : Color.appDarkBackground)
                .clipShape(Capsule())
                .shadow(color: selectedVideos.isEmpty ? .clear : Color.appGold.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(PressableCardStyle(scale: 0.97))
        .disabled(selectedVideos.isEmpty)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.white.opacity(0.1)), alignment: .top)
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
        let isSelected = selectedVideos.contains(metadata.url)

        ZStack(alignment: .topTrailing) {
            LocalVideoThumbnailView(url: metadata.url)
                .contextMenu {
                    if albumType == .trash {
                        Button { restoreSingleVideo(at: metadata.url) } label: { Label("元に戻す", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button(role: .destructive) { deleteSingleVideo(at: metadata.url) } label: { Label("削除", systemImage: "trash") }
                    }
                }

            if isSelectionMode && isSelected {
                Color.black.opacity(0.35)
            }

            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSelected ? Color.appGold : .white)
                    .symbolEffect(.bounce, value: isSelected)
                    .padding(6)
                    .background(
                        Group {
                            if !isSelected {
                                Color.black.opacity(0.5).clipShape(Circle())
                            }
                        }
                    )
                    .offset(x: -2, y: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous)
                .strokeBorder(isSelectionMode && isSelected ? Color.appGold : Color.white.opacity(0.06),
                              lineWidth: isSelectionMode && isSelected ? 2 : 0.5)
        )
        .scaleEffect(isSelectionMode && isSelected ? 0.94 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                Haptics.soft()
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
            let urls = await videoManager.fetchVideos(for: albumType)
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
            self.hasLoaded = true
        }
    }

    private func emptyTrash() {
        Task {
            await videoManager.emptyTrash()
            loadVideos()
        }
    }
}
