# Deploy On VastAI A100

Use an A100/A800 sm80 machine with at least 100G disk. 150G is better.

## 1. Start A VastAI Instance

Recommended:

```text
GPU: A100 80GB or A800 80GB
CUDA: 12.8
Disk: 100G minimum, 150G recommended
Image: vastai/base-image_cuda-12.8.1-auto/jupyter
```

Check the machine:

```bash
df -h /workspace
nvidia-smi
```

## 2. Clone This Repo

```bash
cd /workspace
apt-get update
apt-get install -y git gh zstd wget ffmpeg git-lfs curl ca-certificates

git clone https://github.com/PA5MIN/A100.git
cd /workspace/A100
```

If the release is private, log in:

```bash
gh auth login
```

Or use a token:

```bash
export GH_TOKEN="paste_token_here"
```

## 3. Restore The Prebuilt FlashVSR Environment

```bash
bash /workspace/A100/vastai_setup_flashvsr.sh
```

This restores:

```text
/workspace/miniconda
/workspace/envs/flashvsr-fast
/workspace/FlashVSR
/workspace/Block-Sparse-Attention
```

## 4. Run Videos

Put videos here:

```bash
mkdir -p /workspace/flashvsr_jobs/input
```

Then run:

```bash
bash /workspace/A100/run_flashvsr_video.sh
```

Outputs are written to:

```text
/workspace/flashvsr_jobs/output
```

Run one specific file:

```bash
bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

## Notes

The default runner does not add an `fps=` filter. A 21.85fps source stays at
the source frame timing. Use this only if you intentionally want 30fps:

```bash
FPS=30 bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

For 1088x1920 portrait videos, the runner uses:

```text
transpose -> 1920x1088
scale -> 960x544
FlashVSR -> 3840x2176
crop -> 3840x2160
```

For 1080x1920 portrait videos, it uses:

```text
transpose -> 1920x1080
scale -> 960x540
pad -> 960x544
FlashVSR -> 3840x2176
crop -> 3840x2160
```
