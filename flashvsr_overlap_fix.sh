#!/usr/bin/env bash
set -euo pipefail

# Fixes FlashVSR segment seams by cutting exact frame ranges with overlap,
# then trimming each upscaled result back to the non-overlapped core frames.

WAN_DIR="${WAN_DIR:-/workspace/FlashVSR/examples/WanVSR}"
ENV_SH="${ENV_SH:-/workspace/miniconda/etc/profile.d/conda.sh}"
CONDA_ENV="${CONDA_ENV:-/workspace/envs/flashvsr-fast}"

INPUT="${INPUT:-/workspace/test_flashvsr/input_960x544_landscape_crop.mp4}"
AUDIO_SOURCE="${AUDIO_SOURCE:-/workspace/test.mp4}"
WORK="${WORK:-/workspace/test_flashvsr/overlap_fix}"

CORE_FRAMES="${CORE_FRAMES:-240}"      # 8 seconds at 30 fps
OVERLAP_FRAMES="${OVERLAP_FRAMES:-16}" # must be > FlashVSR's per-chunk 7-frame tail loss
PRE_CRF="${PRE_CRF:-14}"
POST_CRF="${POST_CRF:-16}"

mkdir -p "$WORK/chunks" "$WORK/raw_upscaled" "$WORK/cropped" "$WORK/final"

total_frames="$(ffprobe -v error -select_streams v:0 -count_frames \
  -show_entries stream=nb_read_frames -of csv=p=0 "$INPUT")"

if [[ -z "$total_frames" || "$total_frames" == "N/A" ]]; then
  total_frames="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=nb_frames -of csv=p=0 "$INPUT")"
fi

if [[ -z "$total_frames" || "$total_frames" == "N/A" ]]; then
  echo "Could not read frame count from: $INPUT" >&2
  exit 1
fi

# FlashVSR keeps the largest 8n-3 frame count not exceeding the input.
target_frames=$(( ((total_frames + 3) / 8) * 8 - 3 ))

echo "Input frames:  $total_frames"
echo "Target frames: $target_frames"
echo "Work dir:      $WORK"

meta="$WORK/chunks/meta.tsv"
: > "$meta"

idx=0
core_start=0
while (( core_start < target_frames )); do
  core_end=$(( core_start + CORE_FRAMES ))
  if (( core_end > target_frames )); then
    core_end="$target_frames"
  fi

  keep_frames=$(( core_end - core_start ))
  in_start=$(( core_start - OVERLAP_FRAMES ))
  if (( in_start < 0 )); then
    in_start=0
  fi

  in_end=$(( core_end + OVERLAP_FRAMES ))
  if (( in_end > total_frames )); then
    in_end="$total_frames"
  fi

  trim_left=$(( core_start - in_start ))
  chunk="$(printf 'chunk_%03d' "$idx")"

  echo "Make $chunk: input frames [$in_start,$in_end), keep $keep_frames after trim_left=$trim_left"
  ffmpeg -y -nostdin -hide_banner -i "$INPUT" \
    -vf "trim=start_frame=${in_start}:end_frame=${in_end},setpts=PTS-STARTPTS,setsar=1" \
    -an -c:v libx264 -crf "$PRE_CRF" -preset slow -pix_fmt yuv420p \
    "$WORK/chunks/${chunk}.mp4"

  printf '%s\t%s\t%s\n' "$chunk" "$trim_left" "$keep_frames" >> "$meta"

  idx=$(( idx + 1 ))
  core_start="$core_end"
done

cd "$WAN_DIR"
mkdir -p inputs results

if [[ -f "$ENV_SH" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_SH"
  conda activate "$CONDA_ENV"
fi

export TMPDIR="${TMPDIR:-/workspace/tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/cache/pip}"
export HF_HOME="${HF_HOME:-/workspace/cache/hf}"
export TORCH_HOME="${TORCH_HOME:-/workspace/cache/torch}"
export CUDA_HOME="${CUDA_HOME:-${CONDA_PREFIX:-}}"
export PATH="$CUDA_HOME/bin:$PATH"
export PYTHONPATH=/workspace/FlashVSR:${PYTHONPATH:-}
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export TORCH_CUDNN_V8_API_ENABLED=1

while IFS=$'\t' read -r chunk trim_left keep_frames; do
  echo "Run FlashVSR for $chunk"
  rm -f ./inputs/example4.mp4 ./results/FlashVSR_v1.1_Tiny_Long_example4_seed0.mp4
  cp "$WORK/chunks/${chunk}.mp4" ./inputs/example4.mp4

  python infer_flashvsr_v1.1_tiny_long_video.py

  raw="$WORK/raw_upscaled/${chunk}_3840x2176.mp4"
  cp ./results/FlashVSR_v1.1_Tiny_Long_example4_seed0.mp4 "$raw"

  trim_end=$(( trim_left + keep_frames ))
  echo "Trim $chunk: frames [$trim_left,$trim_end)"
  ffmpeg -y -nostdin -hide_banner -i "$raw" \
    -vf "trim=start_frame=${trim_left}:end_frame=${trim_end},setpts=PTS-STARTPTS,crop=3840:2160:0:8,setsar=1" \
    -an -c:v libx264 -crf "$POST_CRF" -preset slow -pix_fmt yuv420p \
    "$WORK/cropped/${chunk}_3840x2160.mp4"
done < "$meta"

list="$WORK/cropped/list.txt"
: > "$list"
for f in "$WORK"/cropped/chunk_*_3840x2160.mp4; do
  printf "file '%s'\n" "$f" >> "$list"
done

ffmpeg -y -nostdin -hide_banner -f concat -safe 0 -i "$list" -c copy \
  "$WORK/final/final_3840x2160_noaudio_overlap_fixed.mp4"

if [[ -f "$AUDIO_SOURCE" ]]; then
  ffmpeg -y -nostdin -hide_banner \
    -i "$WORK/final/final_3840x2160_noaudio_overlap_fixed.mp4" \
    -i "$AUDIO_SOURCE" \
    -map 0:v:0 -map 1:a? \
    -c:v copy -c:a aac -b:a 192k -shortest \
    "$WORK/final/final_3840x2160_audio_overlap_fixed.mp4"

  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,nb_frames,duration \
    -of default=nw=1 \
    "$WORK/final/final_3840x2160_audio_overlap_fixed.mp4"
else
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,nb_frames,duration \
    -of default=nw=1 \
    "$WORK/final/final_3840x2160_noaudio_overlap_fixed.mp4"
fi
