// ===================================
//  AlbumListView.swift
// ===================================
// アプリのメイン画面。特別なアルバムとユーザーアルバムを一覧表示します。

import SwiftUI

struct AlbumListView: View {
    @StateObject private var videoManager = VideoManager()
    @State private var newAlbumName = ""
    @State private var isShowingCreateAlbumAlert = false
    
    @State private var albumToDelete: String?
    @State private var isShowingDeleteConfirmAlert = false

    // 「お気に入り」の定義を削除しました.
    private let specialAlbums: [(type: AlbumType, name: String, icon: String)] = [
        (.all, "すべてのビデオ", "square.stack.fill"),
        (.trash, "ごみ箱", "trash.fill")
    ]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("ライブラリ")) {
                    ForEach(specialAlbums, id: \.type) { album in
                        NavigationLink(destination: VideoGridView(albumType: album.type, albumName: album.name, videoManager: videoManager)) {
                            HStack {
                                Image(systemName: album.icon)
                                    .foregroundColor(album.type == .trash ? .gray : .blue)
                                Text(album.name)
                            }
                        }
                    }
                }
                
                Section(header: Text("マイアルバム")) {
                    ForEach(videoManager.albums, id: \.self) { album in
                        NavigationLink(destination: VideoGridView(albumType: .user(album), albumName: album, videoManager: videoManager)) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.yellow)
                                Text(album)
                            }
                        }
                    }
                    .onDelete(perform: prepareToDeleteAlbum)
                }
            }
            .navigationTitle("アルバム")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isShowingCreateAlbumAlert = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            .alert("新しいアルバム", isPresented: $isShowingCreateAlbumAlert) {
                TextField("アルバム名", text: $newAlbumName)
                Button("作成", action: createAlbum)
                Button("キャンセル", role: .cancel) {}
            }
            .alert("アルバムを削除", isPresented: $isShowingDeleteConfirmAlert, presenting: albumToDelete) { album in
                Button("削除", role: .destructive) {
                    videoManager.deleteAlbum(name: album)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { album in
                Text("「\(album)」を削除しますか？\nこのアルバム内のすべてのビデオが完全に削除され、この操作は取り消せません。")
            }
            .onAppear {
                videoManager.loadAlbums()
            }
        }
    }
    
    private func createAlbum() {
        if !newAlbumName.isEmpty {
            videoManager.createAlbum(name: newAlbumName)
            newAlbumName = ""
        }
    }
    
    private func prepareToDeleteAlbum(at offsets: IndexSet) {
        if let index = offsets.first {
            self.albumToDelete = videoManager.albums[index]
            self.isShowingDeleteConfirmAlert = true
        }
    }
}
