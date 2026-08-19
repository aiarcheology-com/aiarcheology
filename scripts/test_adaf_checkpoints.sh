#!/usr/bin/env bash
#
# Runs the gated ADAF checkpoint suite and fails when it did not actually run.
#
# Usage:
#   scripts/test_adaf_checkpoints.sh [TARGET_DIR]
#     TARGET_DIR defaults to .adaf-checkpoints/ at the repo root, fetched by
#     scripts/fetch_adaf_checkpoints.sh.
#
# This wrapper exists because of the failure mode ios/AGENTS.md §13 warns about for the other two
# fixture gates: an environment-gated suite *skips* when its fixtures are absent, and the run still
# reports success. A green `swift test` therefore says nothing about whether the real files were
# ever opened. So this asserts three things the test runner will not: that the directory exists,
# that every expected test executed, and that none of them skipped.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-$REPO_ROOT/.adaf-checkpoints}"
MANIFEST="$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/ADAF/ADAFCheckpointFixtures.json"

if [ ! -d "$TARGET_DIR" ]; then
  echo "✗ $TARGET_DIR does not exist. Run scripts/fetch_adaf_checkpoints.sh first." >&2
  exit 1
fi

expected="$(python3 -c "
import json
print(len(json.load(open('$MANIFEST'))['models']))
")"

missing=0
while IFS= read -r fileName; do
  if [ ! -f "$TARGET_DIR/$fileName" ]; then
    echo "✗ missing fixture: $fileName" >&2
    missing=1
  fi
done < <(python3 -c "
import json
for model in json.load(open('$MANIFEST'))['models']:
    print(model['fileName'])
")
[ "$missing" = "0" ] || { echo "Run scripts/fetch_adaf_checkpoints.sh first." >&2; exit 1; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

set +e
ADAF_CHECKPOINT_DIRECTORY="$TARGET_DIR" swift test --filter ADAFCheckpointDirectoryTests 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"
set -e

# `swift test` prints "Test Case" and xcodebuild prints "Test case"; match either, because getting
# this wrong makes the guard report zero and is indistinguishable from the failure it exists to
# catch. (It did exactly that on first run.)
executed="$(grep -ciE "Test Case '.*' passed" "$log" || true)"
skipped="$(grep -ciE "Test Case '.*' skipped" "$log" || true)"

echo
echo "fixtures required: $expected | tests executed: $executed | skipped: $skipped"

if [ "$status" != "0" ]; then
  echo "✗ the gated suite failed" >&2
  exit "$status"
fi
if [ "$skipped" != "0" ]; then
  echo "✗ $skipped test(s) skipped — the gate did not actually run" >&2
  exit 1
fi
# Requiring "at least one test" is not enough: if one of the two stops being discovered, the other
# still runs and the script reports success while a whole family of fixtures goes unopened. Name
# them, so a disappearing test is a failure rather than a quieter pass.
required_tests=(
  test_everyPublishedCheckpoint_isReadAndIdentified
  test_theFourDetectionCheckpoints_shareOneTensorTable
)
for name in "${required_tests[@]}"; do
  if ! grep -qE "Test Case '.*${name}.*' passed" "$log"; then
    echo "✗ $name did not run — the gate did not cover what it claims to" >&2
    exit 1
  fi
done
echo "✓ gated ADAF suite ran ${#required_tests[@]} named tests against $expected real checkpoints, nothing skipped"
