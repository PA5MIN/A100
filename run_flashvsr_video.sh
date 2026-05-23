#!/usr/bin/env bash
set -euo pipefail

# Daily runner for FlashVSR on the restored VastAI A100 environment.
# Default command:
#   bash run_flashvsr_video.sh
# Put one or more videos in /workspace/flashvsr_jobs/input first.

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
WAN_DIR="${WAN_DIR:-$WORKSPACE_DIR/FlashVSR/examples/WanVSR}"
ENV_FILE="${ENV_FILE:-$WORKSPACE_DIR/flashvsr_env.sh}"

INPUT_DIR="${INPUT_DIR:-$WORKSPACE_DIR/flashvsr_jobs/input}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORKSPACE_DIR/flashvsr_jobs/output}"
WORK_ROOT="${WORK_ROOT:-$WORKSPACE_DIR/flashvsr_jobs/work}"

FPS="${FPS:-keep}"                      # keep does not add an fps filter
CORE_FRAMES="${CORE_FRAMES:-240}"       # chunk size in frames
OVERLAP_FRAMES="${OVERLAP_FRAMES:-16}"  # avoids FlashVSR 8n-3 seam loss
PRE_CRF="${PRE_CRF:-14}"
POST_CRF="${POST_CRF:-16}"
TARGET_SMALL_W="${TARGET_SMALL_W:-960}"
TARGET_CONTENT_H="${TARGET_CONTENT_H:-540}"
TARGET_PADDED_H="${TARGET_PADDED_H:-544}"
PAD_TOP="${PAD_TOP:-2}"
FINAL_CROP_Y="${FINAL_CROP_Y:-8}"
FFMPEG_INPUT_OPTS="${FFMPEG_INPUT_OPTS:--noautorotate}"
PORTRAIT_ROTATE_FILTER="${PORTRAIT_ROTATE_FILTER:-transpose=1}"

# By default the script auto-detects portrait vs landscape input.
# For 1080x1920 portrait:
#   rotate -> 1920x1080 -> scale 960x540 -> pad to 960x544.
# For 1088x1920 portrait:
#   rotate -> 1920x1088 -> scale 960x544.
# Override only when a specific source needs custom handling.
PREPROCESS_FILTER="${PREPROCESS_FILTER:-}"

