# 合成テスト素材

`sample.*`は実在する人物・音楽・撮影素材を含まない合成素材である。

動画はFFmpeg 8.1.2のtestsrc2とsineで作成した96×64，1.5秒の映像と440Hz音である。WebMのみ12fps，ほかは30fps。

| 拡張子 | 映像 | 音声 |
|---|---|---|
| mp4 / mov | H.264 | AAC |
| mkv | H.264 | FLAC |
| webm | VP9 | Opus |
| mts | MPEG-2 Video | MP2 |
| m2ts | H.264 | AC-3 |
| avi | MPEG-4 Part 2 | 非圧縮PCM |
| wmv | WMV2 | WMA2 |

画像はImageMagick 7.1.2-30で作成した96×64の赤い単色画像である。GIFは赤，青の2フレームを含み，先頭フレームの選択を検証する。

固定素材により，テスト環境にAVIFやWebMなどのエンコーダーを要求せず，読み込みを検証できる。
