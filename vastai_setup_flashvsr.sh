#!/usr/bin/env bash
set -euo pipefail

# One-time restore script for a fresh VastAI A100/A800 instance.
# It downloads the prebuilt FlashVSR backup from GitHub Releases and restores
# it to /workspace so Block-Sparse-Attention does not need to be rebuilt.

REPO="${REPO:-PA5MIN/A100}"
TAG="${TAG:-a100-cu128-cudnn919-sm80-20260523}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
RESTORE_DIR="${RESTORE_DIR:-/dev/shm/restore_flashvsr_a100}"
MINICONDA_DIR="${MINICONDA_DIR:-$WORKSPACE_DIR/miniconda}"
ENV_DIR="${ENV_DIR:-$WORKSPACE_DIR/envs/flashvsr-fast}"
MIN_WORKSPACE_FREE_GB="${MIN_WORKSPACE_FREE_GB:-80}"
SKIP_DISK_CHECK="${SKIP_DISK_CHECK:-0}"

ASSET_PREFIX="${ASSET_PREFIX:-flashvsr_a100_cu128_sm80.tar.zst.part-}"
ASSET_SUFFIXES="${ASSET_SUFFIXES:-aa ab ac ad ae af ag ah ai aj ak}"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

run_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "This command needs root: $*" >&2
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

download_asset() {
  local name="$1"
  local url="${BASE_URL}/${name}"

  if [[ -s "$RESTORE_DIR/$name" ]]; then
    echo "Already downloaded: $name"
    return
  fi

  echo "Download: $name"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$TAG" \
      --repo "$REPO" \
      --pattern "$name" \
      --dir "$RESTORE_DIR" \
      --clobber
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    curl -L --fail --retry 5 --retry-delay 3 \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -o "$RESTORE_DIR/$name" "$url"
  else
    curl -L --fail --retry 5 --retry-delay 3 \
      -o "$RESTORE_DIR/$name" "$url"
  fi
}

echo "== FlashVSR A100 restore =="
echo "Repo:      $REPO"
echo "Tag:       $TAG"
echo "Workspace: $WORKSPACE_DIR"
echo

run_root apt-get update
run_root apt-get install -y \
  ca-certificates curl wget git git-lfs gh zstd ffmpeg bzip2

mkdir -p "$WORKSPACE_DIR" "$RESTORE_DIR"

echo
echo "== Workspace disk check =="
df -h "$WORKSPACE_DIR" || true
if [[ "$SKIP_DISK_CHECK" != "1" ]]; then
  avail_kb="$(df -Pk "$WORKSPACE_DIR" | awk 'NR==2 {print $4}')"
  required_kb=$(( MIN_WORKSPACE_FREE_GB * 1024 * 1024 ))
  if (( avail_kb < required_kb )); then
    echo "Not enough free space in $WORKSPACE_DIR." >&2
    echo "Need at least ${MIN_WORKSPACE_FREE_GB}G free for the normal restore path." >&2
    echo "Open a new VastAI instance with 100G+ disk, or rerun with SKIP_DISK_CHECK=1 only if you know what you are doing." >&2
    exit 1
  fi
fi

echo
echo "== GPU check =="
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi || true
else
  echo "nvidia-smi not found. VastAI image may not have NVIDIA tooling in PATH yet." >&2
fi

echo
echo "== Download release assets =="
download_asset "SHA256SUMS.txt"
download_asset "README_RESTORE.txt"
download_asset "torch_env.txt"
download_asset "nvidia-smi.txt"

for suffix in $ASSET_SUFFIXES; do
  download_asset "${ASSET_PREFIX}${suffix}"
done

echo
echo "== Verify release assets =="
cd "$RESTORE_DIR"
sha256sum -c SHA256SUMS.txt

echo
echo "== Install Miniconda if needed =="
if [[ ! -x "$MINICONDA_DIR/bin/conda" ]]; then
  wget -O "$RESTORE_DIR/miniconda.sh" \
    https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
  bash "$RESTORE_DIR/miniconda.sh" -b -p "$MINICONDA_DIR"
else
  echo "Miniconda already exists: $MINICONDA_DIR"
fi

echo
echo "== Restore FlashVSR backup =="
cd "$WORKSPACE_DIR"
cat "$RESTORE_DIR"/${ASSET_PREFIX}* | zstd -d -c | tar -xf -

cat > "$WORKSPACE_DIR/flashvsr_env.sh" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail

# Conda activation scripts from CUDA packages may reference unset variables.
set +u

source /workspace/miniconda/etc/profile.d/conda.sh
conda activate /workspace/envs/flashvsr-fast

export CUDA_HOME="${CONDA_PREFIX}"
export PATH="${CUDA_HOME}/bin:${PATH}"

export TORCH_LIB
TORCH_LIB="$(python - <<'PY'
import os, torch
print(os.path.join(os.path.dirname(torch.__file__), "lib"))
PY
)"

export LD_LIBRARY_PATH="${TORCH_LIB}:${CUDA_HOME}/lib64:${CUDA_HOME}/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="/workspace/FlashVSR:${PYTHONPATH:-}"
export TMPDIR="${TMPDIR:-/workspace/tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/cache/pip}"
export HF_HOME="${HF_HOME:-/workspace/cache/hf}"
export TORCH_HOME="${TORCH_HOME:-/workspace/cache/torch}"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export TORCH_CUDNN_V8_API_ENABLED=1
EOF

chmod +x "$WORKSPACE_DIR/flashvsr_env.sh"
mkdir -p "$WORKSPACE_DIR/tmp" "$WORKSPACE_DIR/cache/pip" "$WORKSPACE_DIR/cache/hf" "$WORKSPACE_DIR/cache/torch"

echo
echo "== Verify restored runtime =="
# shellcheck source=/dev/null
source "$WORKSPACE_DIR/flashvsr_env.sh"

python - <<'PY'
import torch
from block_sparse_attn import block_sparse_attn_func, block_streaming_attn_func
import diffsynth

print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
print("cudnn:", torch.backends.cudnn.version())
print("available:", torch.cuda.is_available())
print("gpu:", torch.cuda.get_device_name(0))
print("capability:", torch.cuda.get_device_capability(0))
if torch.cuda.get_device_capability(0) != (8, 0):
    raise SystemExit("This backup was built for sm80 A100/A800. Current GPU is not sm80.")
print("FlashVSR restore OK")
PY

echo
echo "Done."
echo "Put videos in: $WORKSPACE_DIR/flashvsr_jobs/input"
echo "Run with:      bash /workspace/A100/run_flashvsr_video.sh"
