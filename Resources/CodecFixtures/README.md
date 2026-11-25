# 固定解码素材

测试使用同一份、随应用发布的 1920×1080、8-bit 4:2:0 视频码流，帧率 30 fps，共 120 帧。画面由 FFmpeg `testsrc2` 生成，没有外部视频素材。H.264 和 HEVC 分别编码后固定为不可变的 Annex B elementary stream。解码测试读取的输入文件不依赖本轮的编码器输出。

| 文件 | 参数集 | SHA-256 |
| --- | --- | --- |
| `h264-1080p-120f.h264` | AVC SPS/PPS，AUD 分隔，单 IDR GOP，B 帧关闭 | `44302a9e9d2460e7a85cff47ab0cdc832668881538489d1f1bca213abd042cf5` |
| `hevc-1080p-120f.hevc` | HEVC VPS/SPS/PPS，AUD 分隔，单 IDR GOP，B 帧关闭 | `7cbd1c678ed0ade4ea534b9e201a5789df0b56544971977258488902c611ac5e` |

应用中的 loader 校验这些 SHA-256，并将每个访问单元转换成 length-prefixed NAL 与 `CMSampleBuffer`。准备素材只使用 CoreMedia 创建格式描述和样本，不打开 VideoToolbox 会话。样本使用 1/30 秒时间戳，解码请求使用 NV12 像素缓冲。

素材在 macOS 上用 VideoProc Converter AI 随附的 FFmpeg 6.0 生成。编码器是 `libx264` 及 `libx265`，输入和参数均可由以下命令复现。FFmpeg 和编码库没有被复制或加入 GPU-Z。

```sh
ffmpeg -f lavfi -i 'testsrc2=size=1920x1080:rate=30' -frames:v 120 -pix_fmt yuv420p -an \
  -c:v libx264 -preset veryfast -crf 20 \
  -x264-params 'aud=1:keyint=120:min-keyint=120:scenecut=0:bframes=0:repeat-headers=1' \
  -f h264 h264-1080p-120f.h264

ffmpeg -f lavfi -i 'testsrc2=size=1920x1080:rate=30' -frames:v 120 -pix_fmt yuv420p -an \
  -c:v libx265 -preset ultrafast -crf 20 \
  -x265-params 'pools=1:frame-threads=1:log-level=error:aud=1:keyint=120:min-keyint=120:scenecut=0:bframes=0:repeat-headers=1' \
  -f hevc hevc-1080p-120f.hevc
```

## 4K decode matrix assets

The 4K pair uses the same generated `testsrc2` pattern, 8-bit `yuv420p` source and 30 fps timing as the 1080p pair. Each stream contains 48 pictures in one GOP, with AUD delimiters and parameter sets in the elementary stream. H.264 uses CRF 22 with a 24 Mbps VBV cap; HEVC uses CRF 24 with a 16 Mbps VBV cap. The checked-in files are about 4.4 MiB (H.264) and 3.9 MiB (HEVC).

| File | Dimensions / frames | SHA-256 |
| --- | --- | --- |
| `h264-4k-48f.h264` | 3840×2160, 48 frames, 30 fps | `6f846d3e50d3874ef2f32b7fcff0f8902a14895f97dac3290f059e1cae48cc2e` |
| `hevc-4k-48f.hevc` | 3840×2160, 48 frames, 30 fps | `da161736ebbe2e8b0d44ae5d8b3f7f08936a8413c8c4040688a5c62dedae5d80` |

Reproduce the streams with FFmpeg 6.0 and its `libx264` / `libx265` encoders:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=3840x2160:rate=30' -frames:v 48 -pix_fmt yuv420p -an \
  -c:v libx264 -preset veryfast -crf 22 -maxrate 24000k -bufsize 48000k \
  -x264-params 'aud=1:keyint=48:min-keyint=48:scenecut=0:bframes=0:repeat-headers=1' \
  -f h264 h264-4k-48f.h264

ffmpeg -f lavfi -i 'testsrc2=size=3840x2160:rate=30' -frames:v 48 -pix_fmt yuv420p -an \
  -c:v libx265 -preset ultrafast -crf 24 -maxrate 16000k -bufsize 32000k \
  -x265-params 'pools=1:frame-threads=1:log-level=error:aud=1:keyint=48:min-keyint=48:scenecut=0:bframes=0:repeat-headers=1' \
  -f hevc hevc-4k-48f.hevc
```

Independent software-decoder verification (no `-hwaccel` option is enabled):

```sh
ffmpeg -v error -i h264-4k-48f.h264 -map 0:v:0 -f framemd5 h264-4k.framemd5
ffmpeg -v error -i hevc-4k-48f.hevc -map 0:v:0 -f framemd5 hevc-4k.framemd5
```

Each output contains 48 decoded frame records. The app loader verifies the pinned file hashes, expected dimensions and frame counts before constructing the CoreMedia samples.
