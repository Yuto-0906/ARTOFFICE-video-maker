# Mac版のビルドと署名

macOS 15以降のApple Silicon・Intelを対象とします。開発はWindowsで行い，ビルドは公開リポジトリの標準GitHub Actionsランナーで行います。加入済みのApple Developer Programを利用し，有料のMacレンタルや大型ランナーは使用しません。

## 通常のCI

プルリクエストとmainの更新で，Windows，macOS arm64，macOS x64を検証します。

- Macジョブはmacos-15とmacos-15-intelを使用します。
- FFmpeg 8.1.2，x264，FreeType，HarfBuzzはtools.macos.lock.jsonに固定した公式ソースからビルドします。すべてのダウンロードでSHA-256を確認します。
- NASMとpkgconfもビルド時に固定ソースから用意します。実行時にHomebrewは必要ありません。
- FFmpegとffprobeの第三者ライブラリは静的リンクします。otoolとlipoで，Appleのシステムライブラリ以外に依存せず，対象CPU・最低OSが正しいことを確認します。
- CIのDMGはアドホック署名です。一般配布用の署名・公証済みDMGとは区別し，Releaseへ公開しません。
- 配布アプリを日本語・空白を含む別のフォルダーへコピーし，PATHをシステムのみに制限して，実際の書き出し処理を検証します。
- 通常のCIは署名用Secretsを受け取りません。キャッシュと中間成果物はGitHubの無料枠を利用し，成果物の保持期間は7日です。

## 初回設定：WindowsでCSRを作る

Git for WindowsのOpenSSLとGitHub CLIを使います。リポジトリのルートで実行します。

~~~powershell
.\scripts\prepare-macos-signing.ps1
~~~

.macos-signing/DeveloperID.certSigningRequestが証明書申請ファイルです。.macos-signingはGit管理から除外されます。秘密鍵はランダムなパスワードで暗号化し，パスワードはWindowsのDPAPIで現在のユーザーに保護して保存します。フォルダーにも現在のユーザーだけがアクセスできるACLを設定します。

同じフォルダーが既にある場合，鍵を上書きしません。CSRを発行したWindowsユーザーを変更すると，保護したパスワードを復元できません。

## Appleのサイトで証明書を発行する

1. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/add)へ，証明書を発行できるAccount Holderとしてログインします。
2. Developer ID Applicationを選び，作成したCSRをアップロードします。iOS用のApple Distributionとは別の証明書です。
3. 発行された.cerをこのWindowsへダウンロードします。
4. [Apple Account](https://account.apple.com/)で，公証専用のアプリ用パスワードを作ります。Apple Accountの通常のログインパスワードは使用しません。
5. [メンバーシップ情報](https://developer.apple.com/account)で10桁のTeam IDを確認します。

Mac本体やXcodeの画面操作は不要です。初回の本人ログイン・二要素認証は利用者が行います。

## GitHub Secretsへ登録する

~~~powershell
.\scripts\register-macos-signing.ps1 -CertificatePath "C:\Users\ユーザー名\Downloads\developerID_application.cer" -AppleId "Apple Accountのメールアドレス" -TeamId "ABCDEFGHIJ"
~~~

アプリ用パスワードは非表示の入力欄で入力します。スクリプトは証明書の種類・有効期間・Team IDと，CSRの秘密鍵との一致を確認し，Appleの中間証明書を加えたPKCS#12を作成します。次のSecretsを，値を表示せずGitHub CLIの標準入力から登録します。

| Secret | 内容 |
| --- | --- |
| APPLE_CERTIFICATE | 秘密鍵を含むPKCS#12のBase64 |
| APPLE_CERTIFICATE_PASSWORD | PKCS#12のパスワード |
| APPLE_SIGNING_IDENTITY | Developer ID Applicationの証明書名 |
| APPLE_ID | Apple Accountのメールアドレス |
| APPLE_PASSWORD | 公証専用のアプリ用パスワード |
| APPLE_TEAM_ID | Team ID |

秘密鍵・パスワード・PKCS#12を，チャットやIssue，プルリクエスト，ログへ貼り付けないでください。登録後の確認はgh secret listで名前だけを確認します。

公証用パスワードを後で入力する場合は，登録スクリプトへ-SigningOnlyを加えると，署名用の5項目だけを準備できます。APPLE_PASSWORDはGitHubのSettings → Secrets and variables → ActionsでNew repository secretを開き，利用者が直接登録することもできます。Apple Accountの作成済みアプリ用パスワードは文字列を再表示できないため，保存していなければ公証用を新しく1つ作成します。

## 署名・公証済みの下書きRelease

Releaseワークフローをv0.4.0のタグpush，または手動実行で起動します。手動実行時のtag入力はpackage.jsonの版と一致させます。

署名設定が不足すると，ビルド前に不足するSecret名を表示して終了します。Macの各ジョブは一時キーチェーンへ証明書を取り込み，同梱の実行ファイルを含む.appをDeveloper IDで署名し，Tauri経由で公証します。DMGも署名・公証し，両方の公証チケットとGatekeeperの検証を通します。一時キーチェーンは成否にかかわらず削除します。

Windows ZIPとMac DMGの2種類，対応ソース，SHA-256と検証結果がすべてそろった場合のみ，試験版の下書きReleaseを作ります。署名や公証が失敗した場合に，未公証の代替ファイルを公開する処理はありません。

初回の公証が長くかかる場合は，失敗ログにある申請IDを確認します。未完了の状態を公証済みとして扱いません。

## 対応ソースと再現

Mac版と同じ版のmacos-sources.tar.gzには，ビルドに使ったソースアーカイブ，両lockファイル，ビルドスクリプト，この手順を収録します。ソース展開先のリポジトリと同じ階層構成でスクリプトを実行し，Python 3.13とlockファイル記載のfontTools・Meson・Ninjaを用意します。

~~~sh
python scripts/build-macos-tools.py --arch arm64
python scripts/build-macos-tools.py --arch x86_64
~~~

それぞれ同じCPUのMac環境で実行します。生成されたFFmpegのconfig.hとconfig.makは，.tool-cache/macos-runtime内にも保存します。

## 確認できる範囲

CIはバックエンドの実際の書き出しとキャンセル，同梱物の独立性，署名・公証を確認します。画面操作，WKWebViewの動画プレビュー，実機でのVideoToolboxの画質・速度は別の確認です。docs/MAC_TEST_CHECKLIST.mdに結果を記録するまで，実機確認済みとは案内しません。

参考：[TauriのMac署名・公証](https://v2.tauri.app/distribute/sign/macos/)，[AppleのDeveloper ID証明書](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)，[GitHub Actionsの料金](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。
