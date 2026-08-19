# A100 FlashVSR

**One restore command. One run command. 4K video from a Vast.ai A100/A800.**

This repository packages a known-good [FlashVSR](https://github.com/OpenImagingLab/FlashVSR) runtime for NVIDIA **A100 / A800 (sm80)** plus the shell scripts that actually process long videos: overlapped chunks, original frame timing, and a 3840×2160 output.

中文：在 Vast.ai 上租一台 A100/A800，一条命令还原已经编好的 FlashVSR 环境，再一条命令把视频超到 4K。默认保持片源帧率，竖屏会先转横再处理，长视频按重叠分块避免接缝跳变。

[![CUDA](https://img.shields.io/badge/CUDA-12.8-76B900?logo=nvidia&logoColor=white)](#hardware)
[![GPU](https://img.shields.io/badge/GPU-A100%20%2F%20A800%20sm80-76B900?logo=nvidia&logoColor=white)](#hardware)
[![FlashVSR](https://img.shields.io/badge/FlashVSR-v1.1%20Tiny%20Long-0ea5e9)](https://github.com/OpenImagingLab/FlashVSR)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Why this exists

FlashVSR on a cloud GPU usually fails for boring reasons: disk too small, cuDNN too old, Block-Sparse-Attention rebuilt for the wrong architecture, ffmpeg eating the chunk list from stdin, seams between 8-second segments.

This repo is the path that already worked:

1. Restore a **prebuilt** conda env + FlashVSR + Block-Sparse-Attention from [GitHub Releases](https://github.com/PA5MIN/A100/releases/tag/a100-cu128-cudnn919-sm80-20260523) (no compile on a fresh box).
2. Run `run_flashvsr_video.sh` on one file or a folder.

## Hardware

| Item | Requirement |
|---|---|
| GPU | A100 80GB or A800 80GB (**sm80**). Other architectures need a fresh Block-Sparse-Attention build. |
| CUDA | Driver reporting ≥ 12.8. Runtime in the backup is **torch 2.11.0+cu128**, **cuDNN 91900**. |
| Disk | **100 GB minimum**, 150 GB better. A 32 GB root disk is not enough. |
| Image | Vast.ai CUDA 12.8 base / Jupyter image is fine. |

## Quick start

On a new Vast.ai instance:

```bash
cd /workspace
apt-get update
apt-get install -y git
git clone https://github.com/PA5MIN/A100.git
bash /workspace/A100/vastai_setup_flashvsr.sh
```

Put videos in `/workspace/flashvsr_jobs/input`, then:

```bash
bash /workspace/A100/run_flashvsr_video.sh
```

Or pass a path:

```bash
bash /workspace/A100/run_flashvsr_video.sh /workspace/my_video.mp4
```

Outputs land in `/workspace/flashvsr_jobs/output` as `*_3840x2160_flashvsr.mp4`.

Step-by-step notes: [DEPLOY.md](DEPLOY.md). Real failure modes from the first restore: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## What the runner does

Default: **keep source frame timing** (no `fps=` filter). Portrait is rotated to landscape first.

```text
portrait 1088×1920
  → rotate 1920×1088
  → scale 960×544
  → FlashVSR ×4  → 3840×2176
  → crop 8 px top/bottom → 3840×2160
  → mux original audio
```

```text
portrait 1080×1920
  → rotate 1920×1080
  → scale 960×540
  → pad 2 px → 960×544
  → FlashVSR ×4 → 3840×2176
  → crop → 3840×2160
  → mux original audio
```

Landscape skips rotation. Matching `960×544` scales directly; `16:9` scales to `960×540` then pads; anything else is center-cropped to fit.

Chunks overlap so FlashVSR’s `8n−3` tail loss does not show up as a jump. Every ffmpeg call uses `-nostdin` so it cannot steal the chunk list from the shell loop.

## Useful overrides

```bash
# Force 30 fps (off by default)
FPS=30 bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4

# Custom preprocess
PREPROCESS_FILTER='transpose=1,scale=960:544:flags=area,setsar=1' \
  bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4

# Opposite portrait rotation
PORTRAIT_ROTATE_FILTER=transpose=2 bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4

# Honor container rotation metadata
FFMPEG_INPUT_OPTS='' bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4

# More overlap if a chunk is short on frames
OVERLAP_FRAMES=24 bash /workspace/A100/run_flashvsr_video.sh
```

## What’s in the release

Tag [`a100-cu128-cudnn919-sm80-20260523`](https://github.com/PA5MIN/A100/releases/tag/a100-cu128-cudnn919-sm80-20260523) restores:

```text
/workspace/envs/flashvsr-fast
/workspace/FlashVSR
/workspace/Block-Sparse-Attention
/workspace/flashvsr_backup_meta
```

About 18 GB compressed split archives, SHA-256 checked before extract. `vastai_setup_flashvsr.sh` refuses to start unless `/workspace` has at least 80 GB free.

## Scripts

| File | Role |
|---|---|
| `vastai_setup_flashvsr.sh` | Download release, verify checksums, install Miniconda, restore env |
| `run_flashvsr_video.sh` | Daily path: preprocess → overlapped FlashVSR → concat → audio |
| `flashvsr_overlap_fix.sh` | Standalone overlap-trim helper from the first seam-debug session |

## Credits

- [FlashVSR](https://github.com/OpenImagingLab/FlashVSR) — OpenImagingLab
- [FlashVSR-v1.1 weights](https://huggingface.co/JunhaoZhuang/FlashVSR-v1.1)

This repo only ships restore/run glue and a prebuilt sm80 runtime. Model licenses follow upstream.

## License

Scripts and docs in this repository are [MIT](LICENSE). Third-party code and weights inside the release keep their original licenses.