usage() {
  cat <<EOF
Usage:
  bash run_flashvsr_video.sh [video ...]

Default:
  Put .mp4/.mov/.mkv/.webm files into:
    $INPUT_DIR
  Then run:
    bash run_flashvsr_video.sh

Output:
  $OUTPUT_DIR/<name>_3840x2160_flashvsr.mp4

Useful overrides:
  INPUT_DIR=/workspace/in OUTPUT_DIR=/workspace/out bash run_flashvsr_video.sh
  PREPROCESS_FILTER='transpose=1,scale=960:544:flags=area,setsar=1' bash run_flashvsr_video.sh
  FPS=30 bash run_flashvsr_video.sh
  FFMPEG_INPUT_OPTS='' bash run_flashvsr_video.sh
  PORTRAIT_ROTATE_FILTER=transpose=2 bash run_flashvsr_video.sh
  CORE_FRAMES=180 OVERLAP_FRAMES=24 bash run_flashvsr_video.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

safe_name() {
  local name="$1"
  name="${name%.*}"
  echo "$name" | tr ' /:()[]{}' '_________' | tr -cd 'A-Za-z0-9._-'
}

read_frame_count() {
  local file="$1"
  local frames
  frames="$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames -of csv=p=0 "$file" || true)"

  if [[ -z "$frames" || "$frames" == "N/A" ]]; then
    frames="$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=nb_frames -of csv=p=0 "$file" || true)"
  fi

  if [[ -z "$frames" || "$frames" == "N/A" ]]; then
    echo "Could not read frame count from: $file" >&2
    return 1
  fi

  echo "$frames"
}

read_video_size() {
  local file="$1"
  local size

  size="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=s=x:p=0 "$file" | head -n 1 || true)"

  if [[ ! "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "Could not read video size from: $file" >&2
    return 1
  fi

  echo "$size"
}

read_video_fps() {
  local file="$1"
  local fps

  fps="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate -of csv=p=0 "$file" | head -n 1 || true)"

  if [[ -z "$fps" || "$fps" == "0/0" || "$fps" == "N/A" ]]; then
    fps="$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=r_frame_rate -of csv=p=0 "$file" | head -n 1 || true)"
  fi

  if [[ -z "$fps" || "$fps" == "0/0" || "$fps" == "N/A" ]]; then
    echo "30"
  else
    echo "$fps"
  fi
}

fps_prefix() {
  local file="$1"
  local target_fps

  case "$FPS" in
    keep|none|passthrough|source|auto)
      echo ""
      ;;
    *)
      target_fps="$FPS"
      echo "fps=${target_fps},"
      ;;
  esac
}

build_preprocess_filter() {
  local file="$1"
  local size width height work_w work_h prefix fit_filter

  if [[ -n "$PREPROCESS_FILTER" ]]; then
    echo "$PREPROCESS_FILTER"
    return
  fi

  size="$(read_video_size "$file")"
  width="${size%x*}"
  height="${size#*x}"
  prefix="$(fps_prefix "$file")"

  if (( height > width )); then
    work_w="$height"
    work_h="$width"
  else
    work_w="$width"
    work_h="$height"
  fi

  if (( work_w * TARGET_PADDED_H == work_h * TARGET_SMALL_W )); then
    fit_filter="scale=${TARGET_SMALL_W}:${TARGET_PADDED_H}:flags=area,setsar=1"
  elif (( work_w * TARGET_CONTENT_H == work_h * TARGET_SMALL_W )); then
    fit_filter="scale=${TARGET_SMALL_W}:${TARGET_CONTENT_H}:flags=area,pad=${TARGET_SMALL_W}:${TARGET_PADDED_H}:0:${PAD_TOP},setsar=1"
  else
    fit_filter="scale=${TARGET_SMALL_W}:${TARGET_CONTENT_H}:force_original_aspect_ratio=increase:flags=area,crop=${TARGET_SMALL_W}:${TARGET_CONTENT_H},pad=${TARGET_SMALL_W}:${TARGET_PADDED_H}:0:${PAD_TOP},setsar=1"
  fi

  if (( height > width )); then
    echo "${prefix}${PORTRAIT_ROTATE_FILTER},${fit_filter}"
  else
    echo "${prefix}${fit_filter}"
  fi
}

describe_preprocess() {
  local file="$1"
  local size width height work_w work_h fps_note scale_note

  size="$(read_video_size "$file")"
  width="${size%x*}"
  height="${size#*x}"

  if (( height > width )); then
    work_w="$height"
    work_h="$width"
  else
    work_w="$width"
    work_h="$height"
  fi

  case "$FPS" in
    keep|none|passthrough|source|auto)
      fps_note="keep source frame timing; no fps filter"
      ;;
    *)
      fps_note="convert to ${FPS} fps"
      ;;
  esac

  if (( work_w * TARGET_PADDED_H == work_h * TARGET_SMALL_W )); then
    scale_note="direct scale to ${TARGET_SMALL_W}x${TARGET_PADDED_H}"
  elif (( work_w * TARGET_CONTENT_H == work_h * TARGET_SMALL_W )); then
    scale_note="scale to ${TARGET_SMALL_W}x${TARGET_CONTENT_H}, then pad to ${TARGET_SMALL_W}x${TARGET_PADDED_H}"
  else
    scale_note="fit/crop to ${TARGET_SMALL_W}x${TARGET_CONTENT_H}, then pad to ${TARGET_SMALL_W}x${TARGET_PADDED_H}"
  fi

  if (( height > width )); then
    echo "Detected portrait ${width}x${height}: rotate with ${PORTRAIT_ROTATE_FILTER}, then ${scale_note}."
  else
    echo "Detected landscape/square ${width}x${height}: ${scale_note}."
  fi
  echo "Frame rate: ${fps_note}"
}

make_chunk_meta_and_inputs() {
  local preprocessed="$1"
  local chunks_dir="$2"
  local meta="$3"
  local total_frames target_frames idx core_start

  total_frames="$(read_frame_count "$preprocessed")"
  target_frames=$(( ((total_frames + 3) / 8) * 8 - 3 ))

  echo "Preprocessed frames: $total_frames"
  echo "FlashVSR target:     $target_frames"

  : > "$meta"
  idx=0
  core_start=0

  while (( core_start < target_frames )); do
    local core_end keep_frames in_start in_end trim_left chunk

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

    echo "Create $chunk: input frames [$in_start,$in_end), keep $keep_frames, trim_left $trim_left"
    ffmpeg -y -nostdin -hide_banner -i "$preprocessed" \
      -vf "trim=start_frame=${in_start}:end_frame=${in_end},setpts=PTS-STARTPTS,setsar=1" \
      -an -c:v libx264 -crf "$PRE_CRF" -preset slow -pix_fmt yuv420p \
      "$chunks_dir/${chunk}.mp4"

    printf '%s\t%s\t%s\n' "$chunk" "$trim_left" "$keep_frames" >> "$meta"

    idx=$(( idx + 1 ))
    core_start="$core_end"
  done
}

