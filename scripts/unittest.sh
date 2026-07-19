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

# Pick the available iPhone simulator on the NEWEST iOS runtime. Selecting the
# first available iPhone is unsafe: simctl reports devices on runtimes below the
# app's deployment target as "available", but xcodebuild rejects them as
# destinations ("Unable to find a destination matching..."). The newest runtime
# is always >= the deployment target on a sane install.
SIMULATOR_ID=$(xcrun simctl list devices available -j 2>/dev/null | \
    python3 -c "
import json, re, sys
data = json.load(sys.stdin)
best = None  # ((major, minor), udid)
for runtime, devices in data.get('devices', {}).items():
    match = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for d in devices:
        if d.get('isAvailable') and 'iPhone' in d.get('name', ''):
            if best is None or version > best[0]:
                best = (version, d['udid'])
if best is None:
    sys.exit(1)
print(best[1])
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
