# Azure Pipelinesでの追加検証

更新日：2026年10月28日。

CLIの本人認証は完了したが，この組織ではEntraトークンでのAPIアクセスが拒否された。ユーザーからBuildの読取り・実行用PATの作成・DPAPI保存・使用を明示承認され，さらに無期限希望を受けて，実画面で設定できた最長の2027年10月27日までにした。対象は`yuto200596`だけ，スコープはBuild（Read & execute）だけとし，`.secrets/azure-devops-pat.clixml`へWindows DPAPIで保護した。PATの値は会話・Gitへ含めていない。PowerShell保存画面の文字コードを修正後，APIでRun 6の失敗ログを取得できた。

今後の通常操作は`scripts/ios/azure-build.ps1`を使う。`start`はパイプライン1・`codex/ios-native`・明示した完全SHAだけを指定し，受付後のソースを照合する。`status`，`failed-log`，`download`で確認と取得を行う。API認証は暗号化PATからプロセス内で組み立て，値を引数や通常ログへ表示しない。IPA取得は成功済みビルドに限定する。Run 6はCore29件中1件の試験期待値が誤っていた。56.73fpsに最も近い対応値は59.94fpsなので，期待値を修正して再検証する。

28日追記：Chromeの利用を最小限にするユーザー指示を受け，ブラウザー操作を停止した。プロジェクト内の`.cache/azure-cli/`へ公式Azure CLI 2.91.0を用意し，`az rest`でAzure DevOpsを直接操作する経路へ移行中である。認証キャッシュもGit除外済みの`.cache/azure-config/`へ分離する。初回の本人認証を依頼しており，この時点ではAPIログイン済みとは扱わない。`az rest --resource 499b84ac-1321-427f-aa17-267ca6975798`で認証ヘッダーをCLIに任せ，値を会話・引数・通常ログへ出さない。通常のCI状態確認は既存GitHub Checks APIで継続する。

Run 5は新しい実機指摘を含む版へ切り替えるため中止した。続く`8978360`のRun 6は失敗し，GitHubの注釈で終了コード1を確認したが，詳細原因はまだ取得できていない。アイコンとピンク配色まで含む最新版は`e8b5573`・1.1（ビルド4）で，未ビルド・未導入である。以下の実行中・CLI未導入の記述は，この追記前の記録として読む。

`windows-ios-development`スキルの再読込みを受け，無料枠のあるAzure Pipelinesを追加の検証先として準備した。ソースはGitHubの`Yuto-0906/ARTOFFICE-video-maker`・`codex/ios-native`を継続使用する。既存のCodemagic設定は残す。GitHub Actionsや有料ランナーを起動する変更ではない。

## 利用枠・接続・署名

Azure DevOps組織`yuto200596`・既存プロジェクト`ios-development`を使う。開始前の組織画面では，非公開プロジェクトのMicrosoft-hosted無料枠は1並列ジョブ・月1,800分，消費0分だった。課金設定は変更していない。

ユーザーからARTOFFICEだけの連携とGitHub Appの具体的な権限について承認を得て，既存の別リポジトリの許可を変えずに今回のリポジトリを追加した。パイプラインID1は`Yuto-0906.ARTOFFICE-video-maker`である。接続時と署名情報送信時の自動承認レビューの拒否は，それぞれ対象を具体化した明示承認を得てから解消した。

ユーザーが許可した既存P12・プロファイル・復号パスワードを下記のSecure filesへ登録し，それぞれのYAML利用権をパイプライン1だけへ設定した。「全パイプラインを許可」は使っていない。Azureの画面ではClassicパイプラインの扱いが別に表示されるため，ここで限定・確認した対象はYAML利用権である。送信用一時ファイル3件は削除し，元のP12・DPAPI保護したパスワード・プロファイルを維持した。

ローカルにAzure CLI・Azure DevOps用PATは確認できていない。通常の状態確認は既存GitHub CLIのChecks APIを使う。Azure独自の起動・詳細ログ・成果物取得はAPI認証がないため，ブラウザーで補っている。ブラウザーのサインイン状態をCLI認証済みとは扱わない。

## 実行結果

| 実行 | 対象・処理 | 結果 |
|---|---|---|
| [Run 1](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=1) | `c36b3f8`・all | 全体はUIで失敗。両ジョブでCore25件とアプリ・試験コンパイルが成功し，各シミュレーターでネイティブ15件も全件成功した |
| Run 2・Run 3 | 途中のUI修正 | 最新修正を含めるため中止。成功した試験とは数えない |
| [Run 4](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=4) | `fe8dfd3`・device | 4分23秒で署名成功。IPA・署名レポートを取得し，Windowsで照合後，M4 iPadへ1.1（ビルド2）を導入した |
| [Run 5](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=5) | `fe8dfd3`・ui | 実行中。iPhone系・iPad系のUIだけを再検証する |

