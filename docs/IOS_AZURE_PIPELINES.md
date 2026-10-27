# Azure Pipelinesでの追加検証

更新日：2026年10月27日。

`windows-ios-development`スキルの再読込みを受け，無料枠のあるAzure Pipelinesを追加の検証先として準備した。ソースはGitHubの`Yuto-0906/ARTOFFICE-video-maker`・`codex/ios-native`を継続使用する。既存のCodemagic設定は残す。GitHub Actionsや有料ランナーを起動する変更ではない。

## 確認済みの利用枠と未設定の接続

- Azure DevOps組織`yuto200596`・既存プロジェクト`ios-development`へサインイン済みだった。
- Organization settings → Parallel jobsで，非公開プロジェクトのMicrosoft-hosted無料枠が1並列ジョブ・月1,800分，消費0分と表示された。Self-hosted枠とは区別して確認した。
- プロジェクトには既存のパイプラインがなかった。GitHub接続を選択する段階で，自動承認レビューが，対象リポジトリとAzureへのアクセス範囲の明示的な承認不足を理由に操作を拒否した。拒否された操作は迂回していない。
- ローカルにAzure CLI・Azure DevOps用PATは確認できていない。初期接続をブラウザーで確認したが，パイプライン作成・CI起動・署名情報のAzureへの送信はまだ行っていない。

その後，ユーザーからARTOFFICEだけの連携設定と，GitHub Appが表示したメタデータの読取り・コード・Checks・コミット状態・Deployments・Issues・PRの読書きについて承認を得た。GitHubの本人確認も完了した。別リポジトリにも変更が及ぶ可能性を理由に自動レビューが一度確定を拒否したが，保存済みの設定で，そのリポジトリには既に同じ権限があることを読み取り確認した。既存の許可を変えず，ARTOFFICEの追加だけを確定した。

パイプラインID1・`Yuto-0906.ARTOFFICE-video-maker`を作成し，[Run 1](https://dev.azure.com/yuto200596/ios-development/_build/results?buildId=1)を手動起動した。対象は`c36b3f8c0c72877fe50d694e3b15f8ca6d07ef79`。Core25件と，実機用アプリ・シミュレーターテストのコンパイルが成功し，iPhone系の試験に進んだ。選択された機種はiPhone 16e・iOS26.2であり，iPhone15実機の結果とは扱わない。全体の試験はまだ完了していない。通常の状態確認は既存GitHub CLIのChecks APIを使い，AzureのAPI認証がない詳細ログの確認だけブラウザーで補っている。

Azure Secure filesへのP12選択は，自動承認レビューが，署名情報の送信承認はCodemagic宛てに限られるとして拒否した。指定スキル第4項には新しいCIへの送信を許可する指示があるが，今回のレビューではAzure宛ての明示承認を要求された。署名情報はまだAzureへ送っておらず，署名なしの検証を継続しながら，具体的な送信先と3種類の情報について確認する。

## ソースに用意した構成

ルートの`azure-pipelines.yml`は`trigger: none`・`pr: none`とし，手動実行だけを定義する。`task`は`all`・`media`・`storage`・`ui`・`device`から選ぶ。通常の検証は署名情報なしで行い，iPhoneとiPadを別の60分ジョブへ分ける。1並列枠で順番に実行し，既存の`ci.sh`へ`ARTOFFICE_TEST_FAMILY`を渡す。Codemagicで未指定の場合は従来どおり両端末を実行する。

無料の標準プールにある`macOS-26`と，そのソフトウェア一覧で確認したXcode 26.6を明示した。現在Codemagicで使うXcode 27.1と同じ検証環境ではない。最低OS17以降のAPIを使うアプリのビルドと，提供されるiOSシミュレーターでの検証を行い，実際のSDK・シミュレーター機種・OSはCIログで記録する。OS27.0.1の実機受入は更新後のiPadで別に確認する。無料IntelランナーでのMetal利用可否も未確認であり，GPU試験の環境制約と製品不具合をログから切り分ける。

`device`の場合だけ，次の3種類のSecure filesを使う構成にしている。これらはまだAzureへ登録していない。パスワードも保護ファイルとして送り，実行時にAzureのSecret変数へ登録するため，ブラウザーの入力欄や会話へ値を表示する必要がない。

| Azureの入力 | 内容 |
|---|---|
| Secure file：`artoffice-development.p12` | 既存Apple Development証明書と対応する秘密鍵 |
| Secure file：`artoffice-app-development.mobileprovision` | 今回のBundle IDと登録済み2端末用の既存開発プロファイル |
| Secure file：`artoffice-p12-password.txt` | 既存P12の復号パスワード。実行時だけ`ARTOFFICE_DEVELOPMENT_P12_PASSWORD`としてSecret登録する |

`DownloadSecureFile`で取得したファイルを`scripts/ios/azure-sign.py`がプロセス内で既存の署名スクリプトへ渡す。パスワードは子プロセスの開始前に，Azureの`task.setvariable`・`issecret=true`の制御コマンドでマスク対象へ登録する。通常のログ・引数へ値を表示しない。この処理をローカルで実行しないようAzureエージェントかも検査する。既存の`scripts/ios/sign.py`が一度だけ一時キーチェーンを作り，プロファイル照合，実機用ビルド，署名検証，IPA化，後始末を行う。証明書・プロファイルを再発行せず，既存の署名材料を再利用する。

Secure filesの利用権は今回のパイプラインへ限定する。検証用のジョブへ署名情報を渡さない。公開する成果物はIPAと必要な診断・試験結果に絞り，作業領域全体やSecure filesを成果物へ含めない。送信専用のローカル一時ファイルは登録後に削除し，元のP12とDPAPI保護したパスワードを維持する。

## 次の操作

1. 起動済みの署名なし検証を追跡し，コンパイル・試験の失敗を修正する。
2. 署名情報のAzureへの送信承認を確認し，上記3ファイルを保護領域へ登録する。利用権は今回のパイプラインに限定する。
3. 通常の状態確認は既存GitHub Checks APIを使う。Azure独自の実行・ログ・成果物APIを使える認証が整えば，それらもCLI・APIへ移す。ブラウザーのサインイン状態をCLI認証済みとは扱わない。
4. 必要な検証が通ったら`device`を実行する。IPA・リビジョン・プロファイルを照合してからiPadへ上書きする。

Windows側ではYAMLの構文，Python署名アダプターの構文，`bash -n scripts/ios/ci.sh`を確認した。最初のYAMLの展開と署名なしジョブの開始を確認したが，その後に修正したSecure files用アダプターの署名実行は未確認である。

## 確認した公式資料

- [Microsoft-hosted agents](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/hosted?view=azure-devops)：標準プールのmacOSイメージ。
- [Configure and pay for parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs?view=azure-devops)：無料枠の条件。今回の利用権は実際の組織画面でも確認した。
- [macOS 26のソフトウェア一覧](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)：Xcode 26.6のパスとSDK。実ジョブのイメージ更新により変わるため，CIログも記録する。
- [Azure Pipelinesの制御コマンド](https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands?view=azure-devops)：エージェントによるSecret変数の登録とログのマスク。
