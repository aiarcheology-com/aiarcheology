#!/usr/bin/env bash
#
# Downloads the .onnx fixtures listed in the ONNX conversion test manifest, verifying each file's
# SHA256. Lets `ONNXConversionIntegrationTests` run outside the app with real models without
# committing large binaries to the repo.
#
# Usage:
#   scripts/fetch_native_test_models.sh [TARGET_DIR]
#     TARGET_DIR defaults to .native-model-fixtures/ at the repo root.
#
# Then:
#   NATIVE_MODEL_ONNX_DIRECTORY="<TARGET_DIR>" swift test --filter "ONNXConversionIntegrationTests|YOLOv5TrunkConversionTests|YOLOv8TrunkConversionTests|YOLO11TrunkConversionTests"
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/ONNXConversionModels.json"
TARGET_DIR="${1:-$REPO_ROOT/.native-model-fixtures}"
mkdir -p "$TARGET_DIR"

while IFS=$'\t' read -r fileName url sha256; do
  dest="$TARGET_DIR/$fileName"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | awk '{print $1}')" = "$sha256" ]; then
    echo "✓ $fileName (cached, sha256 ok)"
    continue
  fi
  echo "↓ $fileName"
  curl -fL --retry 3 -o "$dest" "$url"
  actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [ "$actual" != "$sha256" ]; then
    echo "✗ $fileName sha256 mismatch: expected $sha256, got $actual" >&2
    exit 1
  fi
  echo "✓ $fileName (sha256 ok)"
done < <(python3 -c "
import json, sys
seen = {}
def emit(name, url, sha):
    if name in seen:
        # A shared fixture must agree on url + sha256 across sources; a mismatch means one drifted.
        if seen[name] != (url, sha):
            sys.stderr.write('conflicting url/sha256 for shared fixture %s\n' % name)
            sys.exit(1)
        return
    seen[name] = (url, sha)
    print('\t'.join([name, url, sha]))
m = json.load(open('$MANIFEST'))
for x in m['models']:
    emit(x['fileName'], x['url'], x['sha256'])
# The YOLOv8 trunk oracle shares its fixture with the manifest's s1777 detection entry (AIA-0469
# PR 2 added the image probes); dedupe by fileName so the shared model is fetched once.
for oracle_path in [
    '$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/YOLOv5TrunkOracle.json',
    '$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/YOLOv8TrunkOracle.json',
    '$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/YOLO11TrunkOracle.json',
]:
    o = json.load(open(oracle_path))
    emit(o['fileName'], o['url'], o['sha256'])
")

echo ""
echo "Fixtures ready in: $TARGET_DIR"
echo "Run: NATIVE_MODEL_ONNX_DIRECTORY=\"$TARGET_DIR\" swift test --filter \"ONNXConversionIntegrationTests|YOLOv5TrunkConversionTests|YOLOv8TrunkConversionTests|YOLO11TrunkConversionTests\""
