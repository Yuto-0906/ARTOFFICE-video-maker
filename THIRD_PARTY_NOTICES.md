# 第三者ソフトウェア

配布アプリには次の第三者ソフトウェアを同梱します。Windows版の版・URL・SHA-256はtools.lock.json，Mac版のソースはtools.macos.lock.jsonに記録しています。

## FFmpeg 8.1.2 Essentials Build

FFmpegは別プロセスとして映像・音声処理に使用します。WindowsバイナリはFFmpeg公式ダウンロードページから案内されているgyan.devの64bit Essentials Buildで，GPLv3ライセンスです。配布物の`licenses/FFmpeg-GPL-3.0.txt`と`licenses/FFmpeg-README.txt`を参照してください。

- プロジェクト：https://ffmpeg.org/
- Windowsビルド：https://www.gyan.dev/ffmpeg/builds/
- 対応ソース：https://github.com/FFmpeg/FFmpeg/tree/n8.1.2

## ImageMagick 7.1.2-30

Windows版のHEIC／HEIF画像のデコードに，HEIC delegateを内蔵したImageMagick portable Q16-HDRI x64を使用します。ImageMagick Licenseで提供されます。`licenses/ImageMagick-LICENSE.txt`と`licenses/ImageMagick-NOTICE.txt`を参照してください。Mac版はmacOS標準のImageIOを使用し，ImageMagickを同梱しません。

- プロジェクト：https://imagemagick.org/
- ソース：https://github.com/ImageMagick/ImageMagick/tree/7.1.2-30

## Noto Sans JP 2.004

タイトル描画に，Google FontsのNoto Sans JP可変フォントからweight 900として生成したBlackインスタンスを使用します。SIL Open Font License 1.1で提供されます。`licenses/NotoSansJP-OFL.txt`を参照してください。

- 配布元：https://github.com/google/fonts/tree/6a003b5eb672dc8bf5bff5937cf5863f8b175445/ofl/notosansjp

## Mac版のFFmpegと静的リンクしたライブラリ

Mac版のFFmpeg・ffprobeは公式のFFmpeg 8.1.2からビルドします。libx264，FreeType，HarfBuzzを静的リンクし，Appleのシステムライブラリ以外に依存しない構成です。FFmpegのGPLv3，x264のGPL，FreeTypeのFTL，HarfBuzzのMITライセンス表示をアプリ内のlicensesへ同梱します。FreeTypeの一部の著作権は© 2006–2026 The FreeType Project（https://freetype.org/）に帰属し，同プロジェクトは権利を留保します。

対応ソースとビルド手順は，同じReleaseのmacos-sources.tar.gzに収録します。NASM・pkgconfはビルドのみに使用し，アプリへ同梱しません。

- FFmpeg：https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
- x264：https://code.videolan.org/videolan/x264
- FreeType：https://freetype.org/
- HarfBuzz：https://github.com/harfbuzz/harfbuzz

## アプリケーションライブラリ

アプリ本体はTauri，React，TypeScript，Rustおよび各エコシステムのライブラリを利用しています。各ライブラリのライセンスは`package-lock.json`と`src-tauri/Cargo.lock`で固定されたパッケージの配布元を参照してください。アプリ本体の著作権はARTOFFICEに帰属します。
