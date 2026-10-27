# Windowsからの実機導入・再導入

この手順は，macOS CIで署名ビルドが成功してIPAを取得した後に使う。実行結果は[IOS_PROGRESS.md](IOS_PROGRESS.md)，導入後の確認は[IOS_DEVICE_ACCEPTANCE.md](IOS_DEVICE_ACCEPTANCE.md)に記録する。

2026年10月28日00:59 JST，M4 iPad（`iPad16,5`・OS27.2）へ1.1（ビルド2）を上書きした。現在の導入元は[Azure Run 4](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=4)，ソース`fe8dfd3f567d4cb40ae366e022797090c4ddbf4a`，IPAは`.cache/ios-signed/azure-build-4/ios-signed/ARTOFFICE-ios-development.ipa`である。macOSでの署名検証，Windowsでの構成・リビジョン・プロファイル照合，端末の`ProfileValidated: true`と編集JSON4ファイルの更新前後の一致を確認した。新しい操作の実機受入は依頼中で，iPhoneの導入は後日対応とする。

## ビルドとIPAを対応させる

成功した署名ジョブの対象コミット，`ARTOFFICE-ios-development.ipa`，`signing-report.json`を照合する。Azureでは`device`ジョブの`ios-signed`成果物，Codemagicでは`ios-device`の成果物を使う。レポートの`codesignVerified`，Bundle ID，バージョン，リビジョンを確認し，同じビルドのIPAを取得する。ダウンロード先はGit除外済みの`.cache/ios-signed/`などを使う。

アプリのBundle IDは`com.yuto0906.artoffice-video-maker.ios`である。Windows側でも次の構成検査を実行し，SHA-256を記録する。

```powershell
python scripts/ios/check-ipa.py `
  --ipa '.cache/ios-signed/azure-build-4/ios-signed/ARTOFFICE-ios-development.ipa' `
  --bundle 'com.yuto0906.artoffice-video-maker.ios'
```

今回のSHA-256は`ff8af5fffb1d991436104056e796b8506b2a507289f8f1625a9dd7a69567f1ae`である。この検査は実機用プラットフォーム，識別子，実行ファイル，署名関連ファイル，プロファイルなどの構成を調べる。暗号学的な署名検証はmacOSの`codesign`と，インストール時の端末検証で確認する。埋込みプロファイルも承認済み原本と照合し，対象端末を含むことを確認する。

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

今回の既存Apple Development証明書の期限は2027年10月16日03:53 UTC，ARTOFFICE用プロファイルの期限は2027年10月26日13:51:55 UTCである。署名・起動に使える期間は両方の有効性に依存する。更新後はアプリ識別子，端末，証明書を再照合して利用可能なmacOS CIで再署名し，対象コミットと新しいIPAを対応させて導入する。

Azureではパイプライン1用Secure filesへ承認済みの3種類を登録した。YAML利用権を当該パイプラインへ限定し，値をGitや通常ログへ含めない。構成は[IOS_AZURE_PIPELINES.md](IOS_AZURE_PIPELINES.md)を参照する。既存の署名情報は承認済みのCodemagicアプリ`ARTOFFICE-video-maker`内の`artoffice_ios_signing`グループで管理する。P12，復号パスワード，プロファイルの値はGitへ含めない。
