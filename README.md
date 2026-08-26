# ARTOFFICE広報動画作成ソフト

バンドサークルで撮影した複数のライブ動画を，トリミング，バンド名表示，クロスフェード，結合，YouTubeチャプター作成まで一括で行うWindows向けデスクトップアプリです。初期版は`0.1.0`です。

## 主な機能

- `出演順_バンド名.MP4`を解析し，数値順に読み込みます。最初の半角アンダースコアだけを区切りとして扱うため，バンド名内のアンダースコアは保持します。
- フレーム単位で各動画の開始・終了を調整し，元動画を変更せず絶対パスで参照します。
- 隣接する映像と音声を0.5秒クロスフェードします。
- 各バンドの登場時に，Noto Sans JP Blackの白文字を左下へ0.5秒フェードイン，4秒表示，0.5秒フェードアウトします。
- 1080p／1440p，59.94fps，H.264 High，AAC-LC 48kHzステレオで書き出します。
- YouTube概要欄用チャプターを`H:MM:SS バンド名`のUTF-8・CRLFテキストで生成します。
- JPG，PNG，HEIC，HEIFの集合写真を16:9へ切り抜き，1920×1080・JPEG品質92で保存します。
- 編集内容をバージョン付きJSONの`.aovproj`へ手動保存できます。

## 利用方法

配布ZIPを任意のフォルダーへ展開し，`ARTOFFICE-video-maker.exe`を起動してください。詳しい操作は[使い方](docs/USER_GUIDE_JA.md)を参照してください。ZIP内では実行ファイルと`tools`，`resources`フォルダーの位置関係を変更しないでください。

コード署名を行っていないため，初回起動時にWindows SmartScreenの警告が出る場合があります。配布元とZIPのSHA-256を確認してから，「詳細情報」→「実行」を選択してください。WebView2がない場合は，[Microsoft WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)を導入してください。

## 開発

必要環境はNode.js 24，Rust stable，Windows 10/11 64bit，Python，7-Zipです。

```powershell
npm ci
python -m pip install fonttools==4.63.0
powershell -ExecutionPolicy Bypass -File scripts/fetch-tools.ps1
npm run check
npm run tauri -- build --no-bundle
```

ポータブルZIPは次で`artifacts`へ作成します。

```powershell
npm run package:portable
```

同梱バイナリの版，取得URL，SHA-256は[tools.lock.json](tools.lock.json)で固定しています。4.9GBの実写素材はGitへ追加せず，ローカル受入試験だけに使用します。

## 対象外

複数カメラ編集，1バンドの複数ファイル結合，自動トリミング，音量正規化，色補正，字幕，サムネイルへの文字入れ，YouTubeへの直接アップロード，macOS対応，自動保存，レンダー再開，自動更新は初期版の対象外です。

第三者ソフトウェアの条件は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を参照してください。