run_one_video() {
  local src="$1"
  local base job_id job_dir preprocessed meta list out_noaudio out_audio preprocess_filter

  if [[ ! -f "$src" ]]; then
    echo "Input not found: $src" >&2
    return 1
  fi

  base="$(safe_name "$(basename "$src")")"
  if [[ -z "$base" ]]; then
    base="video"
  fi
  job_id="$(date +%Y%m%d_%H%M%S)_${base}"
  job_dir="$WORK_ROOT/$job_id"
  preprocessed="$job_dir/preprocessed_960x544.mp4"
  meta="$job_dir/chunks/meta.tsv"
  list="$job_dir/cropped/list.txt"
  out_noaudio="$job_dir/final/${base}_3840x2160_flashvsr_noaudio.mp4"
  out_audio="$OUTPUT_DIR/${base}_3840x2160_flashvsr.mp4"

  mkdir -p "$job_dir/chunks" "$job_dir/raw_upscaled" "$job_dir/cropped" "$job_dir/final" "$OUTPUT_DIR"

  echo
  echo "============================================================"
  echo "Input:  $src"
  echo "Job:    $job_dir"
  echo "Output: $out_audio"
  echo "============================================================"

  echo
  echo "== Preprocess to 960x544 =="
  describe_preprocess "$src"
  preprocess_filter="$(build_preprocess_filter "$src")"
  echo "Filter: $preprocess_filter"
  ffmpeg -y -nostdin -hide_banner \
    ${FFMPEG_INPUT_OPTS:+$FFMPEG_INPUT_OPTS} \
    -i "$src" \
    -vf "$preprocess_filter" \
    -an -c:v libx264 -crf "$PRE_CRF" -preset slow -pix_fmt yuv420p \
    "$preprocessed"

  echo
  echo "== Create overlapped chunks =="
  make_chunk_meta_and_inputs "$preprocessed" "$job_dir/chunks" "$meta"

  echo
  echo "== Run FlashVSR chunks =="
  cd "$WAN_DIR"
  mkdir -p inputs results

  while IFS=$'\t' read -r chunk trim_left keep_frames; do
    local raw trim_end raw_frames

    echo
    echo "-- FlashVSR $chunk --"
    rm -f ./inputs/example4.mp4 ./results/FlashVSR_v1.1_Tiny_Long_example4_seed0.mp4
    cp "$job_dir/chunks/${chunk}.mp4" ./inputs/example4.mp4

    python infer_flashvsr_v1.1_tiny_long_video.py

    raw="$job_dir/raw_upscaled/${chunk}_3840x2176.mp4"
    cp ./results/FlashVSR_v1.1_Tiny_Long_example4_seed0.mp4 "$raw"

    trim_end=$(( trim_left + keep_frames ))
    raw_frames="$(read_frame_count "$raw")"
    if (( raw_frames < trim_end )); then
      echo "Chunk $chunk produced only $raw_frames frames, need $trim_end." >&2
      echo "Try increasing OVERLAP_FRAMES, for example: OVERLAP_FRAMES=24 bash run_flashvsr_video.sh ..." >&2
      exit 1
    fi

    echo "Trim $chunk: frames [$trim_left,$trim_end), crop 3840x2160"
    ffmpeg -y -nostdin -hide_banner -i "$raw" \
      -vf "trim=start_frame=${trim_left}:end_frame=${trim_end},setpts=PTS-STARTPTS,crop=3840:2160:0:${FINAL_CROP_Y},setsar=1" \
      -an -c:v libx264 -crf "$POST_CRF" -preset slow -pix_fmt yuv420p \
      "$job_dir/cropped/${chunk}_3840x2160.mp4"
  done < "$meta"

  echo
  echo "== Concatenate chunks =="
  : > "$list"
  for f in "$job_dir"/cropped/chunk_*_3840x2160.mp4; do
    printf "file '%s'\n" "$f" >> "$list"
  done

  ffmpeg -y -nostdin -hide_banner -f concat -safe 0 -i "$list" -c copy "$out_noaudio"

  echo
  echo "== Merge original audio =="
  ffmpeg -y -nostdin -hide_banner \
    -i "$out_noaudio" \
    -i "$src" \
    -map 0:v:0 -map 1:a? \
    -c:v copy -c:a aac -b:a 192k -shortest \
    "$out_audio"

  echo
  echo "== Final probe =="
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,nb_frames,duration \
    -of default=nw=1 "$out_audio"

  echo
  echo "DONE: $out_audio"
}

need_cmd ffmpeg
need_cmd ffprobe

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Runtime env file not found: $ENV_FILE" >&2
  echo "Run vastai_setup_flashvsr.sh first." >&2
  exit 1
fi

if [[ ! -d "$WAN_DIR" ]]; then
  echo "FlashVSR WanVSR directory not found: $WAN_DIR" >&2
  echo "Run vastai_setup_flashvsr.sh first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$WORK_ROOT"

declare -a inputs=()
if (( "$#" > 0 )); then
  inputs=("$@")
else
  while IFS= read -r file; do
    inputs+=("$file")
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f \( \
    -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' \
  \) | sort)
fi

if (( "${#inputs[@]}" == 0 )); then
  echo "No videos found."
  echo "Put videos in: $INPUT_DIR"
  echo "Then run: bash run_flashvsr_video.sh"
  exit 1
fi

for video in "${inputs[@]}"; do
  run_one_video "$video"
done
