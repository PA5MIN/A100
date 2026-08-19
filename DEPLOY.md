# Deploy on Vast.ai A100

Use an A100/A800 sm80 machine with at least 100 GB disk. 150 GB is better.

## 1. Start an instance

Recommended:

```text
GPU: A100 80GB or A800 80GB
CUDA: 12.8
Disk: 100G minimum, 150G recommended
Image: vastai/base-image_cuda-12.8.1-auto/jupyter
```

Do not use a 32 GB root disk. The split backup is about 18 GB compressed, and the restored environment needs tens of GB more. `vastai_setup_flashvsr.sh` checks for at least 80 GB free before it starts.

```bash
df -h /workspace
nvidia-smi
```

## 2. Clone this repo

```bash
cd /workspace
apt-get update
apt-get install -y git gh zstd wget ffmpeg git-lfs curl ca-certificates

git clone https://github.com/PA5MIN/A100.git
cd /workspace/A100
```

The repo and release are public. You do not need a GitHub token for the default path.

If you fork this project as a **private** repo, authenticate before restore:

```bash
gh auth login
# or: export GH_TOKEN
```

Never commit a token. Prefer `gh auth login` over putting a PAT in a file.

## 3. Restore the prebuilt FlashVSR environment

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

## 4. Run videos

```bash
mkdir -p /workspace/flashvsr_jobs/input
bash /workspace/A100/run_flashvsr_video.sh
```

Outputs:

```text
/workspace/flashvsr_jobs/output
```

One file:

```bash
bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

## Notes

The default runner does not add an `fps=` filter. A 21.85 fps source stays at the source frame timing. Force 30 fps only if you want that:

```bash
FPS=30 bash /workspace/A100/run_flashvsr_video.sh /workspace/video.mp4
```

For 1088×1920 portrait:

```text
transpose → 1920×1088
scale → 960×544
FlashVSR → 3840×2176
crop → 3840×2160
```

For 1080×1920 portrait:

```text
transpose → 1920×1080
scale → 960×540
pad → 960×544
FlashVSR → 3840×2176
crop → 3840×2160
```

The runner uses overlapped chunks and `ffmpeg -nostdin` so ffmpeg does not consume the chunk list from the shell loop.

Known issues: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
