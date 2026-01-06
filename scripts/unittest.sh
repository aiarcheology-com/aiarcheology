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

# Find the first available iPhone simulator (using simctl for speed)
SIMULATOR_ID=$(xcrun simctl list devices available -j 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' in runtime and 'tvOS' not in runtime and 'watchOS' not in runtime:
        for d in devices:
            if d.get('isAvailable') and 'iPhone' in d.get('name', ''):
                print(d['udid'])
                sys.exit(0)
sys.exit(1)
" 2>/dev/null)

if [[ -z "${SIMULATOR_ID}" ]]; then
    echo "❌ No available iPhone simulator found."
    echo "   Please install an iPhone simulator via Xcode > Settings > Platforms."
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

echo "Running MLBrowser unit tests..."
echo "Destination: ${SIMULATOR_NAME} (${SIMULATOR_ID})"
echo ""

# Build the xcodebuild command dynamically
#
# Uses the MLBrowserUnitTests test plan which targets the MLBrowserUnitTests target.
# Code signing is disabled for CI compatibility (GitHub Actions runners lack dev certificates).
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
    -testPlan MLBrowserUnitTests
    -destination "platform=iOS Simulator,id=${SIMULATOR_ID}"
    -derivedDataPath "${DERIVED_DATA}"
    -skipPackagePluginValidation
    -skipMacroValidation
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)

if [[ -n "${SPM_CACHE_PATH:-}" ]]; then
    XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${SPM_CACHE_PATH}")
fi

if [[ -n "${VERBOSE}" ]]; then
    XCODEBUILD_ARGS+=("${VERBOSE}")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"
TEST_EXIT_CODE=$?

echo ""
if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "Unit tests completed successfully."
else
    echo "Unit tests failed."
fi
exit $TEST_EXIT_CODE
