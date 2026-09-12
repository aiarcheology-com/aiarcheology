#!/bin/zsh

set -euo pipefail

reference_directory="$(mktemp -d "${TMPDIR:-/tmp}/native-model-converter-references.XXXXXX")"
trap 'rm -rf "$reference_directory"' EXIT

download_reference() {
	local file_name="$1"
	local url="$2"
	local checksum="$3"

	curl --fail --location --silent --show-error --output "$reference_directory/$file_name" "$url"
	echo "$checksum  $reference_directory/$file_name" | shasum -a 256 -c -
}

download_reference \
	"MobileNetV2Int8LUT.mlmodel" \
	"https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2Int8LUT.mlmodel" \
	"ee53bca4c5042d77aed5c093cba31c2ef229d1cc4c027300af9cc8bf9e240409"
download_reference \
	"MobileNetV2FP16.mlmodel" \
	"https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2FP16.mlmodel" \
	"c76832208ff4c936365f0f2609f7b77f7f1a6caf62b0b429056d5ad7e48635ad"

NATIVE_MODEL_REFERENCE_DIRECTORY="$reference_directory" swift test
