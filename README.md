# VideoPlayer（iOS クライアント）

Mac の「個人用メディアサーバー」（[AllServerForMac](../AllServerForMac)）に同一 Wi‑Fi 上の iPhone から接続し、動画・写真を閲覧・再生する SwiftUI 製 iOS アプリです。サーバーは **Bonjour で自動検出**するので、IP アドレスの手入力は不要です。あわせて、端末内に取り込んだ動画を管理・再生する**ローカルライブラリ**機能も備えています。

> ペアになるサーバー: macOS アプリ **AllServerForMac**（先に起動しておく必要があります）

---

## 主な機能

### サーバー接続（リモート）
- **Bonjour 自動検出**（`_myvideoserver._tcp.`）で LAN 内の Mac サーバーを自動的に一覧表示
- **PIN 認証**：サーバーが PIN を要求する場合、6 桁 PIN を入力（ヘッダ `X-Auth-PIN` / Cookie `pin` / クエリ `pin` の経路に対応）。PIN はキーチェーン/設定に保持
- **アルバム / 動画 / 写真の閲覧**（`ALL VIDEOS` / `ALL PHOTOS` 仮想アルバムを含む）
- **サムネイル表示**（サーバー生成のサムネイルを取得）
- **1080p オンデマンド画質**：再生メニューで「1080p（軽量・変換）」を選ぶと、サーバー側でその場で低画質プロキシを生成。「変換中…」表示で完了を待ってから再生し、視聴終了時に自動でクリーンアップ（DELETE）
- **サーバー停止**：クライアントから Mac サーバーアプリを完全終了（`POST /server/shutdown`）

### 再生
- ネイティブ AVKit プレイヤーによる動画再生
- **連続再生 / シャッフル / リピート / スライドショー**
- 写真のスライドショー表示

### ローカルライブラリ
- **取り込み**：写真ライブラリ（PhotosPicker）/ ファイル（DocumentPicker）から動画を追加
- **ダウンロード管理**（DownloadManager）
- **サムネイル自動生成**（ThumbnailGenerator）
- 端末内での閲覧・再生

---

## 動作環境

- iOS 18.1 / 18.5 以降
- Mac サーバー（AllServerForMac）と **同じ Wi‑Fi** に接続していること
- リモート機能を使うには **AllServerForMac を先に起動**しておくこと

---

## ビルドと起動

1. `VideoPlayer.xcodeproj`（または `.xcworkspace`）を Xcode で開く
2. 実機の iPhone を選択して実行（▶）
3. Mac 側で AllServerForMac を起動しておくと、アプリ起動後にサーバーが自動的に一覧へ表示されます
4. サーバーが PIN を要求する場合は、Mac の画面に表示されている 6 桁 PIN を入力します

> 同一 Wi‑Fi 上にいるのにサーバーが出ない場合は、Mac 側のサーバーが起動しているか、ファイアウォール/ローカルネットワーク権限を確認してください。

---

## アーキテクチャ

画面単位のMVVMを基本とし，機能ごとに`Models`，`Views`，`ViewModels`，`Services`を配置しています．アプリ全体の画面遷移と依存オブジェクトの生成は`App`に集約し，共通デザインと拡張は`Common`から利用します．

```text
VideoPlayer/
├── App/
│   ├── Models/                  # アプリ全体のナビゲーション状態
│   ├── Views/                   # ルートタブ
│   └── VideoPlayerApp.swift     # エントリーポイントと依存注入
├── Common/
│   ├── DesignSystem/            # 色，余白，背景などのUI基盤
│   └── Extensions/              # 複数機能から使うSwift拡張
└── Features/
    ├── LibraryHub/              # ホーム，ショート，アルバム入口
    ├── LocalLibrary/            # 端末内メディアの管理と取り込み
    ├── RemoteLibrary/           # サーバー上のアルバムとメディア一覧
    ├── ServerConnection/        # Bonjour検出，PIN認証，API通信
    ├── Playback/                # 動画，写真，ショートの再生
    └── Settings/                # アプリ設定
```

主な状態管理クラスは次のとおりです．

| ViewModel | 責務 |
|---|---|
| `LocalLibraryViewModel` | ローカルアルバムと動画ファイルの管理 |
| `RemoteVideoListViewModel` | リモートメディアの取得，検索，並び替え，更新 |
| `ServerConnectionViewModel` | 接続中サーバーとアルバム一覧の状態管理 |
| `PlayerViewModel` | `AVPlayer`の再生状態，シーク，動画切替 |
| `RemoteShortsViewModel` | ショート動画の順序，再生区間，進行状況 |
| `RemoteShortsFavoritesViewModel` | お気に入りショートのクリップ再生 |

---

## セキュリティ / 注意点

- **ローカル LAN 専用**を想定しています（サーバーとの通信は平文 HTTP）。インターネット越しの利用は想定していません。
- PIN はサーバー側で表示・再生成されます。クライアントは入力された PIN を保持し、リクエストに付与します。
- リモート機能はサーバー（AllServerForMac）が起動していることが前提です。
- 初回はローカルネットワークアクセスの許可を求められる場合があります（Bonjour 検出に必要）。

---

## 更新履歴

### 2026-07-06 データ保護・堅牢化アップデート（サーバー側と同時対応）

- 「すべての動画/画像」での削除ダイアログを刷新: 「ゴミ箱に入れる（サーバーのゴミ箱へ移動・復元可）」と「完全に削除」を明確に区別（サーバー側の挙動変更に対応）
- サーバーの PIN が変更・無効化された（401 を検知した）タイミングで HTTP キャッシュを全消去し、締め出された後もサムネイルだけ表示され続ける問題を修正
- アップロード前にサーバーの上限（`/server/status` の `maxUploadBytes`）とファイルサイズを照合し、超過分は送信しない（サーバー側のメモリ枯渇防止）
- エラー時の再試行ボタン追加（アルバム一覧・動画一覧・サーバー検索）、エラーバナーが成功後も残り続けるバグの修正
- タブ切替時の全件再取得を60秒キャッシュ化（引っ張って更新・メディア追加/削除で即時無効化）、アルバム表紙のための全件JSON取得を撤廃、`URLCache` 拡大によるサムネイル再取得の削減

---

## ライセンス / クレジット

個人プロジェクト。サーバー側は [AllServerForMac](../AllServerForMac)（[Swifter](https://github.com/httpswift/swifter) ベース）を使用します。
