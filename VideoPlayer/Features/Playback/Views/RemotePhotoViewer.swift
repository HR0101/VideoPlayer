import SwiftUI
import MediaServerKit
import UIKit
import Photos

struct RemotePhotoViewer: View {
    let photos: [RemoteVideoInfo]
    @State private var currentIndex: Int
    let serverAddress: String
    @Binding var isPresented: Bool
    var downloadManager: DownloadManager?
    @EnvironmentObject var appSettings: AppSettings

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showUI: Bool = true

    private var isLeftTapNext: Bool {
        appSettings.photoTapNavigationMode == 1
    }

    init(photos: [RemoteVideoInfo], initialIndex: Int, serverAddress: String, isPresented: Binding<Bool>, downloadManager: DownloadManager?) {
        self.photos = photos
        self._currentIndex = State(initialValue: initialIndex)
        self.serverAddress = serverAddress
        self._isPresented = isPresented
        self.downloadManager = downloadManager
    }

    var body: some View {
        let currentPhoto = photos[currentIndex]
        let originalURL = ServerAuth.mediaURL(address: serverAddress, path: "/video/\(currentPhoto.id)") ?? URL(string: "\(serverAddress)/video/\(currentPhoto.id)")!
        let displayURL = ServerAuth.mediaURL(
            address: serverAddress,
            path: "/thumbnail/\(currentPhoto.id)",
            query: [
                URLQueryItem(name: "original", value: "true"),
                URLQueryItem(name: "max", value: "2400")
            ]
        ) ?? originalURL

        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            GeometryReader { geo in
                AsyncImage(url: displayURL) { phase in
                    switch phase {
                    case .empty: ProgressView().tint(.white)
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(offset)
                    case .failure:
                        AsyncImage(url: originalURL) { fallbackPhase in
                            switch fallbackPhase {
                            case .empty:
                                ProgressView().tint(.white)
                            case .success(let image):
                                image.resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .scaleEffect(scale)
                                    .offset(offset)
                            case .failure:
                                Text("画像の読み込みに失敗しました").foregroundColor(.white)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    @unknown default: EmptyView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(MagnificationGesture()
                    .onChanged { val in
                        let delta = val / lastScale
                        lastScale = val
                        scale *= delta
                    }
                    .onEnded { _ in
                        lastScale = 1.0
                        if scale < 1.0 {
                            withAnimation { scale = 1.0 }
                        }
                    }
                )
                .simultaneousGesture(DragGesture()
                    .onChanged { val in
                        handlePhotoDragChanged(val)
                    }
                    .onEnded { val in
                        handlePhotoDragEnded(val)
                    }
                )
                .onTapGesture { location in
                    handlePhotoTap(location: location, width: geo.size.width)
                }
                .contextMenu {
                    Button {
                        downloadManager?.startDownload(url: originalURL, filename: currentPhoto.filename, isPhoto: true)
                    } label: {
                        Label("写真アプリに保存", systemImage: "square.and.arrow.down")
                    }
                }
            }

            HStack {
                if canNavigateFromLeft {
                    Button(action: { changePhoto(offset: leftNavigationOffset) }) {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                            .padding(.leading, 12)
                    }.buttonStyle(PlainButtonStyle())
                }
                Spacer()
                if canNavigateFromRight {
                    Button(action: { changePhoto(offset: rightNavigationOffset) }) {
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.bold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                            .padding(.trailing, 12)
                    }.buttonStyle(PlainButtonStyle())
                }
            }
            .opacity(scale > 1 || !showUI ? 0 : 1)

            // 上部バー: 閉じる / ページカウンタ / 保存
            VStack {
                HStack {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()

                    if photos.count > 1 {
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button(action: {
                        appSettings.photoTapNavigationMode = isLeftTapNext ? 0 : 1
                        Haptics.light()
                    }) {
                        Text(isLeftTapNext ? "左で次へ" : "右で次へ")
                            .font(.caption.weight(.bold))
                            .foregroundColor(isLeftTapNext ? Color.appGold : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        downloadManager?.startDownload(url: originalURL, filename: currentPhoto.filename, isPhoto: true)
                        Haptics.light()
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
            .opacity(scale > 1 || !showUI ? 0 : 1)

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

    private var leftNavigationOffset: Int {
        isLeftTapNext ? 1 : -1
    }

    private var rightNavigationOffset: Int {
        isLeftTapNext ? -1 : 1
    }

    private var canNavigateFromLeft: Bool {
        canChangePhoto(offset: leftNavigationOffset)
    }

    private var canNavigateFromRight: Bool {
        canChangePhoto(offset: rightNavigationOffset)
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

    private func canChangePhoto(offset: Int) -> Bool {
        photos.indices.contains(currentIndex + offset)
    }

    private func handlePhotoTap(location: CGPoint, width: CGFloat) {
        guard scale <= 1.0 else { return }

        if location.x < width * 0.3 {
            changePhoto(offset: leftNavigationOffset)
        } else if location.x > width * 0.7 {
            changePhoto(offset: rightNavigationOffset)
        } else {
            withAnimation { showUI.toggle() }
        }
    }

    private func handlePhotoDragChanged(_ value: DragGesture.Value) {
        if scale > 1 {
            offset = CGSize(
                width: lastOffset.width + value.translation.width,
                height: lastOffset.height + value.translation.height
            )
        } else {
            offset = value.translation
        }
    }

    private func handlePhotoDragEnded(_ value: DragGesture.Value) {
        if scale > 1 {
            lastOffset = offset
            return
        }

        if abs(value.translation.height) > 100 && abs(value.translation.height) > abs(value.translation.width) {
            isPresented = false
        } else if abs(value.translation.width) > 50 {
            let isNextSwipe = isLeftTapNext ? (value.translation.width > 0) : (value.translation.width < 0)
            changePhoto(offset: isNextSwipe ? 1 : -1)
            withAnimation { offset = .zero }
        } else {
            withAnimation { offset = .zero }
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
