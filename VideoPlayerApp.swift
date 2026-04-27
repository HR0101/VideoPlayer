import SwiftUI

// ===================================
//  VideoPlayerApp.swift
// ===================================

@main
struct VideoPlayerApp: App {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var serverBrowser = ServerBrowser()
    
    @StateObject private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                
                AlbumListView()
                    .environmentObject(appSettings)
                    .environmentObject(serverBrowser)
                    .environmentObject(downloadManager)
                
                
                if downloadManager.isDownloading || downloadManager.successMessage != nil || downloadManager.errorMessage != nil {
                    DownloadStatusOverlay()
                        .environmentObject(downloadManager)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(100)
                }
            }
        }
    }
}


struct DownloadStatusOverlay: View {
    @EnvironmentObject var downloadManager: DownloadManager
    
    var body: some View {
        VStack(spacing: 10) {
            
            if let errorMsg = downloadManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.white)
                    Text(errorMsg).font(.caption).foregroundColor(.white).lineLimit(2)
                    Spacer()
                    Button(action: { downloadManager.errorMessage = nil }) {
                        Image(systemName: "xmark").foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding()
                .background(Color.red.opacity(0.9))
                .cornerRadius(12)
                .padding(.horizontal)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation { downloadManager.errorMessage = nil }
                    }
                }
            }
            
            
            if let successMsg = downloadManager.successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.white)
                    Text(successMsg).font(.subheadline).foregroundColor(.white)
                    Spacer()
                }
                .padding()
                .background(Color.green.opacity(0.9))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            
            if downloadManager.isDownloading {
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("ダウンロード中...").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(downloadManager.progress * 100))%").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        
                        Text(downloadManager.currentFilename)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        ProgressView(value: downloadManager.progress)
                            .progressViewStyle(.linear)
                    }
                    
                    Button(action: { downloadManager.cancelDownload() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding(.horizontal)
            }
        }
        .animation(.spring(), value: downloadManager.isDownloading)
    }
}
