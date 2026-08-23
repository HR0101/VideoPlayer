import MediaServerKit
import SwiftUI

// MARK: - 差分動画を探して切り替え再生へ渡す（iPhone）
//
// 検出そのものは Mac が行う（実ファイルを持っているのは向こうだけなので）。
// この画面は結果を受け取って並べ、選んだぶんを重ねて再生するだけ。
//
// 指紋づくりに時間がかかるぶん、サーバーは「いまわかっていること＋進み具合」を返してくる。
// `ready` になるまで少し間を空けて尋ね直し、その間も見つかったグループから触れるようにする。

struct RemoteVariantFinderView: View {
    let serverAddress: String
    let albumID: String
    /// アルバムの動画。サーバーから返るのは ID だけなので、ここで名前と尺に引き当てる。
    let videos: [RemoteVideoInfo]

    @Environment(\.dismiss) private var dismiss
    @State private var result: RemoteVariantScanResult?
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    /// グループごとに選んでいる差分。
    @State private var selection: [String: Set<String>] = [:]
    /// 再生中の差分。この画面を閉じずに上へ重ねる（閉じるとスクロール位置を失う）。
    @State private var playing: [RemoteVideoInfo]?

    /// 尋ね直す間隔。フレームの展開は1本あたり数秒かかるので、細かく叩いても意味がない。
    private static let pollInterval: Double = 1.2

    private var videosByID: [String: RemoteVideoInfo] {
        Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
    }

    var body: some View {
        ZStack {
            NavigationStack {
                content
                    .background(Color.appDarkBackground.ignoresSafeArea())
                    .navigationTitle("差分動画を探す")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { dismiss() }
                        }
                    }
            }
            if let playing {
                RemoteVariantPlayerView(
                    videos: playing,
                    serverAddress: serverAddress,
                    onClose: { self.playing = nil }
                )
                .transition(.opacity)
            }
        }
        .task { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView(
                "探せませんでした",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if let result, !result.groups.isEmpty {
            List {
                if !result.isReady {
                    scanningRow(result)
                }
                ForEach(result.groups) { group in
                    groupSection(group)
                }
                Section {
                    Text("同時に再生できるのは \(RemoteVariantPlayerViewModel.maxVariants) 本までです。無線越しに本数ぶんの映像を同時に受け取って展開するため、Mac（最大9本）ほどは並べられません。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else if let result, !result.isReady {
            scanningPlaceholder(result)
        } else if result != nil {
            ContentUnavailableView(
                "差分動画は見つかりませんでした",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("尺がほぼ同じで、絵だけが違う動画が対象です。")
            )
        } else {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scanningRow(_ result: RemoteVariantScanResult) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Mac が照合中… \(result.scanned) / \(result.total)　見つかったぶんは先に選べます")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func scanningPlaceholder(_ result: RemoteVariantScanResult) -> some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(result.scanned),
                total: Double(max(result.total, 1))
            )
            .progressViewStyle(.linear)
            .frame(width: 220)
            Text("Mac が照合中… \(result.scanned) / \(result.total)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("初回はフレームの取り出しに時間がかかります。一度調べた結果は Mac 側に残るので、次からは待たされません。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func groupSection(_ group: RemoteVariantGroup) -> some View {
        let items = group.videoIDs.compactMap { videosByID[$0] }
        let picked = selection[group.id] ?? defaultSelection(for: group)
        Section {
            ForEach(items) { item in
                variantRow(item, groupID: group.id, picked: picked)
            }
            Button {
                let chosen = items.filter { picked.contains($0.id) }
                withAnimation(.easeOut(duration: 0.18)) { playing = chosen }
            } label: {
                Label("切り替え再生（\(picked.count)本）", systemImage: "rectangle.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!(2...RemoteVariantPlayerViewModel.maxVariants).contains(picked.count))
        } header: {
            HStack {
                Text("\(items.count)本の差分 ・ \(formatDuration(group.duration))")
                Spacer()
                if let low = group.minFrameDistance, let high = group.maxFrameDistance {
                    Text(String(format: "絵の差 %.1f〜%.1f", low, high))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
    }

    private func variantRow(_ item: RemoteVideoInfo, groupID: String, picked: Set<String>) -> some View {
        let isPicked = picked.contains(item.id)
        let atLimit = picked.count >= RemoteVariantPlayerViewModel.maxVariants
        return Button {
            toggle(item.id, in: groupID)
        } label: {
            HStack(spacing: 12) {
                RemoteVideoThumbnailView(
                    thumbnailURL: ServerAuth.mediaURL(address: serverAddress, path: "/thumbnail/\(item.id)"),
                    duration: 0
                )
                .frame(width: 64, height: 64)

                Text(item.filename.cleanVideoTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isPicked ? .accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        // 上限に達したら、選んでいないものは押せなくする（押せるのに増えないと迷う）。
        .disabled(!isPicked && atLimit)
        .opacity(!isPicked && atLimit ? 0.4 : 1)
    }

    /// 既定は先頭から上限まで。全部入れてしまうと、そのままでは再生できない組ができる。
    private func defaultSelection(for group: RemoteVariantGroup) -> Set<String> {
        Set(group.videoIDs.prefix(RemoteVariantPlayerViewModel.maxVariants))
    }

    private func toggle(_ id: String, in groupID: String) {
        guard let group = result?.groups.first(where: { $0.id == groupID }) else { return }
        var picked = selection[groupID] ?? defaultSelection(for: group)
        if picked.contains(id) {
            picked.remove(id)
        } else {
            guard picked.count < RemoteVariantPlayerViewModel.maxVariants else { return }
            picked.insert(id)
        }
        selection[groupID] = picked
    }

    // MARK: - 問い合わせ

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let fetched = try await ServerAPI.fetchVariantScan(
                        serverAddress: serverAddress,
                        albumID: albumID
                    )
                    errorMessage = nil
                    result = fetched
                    if fetched.isReady { return }
                } catch {
                    // 一度失敗しても諦めない（サーバーが立ち上がり途中のこともある）。
                    // 何も出せていないときだけ知らせる。
                    if result == nil { errorMessage = error.localizedDescription }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
