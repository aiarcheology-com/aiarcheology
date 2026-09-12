#!/usr/bin/env bash
#
# Fetches the published ADAF checkpoints listed in the fixture manifest, so the gated suite
# (ADAFCheckpointDirectoryTests) can run the PyTorch checkpoint reader against files this repository
# did not produce.
#
# Usage:
#   scripts/fetch_adaf_checkpoints.sh [--full] [TARGET_DIR]
#     TARGET_DIR defaults to .adaf-checkpoints/ at the repo root.
#     --full downloads whole files (~4.6 GB). Without it, each file is reconstructed sparsely.
#
# Then:
#   ADAF_CHECKPOINT_DIRECTORY="<TARGET_DIR>" swift test --filter ADAFCheckpointDirectoryTests
#   (or just run scripts/test_adaf_checkpoints.sh, which also fails when fixtures are missing)
#
# Sparse by default, and that is not a shortcut. The reader's entire read set is the archive's end
# records, its central directory, `data.pkl` and `version` — all of which live in the first 640 KB
# and the last 512 KB of the file. Fetching those two ranges (Zenodo serves HTTP 206) and writing
# them at their true offsets into a file of the true length produces something byte-identical to the
# original everywhere the reader looks, for ~9 MB of disk instead of ~518 MB. The middle is a hole,
# so any code that starts reading weight bytes gets zeros rather than silently plausible data —
# which is why `--full` exists and why the manifest records whether a copy is sparse.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/ADAF/ADAFCheckpointFixtures.json"

FULL=0
TARGET_DIR=""
for argument in "$@"; do
  case "$argument" in
    --full) FULL=1 ;;
    *) TARGET_DIR="$argument" ;;
  esac
done
TARGET_DIR="${TARGET_DIR:-$REPO_ROOT/.adaf-checkpoints}"
mkdir -p "$TARGET_DIR"

# Head and tail spans, generous enough for the largest published `data.pkl` (621,064 bytes) and
# central directory (419,501 bytes) with room to spare.
HEAD_BYTES=$((1024 * 1024))
TAIL_BYTES=$((1024 * 1024))

while IFS=$'\t' read -r id fileName url totalLength md5; do
  dest="$TARGET_DIR/$fileName"
  marker="$TARGET_DIR/.$fileName.sparse"

  if [ -f "$dest" ]; then
    actualSize="$(stat -f%z "$dest" 2>/dev/null || stat -c%s "$dest")"
    if [ "$actualSize" = "$totalLength" ]; then
      if [ "$FULL" = "1" ] && [ -f "$marker" ]; then
        echo "↻ $fileName (cached copy is sparse, --full requested)"
      elif [ "$FULL" = "1" ]; then
        actualMD5="$(md5 -q "$dest" 2>/dev/null || md5sum "$dest" | awk '{print $1}')"
        if [ "$actualMD5" = "$md5" ]; then echo "✓ $fileName (cached, md5 ok)"; continue; fi
        echo "↻ $fileName (cached md5 mismatch)"
      else
        echo "✓ $fileName (cached)"; continue
      fi
    fi
  fi

  if [ "$FULL" = "1" ]; then
    echo "↓ $fileName (whole file, $totalLength bytes)"
    curl -fL --retry 3 -o "$dest" "$url"
    actualMD5="$(md5 -q "$dest" 2>/dev/null || md5sum "$dest" | awk '{print $1}')"
    if [ "$actualMD5" != "$md5" ]; then
      echo "✗ $fileName md5 mismatch: expected $md5, got $actualMD5" >&2
      exit 1
    fi
    rm -f "$marker"
    echo "✓ $fileName (md5 ok)"
  else
    echo "↓ $fileName (head + tail, sparse)"
    tailStart=$((totalLength - TAIL_BYTES))
    curl -fL --retry 3 -r "0-$((HEAD_BYTES - 1))" -o "$dest.head" "$url"
    curl -fL --retry 3 -r "$tailStart-$((totalLength - 1))" -o "$dest.tail" "$url"
    python3 - "$dest" "$dest.head" "$dest.tail" "$totalLength" "$tailStart" <<'PY'
import sys
dest, head, tail, total, tail_start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
with open(dest, "wb") as out:
    out.write(open(head, "rb").read())
    out.truncate(total)
    out.seek(tail_start)
    out.write(open(tail, "rb").read())
PY
    rm -f "$dest.head" "$dest.tail"
    : > "$marker"
    echo "✓ $fileName (sparse; run with --full for whole-file bytes)"
  fi
done < <(python3 -c "
import json
manifest = json.load(open('$MANIFEST'))
for model in manifest['models']:
    print('\t'.join([model['id'], model['fileName'], model['url'],
                     str(model['totalLength']), model['md5']]))
")

echo
echo "Fetched into $TARGET_DIR"
echo "Run:  ADAF_CHECKPOINT_DIRECTORY=\"$TARGET_DIR\" swift test --filter ADAFCheckpointDirectoryTests"
