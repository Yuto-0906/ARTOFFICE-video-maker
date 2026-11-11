# 形式対応・自動出力設定の配布記録

2026年11月11日。

## Windows

- 配布物：`artifacts/ARTOFFICE-video-maker-v0.4.0-source-match-windows-x64.zip`（96,936,738 bytes）。展開先の`ARTOFFICE-video-maker.exe`を起動する。
- ソース：`codex/ios-native`の`5a04813eb828863d4e2cab2ac6f9d98737daea28`。
- SHA-256：`3a301ac361737d4cb95f4d25cb3dbdb66ff2d804d815422920def24de3e22e2d`。隣の`.sha256`にも保存した。
- フロントエンドのビルドと21件，Rust 21件，Clippy，配布物の圧縮整合性と同梱ツールを確認した。
- 指定された長いMKVで冒頭と途中の表示，元動画の時刻，30秒区間をまたぐ再生，連続シーク後の最終位置を確認した。元動画は変更していない。
- 新規プロジェクトは解像度とフレームレートを先頭動画へ合わせる。古いプロジェクトでは，書き出し画面から各設定の「先頭の動画に合わせる」を選択できる。

## iOS／iPadOS

- 配布物：`artifacts/ARTOFFICE-video-maker-v1.1-build7-ios-development.ipa`（10,497,317 bytes）。登録済み端末向けの開発用署名である。
- アプリ：`com.yuto0906.artoffice-video-maker.ios`，バージョン1.1，ビルド7，iOS 17以降。
- 対象ソース：`7a955fc3d3ea526841788a8a73d7445bb1a14a69`。続くWindows修正コミットはiOSのファイルを変更していない。
- [Azure検証run 48](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=48)：Core 32件，実機向けコンパイル，iPhone・iPad各8件が成功した。元動画の幅・高さ・フレームレートで実際に書き出す試験も含む。
- [Azure署名run 49](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=49)：成功。macOSの`codesign`検証済み。Windowsでも構成検査，同梱8フレームワークの署名関連ファイル，埋め込みプロファイルと承認済み原本の一致を確認した。
- SHA-256：`8e61a212da9abf83c6f64c2c34ab29a435fc855bb503fa459127a6b48214726a`。
- プロファイル期限：2027-10-26 13:51:55 UTC。証明書期限：2027-10-16 03:53:00 UTC。これらの期限を過ぎた場合は，有効な署名情報で再ビルドする。
- 元の取得先：`.cache/ios-signed/azure-build-49/ios-signed/`。署名レポートとビルドログも同じ場所に保持した。成果物のコピー後も署名済み内容は変更していない。
- 導入状況：接続済みUSB端末なし。実機更新と実機での機能確認は未実施。

### Windowsからの再導入

今回の作業フォルダー内の`.cache/ios-device-tools/Scripts/python.exe`にPyMobileDevice3 11.32.0を準備し，コマンドの起動とUSB検出を確認した。接続・ロック解除後に対象端末を特定し，今回のプロファイルに含まれることを照合する。端末IDは公開記録に含めない。

```powershell
$devicePython = '.cache/ios-device-tools/Scripts/python.exe'
& $devicePython -m pymobiledevice3 usbmux list --usb
& $devicePython -m pymobiledevice3 apps install --udid $deviceUdid `
  'artifacts/ARTOFFICE-video-maker-v1.1-build7-ios-development.ipa'
& $devicePython -m pymobiledevice3 apps query --udid $deviceUdid `
  'com.yuto0906.artoffice-video-maker.ios'
```

`$deviceUdid`には照合した実端末の識別子を指定する。端末からBundle ID，バージョン，ビルド，`ProfileValidated`を読み戻す。保存済みイベントを保持した更新を行い，起動と依頼された機能を実機で確認する。
