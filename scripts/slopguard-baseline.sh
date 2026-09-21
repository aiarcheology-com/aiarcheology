#!/bin/bash
#
# Reproduce the weighted-CRAP baseline for AIA-0901.
#
#   ./scripts/slopguard-baseline.sh complexity
#   ./scripts/slopguard-baseline.sh collect-app
#   ./scripts/slopguard-baseline.sh collect-tools
#   ./scripts/slopguard-baseline.sh collect-converter
#   ./scripts/slopguard-baseline.sh report
#
# `report` reads build/slopguard artifacts and writes specification/weighted-crap/.
# It refuses to publish until app, converter, and tool coverage exports exist.
# SlopGuard itself is not a repository dependency. Set SLOPGUARD_DIR when the
# checkout is not ~/Development/SlopGuard-Swift. The checkout must be the pinned
# revision; this script does not build or update it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOPGUARD_DIR="${SLOPGUARD_DIR:-${HOME}/Development/SlopGuard-Swift}"
ANALYZER_PIN="70245e434a271d6ce95a62976d67f7a14f9f298c"
OUT="${REPO_ROOT}/build/slopguard"
PUBLISHED="${REPO_ROOT}/specification/weighted-crap"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

usage() {
    echo "Usage: $0 {complexity|collect-app|collect-tools|collect-converter|report}" >&2
    exit 2
}

require_analyzer() {
    if [[ ! -x "${SLOPGUARD_DIR}/slopguard-swift" ]]; then
        echo "slopguard-swift is not executable at ${SLOPGUARD_DIR}/slopguard-swift" >&2
        exit 1
    fi
    local revision
    revision="$(git -C "${SLOPGUARD_DIR}" rev-parse HEAD)"
    if [[ "${revision}" != "${ANALYZER_PIN}" ]]; then
        echo "SlopGuard checkout ${revision} is not the pinned ${ANALYZER_PIN}" >&2
        exit 1
    fi
}

pick_simulator() {
    local sdk_version
    sdk_version="$(xcodebuild -version -sdk iphonesimulator SDKVersion 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "${sdk_version}" ]]; then
        echo "Could not read the iOS Simulator SDK from ${DEVELOPER_DIR}" >&2
        exit 1
    fi
    xcrun simctl list devices available -j | SDK_VERSION="${sdk_version}" python3 -c '
import json, os, re, sys
def parse(text):
    parts = re.findall(r"\d+", text)
    return tuple(int(p) for p in parts[:2]) if parts else None
cap = parse(os.environ["SDK_VERSION"])
if cap is None:
    sys.exit(1)
if len(cap) == 1:
    cap = (cap[0], 0)
data = json.load(sys.stdin)
best = None
for runtime, devices in data.get("devices", {}).items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if version > cap:
        continue
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            if best is None or version > best[0]:
                best = (version, device["udid"])
if best is None:
    sys.exit(1)
print(best[1])
'
}

