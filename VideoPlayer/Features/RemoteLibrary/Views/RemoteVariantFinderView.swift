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
    @EnvironmentObject private var remoteControlViewModel: RemoteControlViewModel
    @EnvironmentObject private var navState: AppNavigationState

    /// 重ねた差分をどこで走らせるか。
    ///
    /// この iPhone で再生する場合は、本数ぶんの映像を無線越しに受け取って同時に展開するので
    /// 4 本が限度。Mac へ飛ばす場合は映像を受け取らず「どれを見せるか」を送るだけなので、
    /// Mac 側のデコードの上限（9 本）まで並べられる。
    enum VariantDestination: String, CaseIterable, Identifiable {
        case thisPhone
        case mac

        var id: String { rawValue }

        var label: String {
            switch self {
            case .thisPhone: return "この iPhone"
            case .mac: return "Mac"
            }
        }

        var maxVariants: Int {
            switch self {
            case .thisPhone: return RemoteVariantPlayerViewModel.maxVariants
            case .mac: return VariantDestination.macMaxVariants
            }
        }

        /// Mac の `PlaybackCoordinator.playVariantSwitch` が受け付ける上限と同じ。
        static let macMaxVariants = 9
    }

    @State private var destination: VariantDestination = .thisPhone
    @State private var isSendingToMac = false
    @State private var result: RemoteVariantScanResult?
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    /// グループごとに選んでいる差分。
    @State private var selection: [String: Set<String>] = [:]
    /// 再生中の差分。この画面を閉じずに上へ重ねる（閉じるとスクロール位置を失う）。
    @State private var playing: [RemoteVideoInfo]?

    /// 尋ね直す間隔。フレームの展開は1本あたり数秒かかるので、細かく叩いても意味がない。
    private static let pollInterval: Double = 1.2

    private var maxVariants: Int { destination.maxVariants }

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
                destinationSection
                if !result.isReady {
                    scanningRow(result)
                }
                ForEach(result.groups) { group in
                    groupSection(group)
                }
                Section {
                    Text(destinationFootnote)
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

    private var destinationSection: some View {
        Section {
            Picker("どこで再生するか", selection: $destination) {
                ForEach(VariantDestination.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("どこで再生するか")
        }
        // iPhone へ戻したときに上限を超えた選択が残っていると、押せないボタンだけが残る。
        .onChange(of: destination) { _, _ in trimSelectionsToLimit() }
    }

    private var destinationFootnote: String {
        switch destination {
        case .thisPhone:
            return "同時に再生できるのは \(maxVariants) 本までです。無線越しに本数ぶんの映像を同時に受け取って展開するため、Mac（最大 \(VariantDestination.macMaxVariants) 本）ほどは並べられません。"
        case .mac:
            return "Mac の画面で再生し、見せる1本の切り替えはリモコンタブから行います。映像はこの iPhone に届かないので、Mac 側の上限 \(maxVariants) 本まで並べられます。"
        }
    }

    /// 選んだ差分を Mac へ渡し、リモコンタブへ移る。
    private func sendToMac(_ items: [RemoteVideoInfo]) {
        guard items.count >= 2 else { return }
        isSendingToMac = true
        Task {
            let didOpen = await remoteControlViewModel.openVariantOnMac(
                videoIDs: items.map(\.id),
                serverAddress: serverAddress
            )
            isSendingToMac = false
            guard didOpen else { return }
            Haptics.medium()
            navState.selectedTab = 3
            dismiss()
        }
    }

    /// 行き先を変えて上限が下がったとき、はみ出したぶんを落とす。
    private func trimSelectionsToLimit() {
        guard let groups = result?.groups else { return }
        for group in groups {
            let picked = selection[group.id] ?? defaultSelection(for: group)
            guard picked.count > maxVariants else { continue }
            // 落とす順は group の並び基準。ID の集合順に頼るとその都度変わる。
            selection[group.id] = Set(
                group.videoIDs.filter { picked.contains($0) }.prefix(maxVariants)
            )
        }
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
                switch destination {
                case .thisPhone:
                    withAnimation(.easeOut(duration: 0.18)) { playing = chosen }
                case .mac:
                    sendToMac(chosen)
                }
            } label: {
                HStack {
                    Label(
                        destination == .mac
                            ? "Macで切り替え再生（\(picked.count)本）"
                            : "切り替え再生（\(picked.count)本）",
                        systemImage: destination == .mac
                            ? "display.and.arrow.down"
                            : "rectangle.on.rectangle.angled"
                    )
                    if isSendingToMac {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!(2...maxVariants).contains(picked.count) || isSendingToMac)
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
        let atLimit = picked.count >= maxVariants
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
        Set(group.videoIDs.prefix(maxVariants))
    }

    private func toggle(_ id: String, in groupID: String) {
        guard let group = result?.groups.first(where: { $0.id == groupID }) else { return }
        var picked = selection[groupID] ?? defaultSelection(for: group)
        if picked.contains(id) {
            picked.remove(id)
        } else {
            guard picked.count < maxVariants else { return }
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
