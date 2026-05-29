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

## ソース構成

| ファイル | 役割 |
|---|---|
| `VideoPlayerApp.swift` | アプリのエントリーポイント |
| `ServerModels.swift` | サーバー検出（Bonjour `ServerBrowser`）・接続・PIN 認証・API 呼び出し |
| `AlbumListView.swift` | トップ画面（サーバー一覧 / ローカル / サーバー停止操作） |
| `RemoteAlbumListView.swift` | リモートサーバーのアルバム一覧 |
| `RemoteVideoListView.swift` | リモート動画/写真の一覧・再生・画質切替・スライドショー |
| `VideoGridView.swift` | ローカルライブラリのグリッド表示 |
| `VideoManager.swift` | ローカルライブラリ管理 |
| `Models.swift` | データモデル |
| `PlayerManager.swift` | AVPlayer 管理（再生制御・画質切替） |
| `CustomVideoPlayerContainer.swift` | プレイヤーのコンテナビュー |
| `PhotePicker.swift` | 写真ライブラリからの取り込み |
| `DocumentPicker.swift` | ファイルからの取り込み |
| `DownloadManager.swift` | ダウンロード管理 |
| `ThumbnailGenerator.swift` | サムネイル生成 |
| `LocalVideoThumbnailView.swift` | ローカル動画サムネイル表示 |
| `AppSettings.swift` | アプリ設定（PIN 保持など） |

---

## セキュリティ / 注意点

- **ローカル LAN 専用**を想定しています（サーバーとの通信は平文 HTTP）。インターネット越しの利用は想定していません。
- PIN はサーバー側で表示・再生成されます。クライアントは入力された PIN を保持し、リクエストに付与します。
- リモート機能はサーバー（AllServerForMac）が起動していることが前提です。
- 初回はローカルネットワークアクセスの許可を求められる場合があります（Bonjour 検出に必要）。

---

## ライセンス / クレジット

個人プロジェクト。サーバー側は [AllServerForMac](../AllServerForMac)（[Swifter](https://github.com/httpswift/swifter) ベース）を使用します。
