#!/usr/bin/env bash
# Builds the local-only fixture consumed by ADAFDetectorDeviceParityTests on a physical iPhone.
# The generated model is deliberately ignored: the artifact is about 191 MiB.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checkpoint_directory="${1:-$repo_root/.adaf-checkpoints}"
output_directory="${2:-$repo_root/.adaf-device-parity-assets}"
python="${ADAF_PARITY_PYTHON:-$repo_root/.venv-m3a/bin/python}"
checkpoint="$checkpoint_directory/OD_AO.tar"
figure="$repo_root/scripts/m3a_parity_spike/results/figures/barrows.jpg"

for required in "$python" "$checkpoint" "$figure"; do
	if [[ ! -e "$required" ]]; then
		echo "Missing required device-parity input: $required" >&2
		exit 1
	fi
done

mkdir -p "$output_directory"
rm -rf \
	"$output_directory/AOBarrowDetector.mlmodel" \
	"$output_directory/AOBarrowDetector.mlmodelc" \
	"$output_directory/AOBarrowCanvas.ppm" \
	"$output_directory/AOBarrowOracle.json" \
	"$output_directory/AOBarrowSource.ppm"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/aia-0688-device-parity.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

report="$temporary_directory/torchvision-parity.json"
candidate="$temporary_directory/candidate.json"

PYTHONPATH="$repo_root/scripts/m3a_parity_spike" "$python" \
	"$repo_root/scripts/test_adaf_fasterrcnn_parity.py" \
	--model OD_AO \
	--report "$report"

swift run --package-path "$repo_root" adaf-detector-parity-runner \
	--source-rgb "$output_directory/AOBarrowSource.ppm" \
	--canvas-rgb "$output_directory/AOBarrowCanvas.ppm" \
	--model-output "$output_directory/AOBarrowDetector.mlmodel" \
	--compiled-model-output "$output_directory/AOBarrowDetector.mlmodelc" \
	"$checkpoint" \
	"$candidate" \
	"$figure"

jq -n \
	--slurpfile report "$report" \
	--slurpfile candidate "$candidate" \
	'
		($report[0].results[] | select(.model == "OD_AO" and (.figure | endswith("/barrows.jpg")))) as $comparison |
		$candidate[0].images[0] as $image |
		{
			fixture: "AIA-0688 AO Barrow device parity",
			sourceSize: $image.sourceSize,
			canvasSize: $image.canvasSize,
			reference: $comparison.reference,
			rule: $report[0].rule
		}
	' > "$output_directory/AOBarrowOracle.json"

echo "Prepared device-parity assets in $output_directory"
