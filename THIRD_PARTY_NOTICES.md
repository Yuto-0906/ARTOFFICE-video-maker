# 第三者ソフトウェア

配布ZIPには次の第三者ソフトウェアを同梱します。正確な版，URL，SHA-256は`tools.lock.json`に記録しています。

## FFmpeg 8.1.2 Essentials Build

FFmpegは別プロセスとして映像・音声処理に使用します。WindowsバイナリはFFmpeg公式ダウンロードページから案内されているgyan.devの64bit Essentials Buildで，GPLv3ライセンスです。配布物の`licenses/FFmpeg-GPL-3.0.txt`と`licenses/FFmpeg-README.txt`を参照してください。

- プロジェクト：https://ffmpeg.org/
- Windowsビルド：https://www.gyan.dev/ffmpeg/builds/
- 対応ソース：https://github.com/FFmpeg/FFmpeg/tree/n8.1.2

## ImageMagick 7.1.2-30

HEIC／HEIF画像のデコードに，HEIC delegateを内蔵したImageMagick portable Q16-HDRI x64を使用します。ImageMagick Licenseで提供されます。`licenses/ImageMagick-LICENSE.txt`と`licenses/ImageMagick-NOTICE.txt`を参照してください。

- プロジェクト：https://imagemagick.org/
- ソース：https://github.com/ImageMagick/ImageMagick/tree/7.1.2-30

## Noto Sans JP 2.004

タイトル描画に，Google FontsのNoto Sans JP可変フォントからweight 900として生成したBlackインスタンスを使用します。SIL Open Font License 1.1で提供されます。`licenses/NotoSansJP-OFL.txt`を参照してください。

- 配布元：https://github.com/google/fonts/tree/6a003b5eb672dc8bf5bff5937cf5863f8b175445/ofl/notosansjp

## アプリケーションライブラリ

アプリ本体はTauri，React，TypeScript，Rustおよび各エコシステムのライブラリを利用しています。各ライブラリのライセンスは`package-lock.json`と`src-tauri/Cargo.lock`で固定されたパッケージの配布元を参照してください。アプリ本体の著作権はARTOFFICEに帰属します。
