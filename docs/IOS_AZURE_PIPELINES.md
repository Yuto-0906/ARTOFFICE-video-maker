# Azure Pipelinesでの追加検証

更新日：2026年10月27日。

`windows-ios-development`スキルの再読込みを受け，無料枠のあるAzure Pipelinesを追加の検証先として準備した。ソースはGitHubの`Yuto-0906/ARTOFFICE-video-maker`・`codex/ios-native`を継続使用する。既存のCodemagic設定は残す。GitHub Actionsや有料ランナーを起動する変更ではない。

## 確認済みの利用枠と未設定の接続

- Azure DevOps組織`yuto200596`・既存プロジェクト`ios-development`へサインイン済みだった。
- Organization settings → Parallel jobsで，非公開プロジェクトのMicrosoft-hosted無料枠が1並列ジョブ・月1,800分，消費0分と表示された。Self-hosted枠とは区別して確認した。
- プロジェクトには既存のパイプラインがなかった。GitHub接続を選択する段階で，自動承認レビューが，対象リポジトリとAzureへのアクセス範囲の明示的な承認不足を理由に操作を拒否した。拒否された操作は迂回していない。
- ローカルにAzure CLI・Azure DevOps用PATは確認できていない。初期接続をブラウザーで確認したが，パイプライン作成・CI起動・署名情報のAzureへの送信はまだ行っていない。

## ソースに用意した構成

ルートの`azure-pipelines.yml`は`trigger: none`・`pr: none`とし，手動実行だけを定義する。`task`は`all`・`media`・`storage`・`ui`・`device`から選ぶ。通常の検証は署名情報なしで行い，iPhoneとiPadを別の60分ジョブへ分ける。1並列枠で順番に実行し，既存の`ci.sh`へ`ARTOFFICE_TEST_FAMILY`を渡す。Codemagicで未指定の場合は従来どおり両端末を実行する。

無料の標準プールにある`macOS-26`と，そのソフトウェア一覧で確認したXcode 26.6を明示した。現在Codemagicで使うXcode 27.1と同じ検証環境ではない。最低OS17以降のAPIを使うアプリのビルドと，提供されるiOSシミュレーターでの検証を行い，実際のSDK・シミュレーター機種・OSはCIログで記録する。OS27.0.1の実機受入は更新後のiPadで別に確認する。無料IntelランナーでのMetal利用可否も未確認であり，GPU試験の環境制約と製品不具合をログから切り分ける。

`device`の場合だけ，変数グループ`artoffice-ios-signing`と次のSecure filesを使う構成にしている。これらはまだAzureへ登録していない。

| Azureの入力 | 内容 |
|---|---|
| Secure file：`artoffice-development.p12` | 既存Apple Development証明書と対応する秘密鍵 |
| Secure file：`artoffice-app-development.mobileprovision` | 今回のBundle IDと登録済み2端末用の既存開発プロファイル |
| Secret変数：`ARTOFFICE_DEVELOPMENT_P12_PASSWORD` | 既存P12の復号パスワード |

`DownloadSecureFile`で取得したファイルを`scripts/ios/azure-sign.py`がプロセス内で既存の署名スクリプトへ渡す。秘密データは引数・標準出力へ出さない。既存の`scripts/ios/sign.py`が一度だけ一時キーチェーンを作り，プロファイル照合，実機用ビルド，署名検証，IPA化，後始末を行う。証明書・プロファイルを再発行せず，既存の署名材料を再利用する。

Secure filesとSecret変数グループの利用権は今回のパイプラインへ限定する。検証用のジョブへ署名情報を渡さない。公開する成果物はIPAと必要な診断・試験結果に絞り，作業領域全体やSecure filesを成果物へ含めない。

## 次の操作

1. 対象のGitHubリポジトリをAzureへ接続する範囲について承認を得た後，接続画面が実際に要求する権限を確認する。対象外のリポジトリまで広げない。
2. `codex/ios-native`の`azure-pipelines.yml`を既存YAMLとして選び，最初は署名なしの検証を実行する。対象コミットとRun IDを確定し，コンパイル・試験の失敗を修正する。
3. 通常の実行・監視・成果物取得にはAzure CLIまたは公式REST APIの認証を整える。ブラウザーのサインイン状態をCLI認証済みとは扱わない。
4. 必要な検証が通ったら，上記Secure filesとSecret変数を対象パイプラインに登録し，`device`を実行する。IPA・リビジョン・プロファイルを照合してからiPadへ上書きする。

Windows側ではYAMLの構文，Python署名アダプターの構文，`bash -n scripts/ios/ci.sh`を確認した。Azure自身によるYAMLの展開とジョブ実行は未確認である。

## 確認した公式資料

- [Microsoft-hosted agents](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/hosted?view=azure-devops)：標準プールのmacOSイメージ。
- [Configure and pay for parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs?view=azure-devops)：無料枠の条件。今回の利用権は実際の組織画面でも確認した。
- [macOS 26のソフトウェア一覧](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)：Xcode 26.6のパスとSDK。実ジョブのイメージ更新により変わるため，CIログも記録する。
