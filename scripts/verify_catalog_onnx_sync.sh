#!/bin/bash
#
# verify_catalog_onnx_sync.sh — AIA-0497
#
# Every ONNX model the catalog advertises as verified (in the curated
# ONNXModelZooCatalogProvider) must be backed by an oracle-verified entry in the converter test
# fixtures. This fails CI if the catalog drifts away from the oracle — a listed model with no
# fixture, or a fixture URL the catalog renamed — so the catalog cannot silently claim a model is
# verified after it stopped being tested.
#
# Scope, stated honestly: this proves the catalog list and the verified set stay in sync *by URL*.
# It does NOT run conversion — the only test that actually converts these models
# (ONNXConversionIntegrationTests) is skipped unless NATIVE_MODEL_ONNX_DIRECTORY and the model files
# are present, which no CI job sets today. Wiring CI to fetch models and run the oracle is a
# separate ticket.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVIDER="$REPO_ROOT/ios/MLBrowser/iOS/Services/Catalog/ONNXModelZooCatalogProvider.swift"
FIXTURE="$REPO_ROOT/Tests/NativeModelConverterTests/Fixtures/ONNXConversionModels.json"

for path in "$PROVIDER" "$FIXTURE"; do
	if [[ ! -f "$path" ]]; then
		echo "verify_catalog_onnx_sync: required file not found: $path" >&2
		exit 1
	fi
done

# Extract .onnx URLs from both files. Portable (no jq dependency): the provider stores them as string
# literals and the fixture as JSON "url" values, both ending in .onnx.
extract_onnx_urls() { grep -oE 'https://[^" ]+\.onnx' "$1" | sort -u; }

catalog_urls="$(extract_onnx_urls "$PROVIDER")"
fixture_urls="$(extract_onnx_urls "$FIXTURE")"

if [[ -z "$catalog_urls" ]]; then
	echo "verify_catalog_onnx_sync: no ONNX URLs found in $PROVIDER (did the provider move?)" >&2
	exit 1
fi

status=0
while IFS= read -r url; do
	if ! grep -qxF "$url" <<<"$fixture_urls"; then
		echo "❌ Catalog advertises an ONNX model that is not oracle-verified in the fixture:" >&2
		echo "     $url" >&2
		echo "   Add it to $FIXTURE (URL + SHA256 + expected outputs) or remove it from the catalog." >&2
		status=1
	fi
done <<<"$catalog_urls"

if [[ $status -eq 0 ]]; then
	count="$(printf '%s\n' "$catalog_urls" | grep -c .)"
	echo "✅ All $count catalog verified-ONNX entries are backed by an oracle fixture."
fi

exit $status
