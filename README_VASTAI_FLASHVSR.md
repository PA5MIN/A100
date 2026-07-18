# VastAI FlashVSR A100 Runner

This repo keeps the A100 FlashVSR restore and run commands as scripts, so a
new VastAI machine only needs one setup command and one daily run command.

## What Was Backed Up

GitHub Release:

```text
https://github.com/PA5MIN/A100/releases/tag/a100-cu128-cudnn919-sm80-20260523
```

The release contains:

```text
/workspace/envs/flashvsr-fast
/workspace/FlashVSR
/workspace/Block-Sparse-Attention
/workspace/flashvsr_backup_meta
```

It is built for:

```text
A100/A800 sm80
torch 2.11.0+cu128
CUDA 12.8
cuDNN 91900
```

Use it on A100/A800-class machines. Different GPU architectures may need a
fresh Block-Sparse-Attention build.

## New VastAI Machine

Clone this repo on the VastAI machine:

```bash
cd /workspace
apt-get update
apt-get install -y git
git clone https://github.com/PA5MIN/A100.git
```

If the repo or release is private, log in first or export a GitHub token:

```bash
export GH_TOKEN="paste_token_here"
```

Restore the prebuilt environment:

```bash
bash /workspace/A100/vastai_setup_flashvsr.sh
```

That downloads the release assets, verifies checksums, installs Miniconda, and
restores everything to `/workspace`.

Use at least a 100G disk. A 32G root disk is not enough for the 18G split
backup plus the restored runtime. The setup script checks for at least 80G
free before downloading and restoring.

## Run A Video

Put videos here:

```text
/workspace/flashvsr_jobs/input
```

Then run:

```bash
bash /workspace/A100/run_flashvsr_video.sh
```

Outputs go here:

```text
/workspace/flashvsr_jobs/output
```

You can also pass a video path directly:

```bash
bash /workspace/A100/run_flashvsr_video.sh /workspace/my_video.mp4
```

## Default Processing

The runner auto-detects the source shape and does not add an `fps=` filter by
default, so a `21.85fps` source stays at its original frame timing. For a
`1088x1920` portrait video, the clean path is:

```text
1088x1920 portrait video
-> rotate to 1920x1088 landscape
-> scale down to 960x544
-> FlashVSR x4 to 3840x2176
-> crop 8 px top + 8 px bottom to 3840x2160
-> merge original audio
```

For a `1080x1920` portrait video, the path is:

```text
1080x1920 portrait video
-> rotate to 1920x1080 landscape
-> scale down to 960x540
-> pad 2 px top + 2 px bottom to 960x544
-> FlashVSR x4 to 3840x2176
-> crop 8 px top + 8 px bottom to 3840x2160
-> merge original audio
```

For landscape inputs, it skips the rotation. If the aspect ratio matches
`960x544`, it scales directly to `960x544`; if it matches `16:9`, it scales to
`960x540` and pads to `960x544`; otherwise it center-crops to fit.

The runner uses overlapped chunks by default, so the previous 14s/22s segment
jump should not reappear.

The runner also passes `-nostdin` to ffmpeg. Without that, ffmpeg can consume
the chunk metadata from the shell loop, causing only `chunk_000` to run and the
final video to be only a few seconds long.

If a future input needs custom handling, override preprocessing:

```bash
PREPROCESS_FILTER='transpose=1,scale=960:544:flags=area,setsar=1' \
bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

Only use this if you deliberately want a standard 30fps output:

```bash
FPS=30 bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

The script uses `-noautorotate` by default so encoded dimensions are handled
deterministically. To let ffmpeg honor rotation metadata, run:

```bash
FFMPEG_INPUT_OPTS='' bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

If the portrait video rotates the wrong way, use the opposite transpose:

```bash
PORTRAIT_ROTATE_FILTER=transpose=2 bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

If a chunk still reports not enough frames, increase overlap:

```bash
OVERLAP_FRAMES=24 bash /workspace/A100/run_flashvsr_video.sh
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the real issues found during
the first VastAI restore and run: private Release 404s, 32G disk failures,
broken merged tar files, conda activation, source video corruption, and AAC
audio warnings.
