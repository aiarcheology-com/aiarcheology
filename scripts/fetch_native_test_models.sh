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
#   NATIVE_MODEL_ONNX_DIRECTORY="<TARGET_DIR>" swift test --filter ONNXConversionIntegrationTests
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
m = json.load(open('$MANIFEST'))
for x in m['models']:
    print('\t'.join([x['fileName'], x['url'], x['sha256']]))
")

echo ""
echo "Fixtures ready in: $TARGET_DIR"
echo "Run: NATIVE_MODEL_ONNX_DIRECTORY=\"$TARGET_DIR\" swift test --filter ONNXConversionIntegrationTests"
