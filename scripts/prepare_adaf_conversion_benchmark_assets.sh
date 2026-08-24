#!/usr/bin/env bash
# Stages the local-only dense ADAF checkpoint for the physical-iPhone conversion benchmark.
#
# Usage:
#   scripts/prepare_adaf_conversion_benchmark_assets.sh [CHECKPOINT_DIR] [OUTPUT_DIR]
#
# Build with:
#   AIA_ADAF_CONVERSION_BENCHMARK_ASSETS="$PWD/.adaf-conversion-benchmark-assets" \
#     ADAF_CONVERSION_DEVICE_BENCHMARK=1 xcodebuild test ...

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checkpoint_directory="${1:-$repository_root/.adaf-checkpoints}"
output_directory="${2:-$repository_root/.adaf-conversion-benchmark-assets}"
checkpoint="$checkpoint_directory/OD_ringfort.tar"
staged_checkpoint="$output_directory/OD_ringfort.tar"
expected_size=517823445
expected_md5=4518e1966cafa0544bd3ea78be3b711a

if [[ ! -f "$checkpoint" ]]; then
	echo "Missing dense ADAF checkpoint: $checkpoint" >&2
	exit 1
fi

actual_size="$(stat -f '%z' "$checkpoint")"
actual_md5="$(md5 -q "$checkpoint")"
if [[ "$actual_size" != "$expected_size" || "$actual_md5" != "$expected_md5" ]]; then
	echo "OD_ringfort.tar did not match the required dense benchmark fixture." >&2
	echo "Expected: $expected_size bytes, MD5 $expected_md5" >&2
	echo "Actual:   $actual_size bytes, MD5 $actual_md5" >&2
	exit 1
fi

mkdir -p "$output_directory"
if [[ "$checkpoint" != "$staged_checkpoint" ]]; then
	cp "$checkpoint" "$staged_checkpoint"
fi

echo "Prepared $staged_checkpoint"
