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

# Find an available iOS simulator by ID for reliable matching
# Prefer iPhone 16, fall back to any available iPhone
PREFERRED_SIMULATOR="iPhone 16"
SIMULATOR_ID=""
SIMULATOR_NAME=""

# Get the simulator ID for reliable destination matching
# Format: "    iPhone 16 (UUID) (Booted/Shutdown)"
while IFS= read -r line; do
    if [[ "$line" =~ $PREFERRED_SIMULATOR ]]; then
        # Extract UUID from the line
        if [[ "$line" =~ \(([A-F0-9-]{36})\) ]]; then
            SIMULATOR_ID="${BASH_REMATCH[1]}"
            SIMULATOR_NAME="$PREFERRED_SIMULATOR"
            break
        fi
    fi
done < <(xcrun simctl list devices available 2>/dev/null)

# Fall back to first available iPhone if preferred not found
if [[ -z "$SIMULATOR_ID" ]]; then
    echo "Warning: ${PREFERRED_SIMULATOR} simulator not found. Using first available iPhone simulator."
    while IFS= read -r line; do
        if [[ "$line" =~ iPhone ]]; then
            if [[ "$line" =~ \(([A-F0-9-]{36})\) ]]; then
                SIMULATOR_ID="${BASH_REMATCH[1]}"
                # Extract name (everything before the first parenthesis)
                SIMULATOR_NAME=$(echo "$line" | sed 's/ *(.*//' | xargs)
                break
            fi
        fi
    done < <(xcrun simctl list devices available 2>/dev/null)
fi

if [[ -z "$SIMULATOR_ID" ]]; then
    echo "Error: No iPhone simulator found. Please install one via Xcode." >&2
    exit 1
fi

echo "Running Harmonize architectural tests..."
echo "Simulator: ${SIMULATOR_NAME} (${SIMULATOR_ID})"
echo ""

# Run only the ArchitectureTests test class using simulator ID for reliable matching
xcodebuild test \
    -workspace ios/MLBrowser.xcworkspace \
    -scheme MLBrowser \
    -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
    -only-testing:MLBrowserUnitTests/ArchitectureTests \
    ${VERBOSE} \
    | xcpretty --color 2>/dev/null || xcodebuild test \
        -workspace ios/MLBrowser.xcworkspace \
        -scheme MLBrowser \
        -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
        -only-testing:MLBrowserUnitTests/ArchitectureTests \
        ${VERBOSE}

echo ""
echo "Harmonize architectural tests completed."
