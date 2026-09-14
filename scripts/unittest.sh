#!/bin/bash
#
# Convenience wrapper for running MLBrowser unit tests.
#
# Usage:
#   ./scripts/unittest.sh              # Run all unit tests
#   ./scripts/unittest.sh --verbose    # Run with verbose output
#   ./scripts/unittest.sh --help       # Show help
#
# Prerequisites:
#   - Xcode must be installed
#   - Run from the repository root
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run unit tests for the MLBrowser project."
    echo ""
    echo "Options:"
    echo "  --verbose, -v    Show detailed test output"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0               Run all unit tests"
    echo "  $0 --verbose     Run with detailed output"
}

VERBOSE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE="-verbose"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

cd "${REPO_ROOT}"

python3 scripts/test_apple_test_models.py

# ProjectTool's own tests run first: they are pure host-side Swift (no simulator, well under a
# second), so a failure here should not cost a full simulator boot to discover. Without this the
# Tools package has no test coverage in either the pre-push sweep or CI.
echo "Running ProjectTool (Tools) unit tests..."
if swift test --package-path Tools; then
    echo "ProjectTool unit tests completed successfully."
    echo ""
else
    TOOLS_EXIT_CODE=$?
    echo ""
    echo "ProjectTool unit tests failed."
    exit $TOOLS_EXIT_CODE
fi

# deliver.sh credential resolution — hermetic (no network, no Xcode, no real credentials).
if ./scripts/test_deliver_credentials.sh; then
    echo ""
else
    DELIVER_EXIT_CODE=$?
    echo ""
    echo "deliver.sh credential tests failed."
    exit $DELIVER_EXIT_CODE
fi

# Pick the available iPhone simulator on the newest iOS runtime THIS Xcode can drive.
#
# Two constraints, and taking only one of them produces a broken destination:
#
#   - Not the first available iPhone: simctl reports devices on runtimes below the app's
#     deployment target as "available", but xcodebuild rejects them as destinations
#     ("Unable to find a destination matching...").
#   - Not simply the newest installed runtime either. Installing an Xcode beta leaves its
#     newer runtime on the machine, and the shipping Xcode cannot launch a test host on it:
#     the build succeeds, then every test dies with "Simulator device failed to launch"
#     (FBSOpenApplicationServiceErrorDomain). Cap at the active toolchain's simulator SDK.
SDK_VERSION=$(xcodebuild -version -sdk iphonesimulator SDKVersion 2>/dev/null | tr -d '[:space:]')
if [[ -z "${SDK_VERSION}" ]]; then
    echo "❌ Could not read the iOS Simulator SDK version from the active Xcode."
    echo "   Check 'xcode-select -p' / DEVELOPER_DIR — a CommandLineTools selection has no SDK."
    exit 1
fi

SIMULATOR_ID=$(xcrun simctl list devices available -j 2>/dev/null | \
    SDK_VERSION="${SDK_VERSION}" python3 -c "
import json, os, re, sys

def parse(text):
    parts = re.findall(r'\d+', text)
    return tuple(int(p) for p in parts[:2]) if parts else None

cap = parse(os.environ['SDK_VERSION'])
if cap is None:
    sys.exit(1)
if len(cap) == 1:
    cap = (cap[0], 0)

data = json.load(sys.stdin)
best = None  # ((major, minor), udid)
for runtime, devices in data.get('devices', {}).items():
    match = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if version > cap:
        continue
    for d in devices:
        if d.get('isAvailable') and 'iPhone' in d.get('name', ''):
            if best is None or version > best[0]:
                best = (version, d['udid'])
if best is None:
    sys.exit(1)
print(best[1])
" 2>/dev/null)

if [[ -z "${SIMULATOR_ID}" ]]; then
    echo "❌ No available iPhone simulator on an iOS runtime this Xcode can drive (<= ${SDK_VERSION})."
    echo "   Install one via Xcode > Settings > Platforms. A runtime NEWER than ${SDK_VERSION} is"
    echo "   deliberately ignored: this Xcode cannot launch a test host on it."
    exit 1
fi

# Get simulator name for display
SIMULATOR_NAME=$(xcrun simctl list devices -j 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
target_id = '${SIMULATOR_ID}'
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('udid') == target_id:
            print(d['name'])
            sys.exit(0)
" 2>/dev/null)

if [[ -z "${SIMULATOR_NAME}" ]]; then
    echo "⚠️  Warning: Unable to determine simulator name for ID ${SIMULATOR_ID}. Using fallback label." >&2
    SIMULATOR_NAME="Unknown iOS Simulator"
fi

./scripts/fetch_apple_test_models.sh

echo "Running MLBrowser unit tests..."
echo "Destination: ${SIMULATOR_NAME} (${SIMULATOR_ID})"
echo ""

# Build the xcodebuild command dynamically
#
# Uses the MLBrowserUnitTests test plan which targets the MLBrowserUnitTests target.
#
# Code signing MUST stay enabled. It is tempting to add CODE_SIGNING_ALLOWED=NO /
# CODE_SIGNING_REQUIRED=NO to shave build time, and this script did exactly that from AIA-0038
# until AIA-0598. Do not put them back: keychain access is granted through entitlements
# (`application-identifier`, `keychain-access-groups`), those entitlements are embedded by the
# codesign step, and an unsigned binary therefore belongs to no keychain access group. Every
# keychain test then fails with errSecMissingEntitlement (-34018) — 20 of them in
# FreeAccessAnchorServiceTests (AIA-0556) — which also fails the deliver.sh preflight sweep and
# makes a TestFlight upload impossible. Simulator builds sign ad-hoc ("Sign to Run Locally") and
# need no developer certificate, so nothing is gained by skipping it.
#
# Environment variables:
#   SPM_CACHE_PATH: Specify SPM package cache location (for CI)
#   DERIVED_DATA_PATH: Specify derived data path for build caching

# Default derived data path for faster incremental builds
DERIVED_DATA="${DERIVED_DATA_PATH:-${REPO_ROOT}/.deriveddata}"

XCODEBUILD_ARGS=(
    test
    -workspace ios/MLBrowser.xcworkspace
    -scheme MLBrowser
    AIA_INCLUDE_TEST_FIXTURES=YES
    -testPlan MLBrowserUnitTests
    -destination "platform=iOS Simulator,id=${SIMULATOR_ID}"
    -derivedDataPath "${DERIVED_DATA}"
    -skipPackagePluginValidation
    -skipMacroValidation
)

if [[ -n "${SPM_CACHE_PATH:-}" ]]; then
    XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${SPM_CACHE_PATH}")
fi

if [[ -n "${VERBOSE}" ]]; then
    XCODEBUILD_ARGS+=("${VERBOSE}")
fi

# Under `set -e`, a plain `xcodebuild ...; TEST_EXIT_CODE=$?` aborts before the capture,
# so the failure branch is dead code. The if-form disables errexit for the command and
# preserves the exact xcodebuild exit code (e.g. 65 for test failures).
if xcodebuild "${XCODEBUILD_ARGS[@]}"; then
    echo ""
    echo "Unit tests completed successfully."
else
    TEST_EXIT_CODE=$?
    echo ""
    echo "Unit tests failed."
    exit $TEST_EXIT_CODE
fi
