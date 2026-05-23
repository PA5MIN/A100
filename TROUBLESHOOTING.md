# Troubleshooting Notes

These are the issues found during the first real VastAI restore and run.

## 1. Use Enough Disk

Do not use a 32G VastAI root disk for the normal restore path.

The GitHub Release split files are about 18G compressed, and the restored
environment also needs tens of GB.

Recommended:

```text
Disk: 100G minimum
Better: 150G
GPU: A100/A800 sm80
```

If the machine has only 32G disk, the restore may fail with:

```text
No space left on device
tar: Wrote only ... bytes
```

Use a bigger disk. `/dev/shm` can be used as a temporary memory-disk workaround,
but it disappears when the instance stops.

## 2. Private Release Download

If the release is private, raw `curl` URLs can return:

```text
curl: (22) The requested URL returned error: 404
```

Fix:

```bash
gh auth login
bash /workspace/A100/vastai_setup_flashvsr.sh
```

The setup script now detects `gh auth login` and uses `gh release download`.

## 3. Do Not Use A Broken Merged tar.zst

If extraction fails with:

```text
premature end
Unexpected EOF in archive
```

Check split files:

```bash
cd /workspace/restore_flashvsr
sha256sum -c SHA256SUMS.txt
```

If all split files are `OK`, delete the broken merged file and stream extract:

```bash
rm -f /workspace/restore_flashvsr/flashvsr_a100_cu128_sm80.tar.zst

cat /workspace/restore_flashvsr/flashvsr_a100_cu128_sm80.tar.zst.part-* \
| zstd -d -c \
| tar -xf - -C /workspace
```

## 4. Conda Activation `NVCC_PREPEND_FLAGS`

If activation fails with:

```text
NVCC_PREPEND_FLAGS: unbound variable
```

Use the latest `vastai_setup_flashvsr.sh`. The generated `/workspace/flashvsr_env.sh`
does not use `set -u`, because CUDA conda activation scripts may reference
unset variables.

## 5. Only First Chunk Ran

If the output is only 4 seconds and logs show:

```text
Enter command: <target>|all <time>|-1 <command>
Parse error ... string 'chunk_001 ...'
```

Then `ffmpeg` consumed the chunk metadata from stdin. The runner now uses
`ffmpeg -nostdin` for every ffmpeg call.

Update:

```bash
cd /workspace/A100
git pull
```

## 6. Source Video Has Decode Errors

If preprocessing logs many messages like:

```text
Invalid NAL unit size
Error splitting the input into NAL units
corrupt decoded frame
```

The source video is damaged or partially corrupted. FlashVSR can still run on
the decodable frames, but the final duration may be shorter than the container
duration.

Example observed:

```text
source container duration: 24.27s
preprocessed/final duration: about 22.75s
```

This is an input-file issue, not an A100 or FlashVSR restore issue.

## 7. Audio Decode Warnings

If final audio merge logs many AAC warnings like:

```text
Number of bands exceeds limit
channel element is not allocated
Invalid data found when processing input
```

The source audio stream also has damaged packets. The current runner may still
produce a playable output. If audio sounds wrong, use the no-audio intermediate:

```text
/workspace/flashvsr_jobs/work/<job>/final/<name>_3840x2160_flashvsr_noaudio.mp4
```

Then remux or replace audio from a clean source.

## 8. Expected Successful Output

A successful run ends with something like:

```text
DONE: /workspace/flashvsr_jobs/output/input_3840x2160_flashvsr.mp4
width=3840
height=2160
r_frame_rate=60/1
duration=22.750000
nb_frames=1365
```
