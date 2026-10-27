# Windowsからの実機導入・再導入

この手順は，Codemagicの署名ビルドが成功してIPAを取得できた後に使う。現時点の実行結果は[IOS_PROGRESS.md](IOS_PROGRESS.md)へ記録する。導入後の操作確認は[IOS_DEVICE_ACCEPTANCE.md](IOS_DEVICE_ACCEPTANCE.md)に沿って行う。

2026年10月27日，M4 iPad（27.0.1）で新規導入と上書き更新が成功した。現在導入しているのは[署名ビルド #2](https://codemagic.io/app/6adb7fa259debc2d2f15db9f/build/6ae007e94a72334e32e58ec5)，ソース`f3aa9a8`，IPAは`.cache/ios-signed/build-2/ARTOFFICE-ios-development.ipa`である。Core14件・macOSでの署名検証・Windowsでの構成検査が通り，端末の`ProfileValidated: true`と，更新前後の編集JSONの一致を確認した。iPhoneの導入はユーザー指示により後日対応とする。

## ビルドとIPAを対応させる

Codemagicの`ios-device`で成功したビルドを開き，コミット，`ARTOFFICE-ios-development.ipa`，`signing-report.json`を確認する。署名レポートの`codesignVerified`，Bundle ID，バージョン，リビジョンを照合して，同じビルドのIPAを取得する。ダウンロード先はGit除外済みの`.cache/ios-delivery/`などを使う。

アプリのBundle IDは`com.yuto0906.artoffice-video-maker.ios`である。Windows側でも次の構成検査を実行し，SHA-256を記録する。

```powershell
python scripts/ios/check-ipa.py `
  --ipa '.cache/ios-delivery/ARTOFFICE-ios-development.ipa' `
  --bundle 'com.yuto0906.artoffice-video-maker.ios'
```

この検査は，実機用プラットフォーム，アプリ識別子，実行ファイル，署名関連ファイル，プロファイルなどの構成を調べる。暗号学的な署名検証はCodemagic上の`codesign`と，インストール時の端末による検証で確認する。

## 接続ツールを用意する

今回のWindows上の読取りには，Python 3.12.14とPyMobileDevice3 11.32.0を使用した。正常に動作する既存環境は再利用できる。新しい環境が必要な場合は，利用可能なPython 3.12の実行ファイルを`$python312`へ指定し，作業フォルダー内へ環境を作る。

```powershell
& $python312 -m venv '.cache/ios-device-tools'
$devicePython = '.cache/ios-device-tools/Scripts/python.exe'
& $devicePython -m pip install 'pymobiledevice3==11.32.0'
```

配布元は[PyMobileDevice3の公式PyPI](https://pypi.org/project/pymobiledevice3/11.32.0/)，接続の説明は[公式Windows導入案内](https://doronz88.github.io/pymobiledevice3/installation/)を参照する。Apple接続サービスとUSBドライバーが既に動作している場合は，その構成を使う。

## 対象を選んで導入する

端末をUSBデータケーブルで接続し，ロックを解除する。信頼確認が表示された場合は本人が許可する。対象機種と端末IDをプロファイルに登録したものと照合する。

```powershell
$connectedDevices = & $devicePython -m pymobiledevice3 usbmux list --usb | ConvertFrom-Json
$targetKind = 'iPad' # iPhoneへ入れる場合は'iPhone'を指定する。
$matchingDevices = @($connectedDevices | Where-Object { $_.DeviceClass -eq $targetKind })
if ($matchingDevices.Count -ne 1) { throw '対象機種を1台に絞り，登録情報と照合してください。' }
$targetDeviceId = $matchingDevices[0].UniqueDeviceID

& $devicePython -m pymobiledevice3 apps install `
  --udid $targetDeviceId '.cache/ios-delivery/ARTOFFICE-ios-development.ipa'
if ($LASTEXITCODE -ne 0) { throw 'インストールに失敗しました。' }

& $devicePython -m pymobiledevice3 apps query `
  --udid $targetDeviceId 'com.yuto0906.artoffice-video-maker.ios' `
  > '.cache/ios-delivery/installed-app.json'
if ($LASTEXITCODE -ne 0) { throw '導入後の情報を読み戻せませんでした。' }
```

`installed-app.json`からBundle ID，バージョン，`ProfileValidated`，必要な権限を読み戻す。端末IDや接続情報の原本は`.cache/`内で扱う。プロファイルに含まれる端末であることも確認してから導入する。

再導入も，同じBundle IDの検証済みIPAを上書きインストールする手順とする。導入後は実際に起動し，既存プロジェクトの編集内容と素材を開き直せることを確認する。Developer Modeや開発者の信頼確認が必要な場合は，端末の画面に従って本人が操作する。今回接続したM4 iPadではDeveloper Modeが有効であることを読み戻した。

## 証明書・プロファイルの更新

今回の既存Apple Development証明書の期限は2027年10月16日03:53 UTC，ARTOFFICE用プロファイルの期限は2027年10月26日13:51:55 UTCである。署名・起動に使える期間は両方の有効性に依存する。更新後はアプリ識別子，端末，証明書を再照合してCodemagicで再署名し，対象コミットと新しいIPAを対応させて導入する。

署名情報は承認済みのCodemagicアプリ`ARTOFFICE-video-maker`内の`artoffice_ios_signing`グループで管理する。P12，復号パスワード，プロファイルの値はGitへ含めない。