export_llvm() {
    local build_dir="$1"
    local destination="$2"
    local profdata product
    profdata="$(find "${build_dir}" -name default.profdata -path '*codecov*' | head -1)"
    if [[ -z "${profdata}" ]]; then
        echo "Could not find a codecov profile under ${build_dir}" >&2
        exit 1
    fi
    product="$(cd "$(dirname "${profdata}")/.." && pwd)"
    local bins=()
    while IFS= read -r bin; do
        bins+=("${bin}")
    done < <(find "${product}" -type f -path '*.xctest/Contents/MacOS/*' ! -path '*.dSYM/*')
    if [[ ${#bins[@]} -eq 0 ]]; then
        echo "Could not find an instrumented test binary under ${product}" >&2
        exit 1
    fi
    xcrun llvm-cov export -format=text -instr-profile "${profdata}" "${bins[@]}" > "${destination}"
}

command="${1:-}"
mkdir -p "${OUT}"

case "${command}" in
    complexity)
        require_analyzer
        "${SLOPGUARD_DIR}/slopguard-swift" analyze \
            --path "${REPO_ROOT}" \
            --no-coverage \
            --exclude build 'build/*' .deriveddata '.deriveddata/*' 'web/node_modules/*' \
            --json --quiet > "${OUT}/complexity.json"
        ;;
    collect-app)
        simulator_id="$(pick_simulator)"
        "${REPO_ROOT}/scripts/fetch_apple_test_models.sh"
        rm -rf "${OUT}/app.xcresult"
        xcodebuild test \
            -workspace "${REPO_ROOT}/ios/MLBrowser.xcworkspace" \
            -scheme MLBrowser \
            AIA_INCLUDE_TEST_FIXTURES=YES \
            -testPlan MLBrowserUnitTests \
            -destination "platform=iOS Simulator,id=${simulator_id}" \
            -derivedDataPath "${REPO_ROOT}/.deriveddata" \
            -resultBundlePath "${OUT}/app.xcresult" \
            -enableCodeCoverage YES \
            -skipPackagePluginValidation \
            -skipMacroValidation
        xcrun xccov view --report --json "${OUT}/app.xcresult" > "${OUT}/app-coverage.json"
        ;;
    collect-tools)
        swift test --package-path "${REPO_ROOT}/Tools" --enable-code-coverage
        export_llvm "${REPO_ROOT}/Tools/.build" "${OUT}/tools-coverage.json"
        ;;
    collect-converter)
        reference_directory="$(mktemp -d "${TMPDIR:-/tmp}/native-model-converter-references.XXXXXX")"
        trap 'rm -rf "${reference_directory}"' EXIT
        download_reference() {
            curl --fail --location --silent --show-error --output "${reference_directory}/$1" "$2"
            echo "$3  ${reference_directory}/$1" | shasum -a 256 -c -
        }
        download_reference \
            MobileNetV2Int8LUT.mlmodel \
            "https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2Int8LUT.mlmodel" \
            ee53bca4c5042d77aed5c093cba31c2ef229d1cc4c027300af9cc8bf9e240409
        download_reference \
            MobileNetV2FP16.mlmodel \
            "https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2FP16.mlmodel" \
            c76832208ff4c936365f0f2609f7b77f7f1a6caf62b0b429056d5ad7e48635ad
        if [[ ! -d "${REPO_ROOT}/.native-model-fixtures" ]]; then
            echo "Missing ${REPO_ROOT}/.native-model-fixtures. Run ./scripts/fetch_native_test_models.sh first." >&2
            exit 1
        fi
        NATIVE_MODEL_ONNX_DIRECTORY="${REPO_ROOT}/.native-model-fixtures" \
            NATIVE_MODEL_REFERENCE_DIRECTORY="${reference_directory}" \
            swift test --package-path "${REPO_ROOT}" --skip ADAFCheckpointDirectoryTests --enable-code-coverage
        export_llvm "${REPO_ROOT}/.build" "${OUT}/converter-coverage.json"
        ;;
    report)
        require_analyzer
        for required in app-coverage.json converter-coverage.json tools-coverage.json complexity.json; do
            if [[ ! -s "${OUT}/${required}" ]]; then
                echo "Missing ${OUT}/${required}. Run the collect and complexity commands first." >&2
                exit 1
            fi
        done
        revision="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        if [[ ! -s "${OUT}/runs.json" ]]; then
            echo '[]' > "${OUT}/runs.json"
        fi
        python3 "${REPO_ROOT}/scripts/slopguard_baseline.py" \
            --complexity "${OUT}/complexity.json" \
            --initial "${OUT}/worst-15-percent.csv" \
            --xccov app "${OUT}/app-coverage.json" \
            --llvm-cov converter "${OUT}/converter-coverage.json" \
            --llvm-cov tools "${OUT}/tools-coverage.json" \
            --require-suite app \
            --require-suite converter \
            --require-suite tools \
            --source-revision "${revision}" \
            --analyzer-revision "${ANALYZER_PIN}" \
            --runs "${OUT}/runs.json" \
            --out "${PUBLISHED}"
        ;;
    *)
        usage
        ;;
esac
