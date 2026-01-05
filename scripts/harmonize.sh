#!/bin/bash
#
# Convenience wrapper for running Harmonize architectural tests.
#
# Usage:
#   ./scripts/harmonize.sh              # Run Harmonize tests
#   ./scripts/harmonize.sh --verbose    # Run with verbose output
#   ./scripts/harmonize.sh --help       # Show help
#
# Prerequisites:
#   - Xcode must be installed
#   - The Harmonize SPM package must be added to the test target
#   - Run from the repository root
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run Harmonize architectural tests for the MLBrowser project."
    echo ""
    echo "Options:"
    echo "  --verbose, -v    Show detailed test output"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0               Run architecture tests"
    echo "  $0 --verbose     Run with detailed output"
    echo ""
    echo "Note: Harmonize rules are guidelines, not unbreakable constraints."
    echo "      Evaluate trade-offs when rules conflict with pragmatic design."
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

echo "Running Harmonize architectural tests..."
echo "Destination: macOS (recommended for Harmonize file access)"
echo ""

# Run Harmonize tests using the dedicated test plan.
#
# IMPORTANT: Harmonize reads project source files from disk. On iOS Simulator, the test runner
# is sandboxed and can't read your repository, causing failures like:
#   "Harmonize is unable to read the files of your project. This may be caused by App Sandboxing."
#
# Running on macOS avoids this and is the intended execution environment for architecture lint.
#
# Code signing is disabled for CI compatibility (GitHub Actions runners lack dev certificates).
xcodebuild test \
    -workspace ios/MLBrowser.xcworkspace \
    -scheme MLBrowserArchitectureTests \
    -destination "platform=macOS" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ${VERBOSE}
TEST_EXIT_CODE=$?

echo ""
if [[ $TEST_EXIT_CODE -eq 0 ]]; then
    echo "Harmonize architectural tests completed successfully."
else
    echo "Harmonize architectural tests failed."
fi
exit $TEST_EXIT_CODE
