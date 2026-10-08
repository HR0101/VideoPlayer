//
//  Views:AlbumListView.swift
//  VideoPlayer
//
//  Created by hara ryuto   on 2025/06/20.
//

import SwiftUI

// MARK: - Main Views

// MARK: AlbumListView
/// アプリケーションのメイン画面。アルバムを一覧表示する。
struct AlbumListView: View {
    @EnvironmentObject var videoManager: VideoManager
    @State private var showingCreateAlbumAlert = false
    @State private var newAlbumName = ""
    @State private var albumToDelete: String?

    var body: some View {
        NavigationView {
            List {
                // Section 1: ライブラリ
                Section(header: Text("ライブラリ")) {
                    NavigationLink(destination: VideoGridView(albumType: .all)) {
                        AlbumRow(albumType: .all)
                    }
                    NavigationLink(destination: VideoGridView(albumType: .trash)) {
                        AlbumRow(albumType: .trash)
                    }
                }

                // Section 2: マイアルバム
                Section(header: Text("マイアルバム")) {
                    ForEach(videoManager.userAlbums, id: \.self) { albumName in
                        NavigationLink(destination: VideoGridView(albumType: .user(albumName))) {
                            AlbumRow(albumType: .user(albumName))
                        }
                    }
                    .onDelete(perform: scheduleAlbumDeletion)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("アルバム")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingCreateAlbumAlert = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showingCreateAlbumAlert) {
                // 新規アルバム作成用のシート
                NavigationView {
                    VStack(spacing: 20) {
                        TextField("アルバム名", text: $newAlbumName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding()
                        
                        Button("作成") {
                            videoManager.createAlbum(name: newAlbumName)
                            newAlbumName = ""
                            showingCreateAlbumAlert = false
                        }
                        .disabled(newAlbumName.isEmpty)
                        
                        Spacer()
                    }
                    .navigationTitle("新規アルバム")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("キャンセル") {
                                newAlbumName = ""
                                showingCreateAlbumAlert = false
                            }
                        }
                    }
                }
            }
            .alert(item: $albumToDelete, content: { albumName in
                Alert(
                    title: Text("アルバムの削除"),
                    message: Text("アルバム「\(albumName)」を削除してもよろしいですか？中のビデオはすべて削除されます."),
                    primaryButton: .destructive(Text("削除")) {
                        videoManager.deleteAlbum(name: albumName)
                    },
                    secondaryButton: .cancel()
                )
            })
            .onAppear {
                // 画面が表示されるたびにアルバムリストを更新
                videoManager.loadAlbums()
            }
        }
    }
    
    private func scheduleAlbumDeletion(at offsets: IndexSet) {
        // 削除するアルバムの名前を設定してアラートを表示
        offsets.forEach { index in
            self.albumToDelete = videoManager.userAlbums[index]
        }
    }
}
