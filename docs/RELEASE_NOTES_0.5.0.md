# ARTOFFICE広報動画作成ソフト v0.5.0

ライブ動画の読み込みから書き出しまでの画面と操作を見直した。

## 変更点

- カット画面に新しい時間軸を追加した。両端のつまみで残す範囲を調整できる。再生，フレーム移動，開始・終了位置の指定はキーボードでも操作できる。
- 「元に戻す」「やり直す」を追加した。
- 一度プロジェクトを保存すると，その後の変更を自動で上書き保存する。
- 書き出し先は，初期状態では一覧の1本目の動画と同じフォルダーになる。変更した保存先はプロジェクトに記憶する。
- 書き出し完了後の「フォルダーで表示」から，完成ファイルを確認できる。
- YouTube用チャプターに「コピー」ボタンを追加した。
- フォルダーを画面へドロップし，中の動画をまとめて追加できる。
- 動画のファイル名は自由に付けられる。先頭に番号がある場合は出演順として使う。番号がない動画も読み込める。
- 「前の動画の続き」のチェックで，1バンドの演奏が分かれた動画を指定できる。続きの部分はクロスフェードなしでつながり，バンド名とチャプターは1本目だけに入る。
- 画面の見た目を簡素にし，アプリのアイコンを円形のロゴに変更した。
- READMEに番号付きの画面図を追加し，使い方を整理した。

## ダウンロード

Releaseの「Assets」から，自分のパソコンに合うファイルを選ぶ。

| パソコン | ファイル |
|---|---|
| Windows 10・11の64ビット版 | `ARTOFFICE-video-maker-v0.5.0-windows-x64.zip` |
| macOS 15以降，Apple Silicon（Mシリーズ） | `ARTOFFICE-video-maker-v0.5.0-macos-arm64.dmg` |
| macOS 15以降，Intel | `ARTOFFICE-video-maker-v0.5.0-macos-x64.dmg` |

WindowsはZIPを「すべて展開」し，フォルダー内の`ARTOFFICE-video-maker.exe`を起動する。MacはDMG（ディスクイメージ）を開き，アプリをApplicationsへコピーする。必要なフォントと動画処理用ツールは同梱されている。

Mac版は引き続き試験版。署名・公証済みだが，実機での画面操作，動画プレビュー，高速化は未確認。[実機確認表](https://github.com/Yuto-0906/ARTOFFICE-video-maker/blob/codex/ios-native/docs/MAC_TEST_CHECKLIST.md)を参照する。

`macos-sources.tar.gz`はMac版のソース配布用。各配布ファイルにはSHA-256（Secure Hash Algorithm 256-bit）のチェックサムが付き，Mac版には署名・公証などの検証結果`macos-*-verification.json`も付く。

## プロジェクトの互換性

v0.1.0～v0.4.0で保存した`.aovproj`は，これまでどおり開ける。v0.5.0で保存したプロジェクトもv0.4.0で開ける。

操作手順は[README](https://github.com/Yuto-0906/ARTOFFICE-video-maker/blob/codex/ios-native/README.md)にまとめている。
