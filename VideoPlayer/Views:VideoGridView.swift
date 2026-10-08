//
//  Views:VideoGridView.swift
//  VideoPlayer
//
//  Created by hara ryuto   on 2025/06/20.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: VideoGridView
/// 選択されたアルバムのビデオをグリッド表示する画面
struct VideoGridView: View {
    @EnvironmentObject var videoManager: VideoManager
    @EnvironmentObject var appSettings: AppSettings
    let albumType: AlbumType

    @State private var videos: [VideoMetadata] = []
    @State private var isEditing = false
    @State private var selectedVideos = Set<URL>()
    @State private var showingFileImporter = false
    @State private var showingPlayer = false
    @State private var selectedVideoURL: URL?
    @State private var sortOrder: SortOrder = .dateAdded
    @State private var showingEmptyTrashConfirm = false

    // グリッドレイアウトの定義
    private let columns: [GridItem] = Array(repeating: .init(.flexible()), count: 3)

    var body: some View {
        Group {
            if videos.isEmpty {
                // ビデオがない場合の表示
                EmptyStateView(
                    message: "ビデオがありません",
                    systemImage: "video.slash.fill"
                )
            } else {
                // ビデオがある場合のグリッド表示
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(videos) { video in
                            ZStack(alignment: .topTrailing) {
                                LocalVideoThumbnailView(videoURL: video.url)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                    .onTapGesture {
                                        if isEditing {
                                            toggleSelection(for: video.url)
                                        } else {
                                            selectedVideoURL = video.url
                                            showingPlayer = true
                                        }
                                    }
                                
                                if isEditing {
                                    Image(systemName: selectedVideos.contains(video.url) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundColor(selectedVideos.contains(video.url) ? .white : .gray.opacity(0.8))
                                        .background(Circle().fill(selectedVideos.contains(video.url) ? .blue : .black.opacity(0.3)))
                                        .padding(4)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [UTType.movie, UTType.video], allowsMultipleSelection: true) { result in
            handleImport(result: result)
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            if let url = selectedVideoURL {
                CustomVideoPlayerContainer(videoURL: url)
            }
        }
        .onAppear(perform: loadVideos)
        .onChange(of: sortOrder) { _ in loadVideos() }
        .alert("ごみ箱を空にする", isPresented: $showingEmptyTrashConfirm) {
            Button("すべて削除", role: .destructive) {
                videoManager.emptyTrash()
                loadVideos()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ごみ箱内のすべてのビデオを完全に削除します。この操作は取り消せません。")
        }
    }
    
    // MARK: View Logic
    
    private var navigationTitle: String {
        if isEditing {
            return "\(selectedVideos.count)件選択中"
        } else {
            return albumType.displayName
        }
    }
    
    private func loadVideos() {
        let fetchedURLs = videoManager.fetchVideos(for: albumType)
        let metadata = fetchedURLs.map { VideoMetadata(url: $0) }
        
        // 並べ替え
        videos = metadata.sorted { (lhs, rhs) -> Bool in
            switch sortOrder {
            case .dateAdded:
                return (lhs.dateAdded ?? .distantPast) > (rhs.dateAdded ?? .distantPast)
            case .creationDate:
                return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
            case .name:
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
        }
    }
    
    private func handleImport(result: Result<[URL], Error>) {
        if case .user(let albumName) = albumType {
            switch result {
            case .success(let urls):
                videoManager.importVideos(from: urls, to: albumName)
                loadVideos() // インポート後にリストを更新
            case .failure(let error):
                print("ファイルのインポートに失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func toggleSelection(for url: URL) {
        if selectedVideos.contains(url) {
            selectedVideos.remove(url)
        } else {
            selectedVideos.insert(url)
        }
    }

    private func deleteSelectedVideos() {
        videoManager.moveVideosToTrash(urls: Array(selectedVideos))
        exitEditMode()
    }
    
    private func restoreSelectedVideos() {
        videoManager.restoreVideosFromTrash(urls: Array(selectedVideos))
        exitEditMode()
    }

    private func deletePermanentlySelectedVideos() {
        videoManager.deletePermanently(urls: Array(selectedVideos))
        exitEditMode()
    }
    
    private func exitEditMode() {
        loadVideos()
        selectedVideos.removeAll()
        isEditing = false
    }
    
    // MARK: Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent { // <- 修正点: `some View` から `some ToolbarContent` へ変更
        // 選択ボタン
        ToolbarItem(placement: .navigationBarTrailing) {
            if !videos.isEmpty {
                Button(isEditing ? "完了" : "選択") {
                    isEditing.toggle()
                    if !isEditing {
                        selectedVideos.removeAll()
                    }
                }
            }
        }
        
        // メインのツールバーアイテム
        ToolbarItem(placement: .navigationBarTrailing) {
            if !isEditing {
                Menu {
                    // 並べ替えメニュー
                    Picker("並べ替え", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    
                    // サムネイル設定メニュー
                    Picker("サムネイル", selection: $appSettings.thumbnailOption) {
                        ForEach(ThumbnailOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    
                    // インポートボタン（ごみ箱とすべてのビデオ以外）
                    if case .user = albumType {
                        Button(action: { showingFileImporter = true }) {
                            Label("ビデオをインポート", systemImage: "plus")
                        }
                    }
                    
                    // ごみ箱を空にするボタン（ごみ箱のみ）
                    if albumType == .trash && !videos.isEmpty {
                        Button(role: .destructive, action: { showingEmptyTrashConfirm = true }) {
                            Label("ごみ箱を空にする", systemImage: "trash.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }

        // 編集モード時の下部ツールバー
        if isEditing {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Spacer()
                    if albumType == .trash {
                        // ごみ箱用のツールバー
                        Button("復元", action: restoreSelectedVideos).disabled(selectedVideos.isEmpty)
                        Spacer()
                        Button("削除", role: .destructive, action: deletePermanentlySelectedVideos).disabled(selectedVideos.isEmpty)
                    } else {
                        // 通常アルバム用のツールバー
                        Button(action: deleteSelectedVideos) {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedVideos.isEmpty)
                    }
                    Spacer()
                }
            }
        }
    }
}