Run 1のiPhone系はiPhone16e・iOS26.2，iPad系はiPad Air 13-inch（M4）・iOS26.4であり，iPhone15・iPad Proの実機結果とは扱わない。ネイティブ15件の内訳はFolderVideoImport1件・MediaExport13件・RuntimePressure1件である。iPhone側は短い保存完了表示の確認，iPad側は名前を消した後の空欄確認で失敗した。保存完了表示の保持，消去時のフォーカス維持，試験側の空欄判定・待機の調整を最新ソースへ反映した。Run 1以後，Core・Media・Rendering・ネイティブ試験のソースに差分はない。

Run 4では既存Secure filesから一時キーチェーンへの取込み・Releaseビルド・署名検証・IPA生成が実際に成功した。リビジョンは`fe8dfd3f567d4cb40ae366e022797090c4ddbf4a`，`codesignVerified: true`，IPAのSHA-256は`ff8af5fffb1d991436104056e796b8506b2a507289f8f1625a9dd7a69567f1ae`だった。埋込みプロファイルは承認済み原本と一致し，対象iPadを含む。端末の読み戻しでも1.1・ビルド2・`ProfileValidated: true`を確認した。既存2プロジェクトの編集情報4ファイルも更新前後で一致した。新しいUIの操作確認は依頼中である。

## ソースに用意した構成

ルートの`azure-pipelines.yml`は`trigger: none`・`pr: none`とし，手動実行だけを定義する。`task`は`all`・`media`・`storage`・`ui`・`device`から選ぶ。通常の検証は署名情報なしで行い，iPhoneとiPadを別の60分ジョブへ分ける。1並列枠で順番に実行し，既存の`ci.sh`へ`ARTOFFICE_TEST_FAMILY`を渡す。Codemagicで未指定の場合は従来どおり両端末を実行する。

無料の標準プールにある`macOS-26`と，そのソフトウェア一覧で確認したXcode 26.6を明示した。現在Codemagicで使うXcode 27.1と同じ検証環境ではない。最低OS17以降のAPIを使うアプリのビルドと，提供されるiOSシミュレーターでの検証を行い，実際のSDK・シミュレーター機種・OSはCIログで記録する。現在OS27.2のM4 iPadでの受入は別に確認する。無料Intelランナーでも今回のネイティブ15件は両ジョブで通ったが，実機の速度・音声・タッチ操作の証明とは区別する。

`device`の場合だけ，登録済みの次の3種類のSecure filesを使う。パスワードも保護ファイルとして送り，実行時にAzureのSecret変数へ登録するため，ブラウザーの入力欄や会話へ値を表示する必要がない。

| Azureの入力 | 内容 |
|---|---|
| Secure file：`artoffice-development.p12` | 既存Apple Development証明書と対応する秘密鍵 |
| Secure file：`artoffice-app-development.mobileprovision` | 今回のBundle IDと登録済み2端末用の既存開発プロファイル |
| Secure file：`artoffice-p12-password.txt` | 既存P12の復号パスワード。実行時だけ`ARTOFFICE_DEVELOPMENT_P12_PASSWORD`としてSecret登録する |

`DownloadSecureFile`で取得したファイルを`scripts/ios/azure-sign.py`がプロセス内で既存の署名スクリプトへ渡す。パスワードは子プロセスの開始前に，Azureの`task.setvariable`・`issecret=true`の制御コマンドでマスク対象へ登録する。通常のログ・引数へ値を表示しない。この処理をローカルで実行しないようAzureエージェントかも検査する。既存の`scripts/ios/sign.py`が一度だけ一時キーチェーンを作り，プロファイル照合，実機用ビルド，署名検証，IPA化，後始末を行う。証明書・プロファイルを再発行せず，既存の署名材料を再利用する。

Secure filesの利用権は今回のパイプラインへ限定する。検証用のジョブへ署名情報を渡さない。公開する成果物はIPAと必要な診断・試験結果に絞り，作業領域全体やSecure filesを成果物へ含めない。送信専用のローカル一時ファイルは登録後に削除し，元のP12とDPAPI保護したパスワードを維持する。

## 次の操作

1. Run 5のUI試験をGitHub Checks APIで追跡し，失敗時だけ詳細ログから原因を調べる。
2. 導入済みM4 iPadでフォルダー取込み，音声付き再生，名前・順番，保存再開，写真の操作，容量整理を確認する。iPhone実機は後日対応とする。
3. Azure独自のAPI認証が整った場合は，起動・ログ・成果物取得もCLI・APIへ移す。

Windowsでは差分書式，YAML・Python署名アダプターの構文，`bash -n scripts/ios/ci.sh`を確認済みである。署名経路はRun 4で実行確認済み，UI試験と実機受入は上記の範囲を残す。

## 確認した公式資料

- [Microsoft-hosted agents](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/hosted?view=azure-devops)：標準プールのmacOSイメージ。
- [Configure and pay for parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs?view=azure-devops)：無料枠の条件。今回の利用権は実際の組織画面でも確認した。
- [macOS 26のソフトウェア一覧](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)：Xcode 26.6のパスとSDK。実ジョブのイメージ更新により変わるため，CIログも記録する。
- [Azure Pipelinesの制御コマンド](https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands?view=azure-devops)：エージェントによるSecret変数の登録とログのマスク。
