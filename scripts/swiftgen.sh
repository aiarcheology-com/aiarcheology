#!/bin/bash
#
# SwiftGen wrapper that handles String Catalogs (.xcstrings)
#
# Usage:
#   ./scripts/swiftgen.sh              # Generate L10n.swift from xcstrings
#   ./scripts/swiftgen.sh --verify     # Verify SwiftGen is installed
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${REPO_ROOT}/ios"
XCSTRINGS_FILE="${IOS_DIR}/MLBrowser/iOS/Resources/Localizable.xcstrings"
TEMP_STRINGS_FILE="${IOS_DIR}/MLBrowser/iOS/Resources/Localizable.strings"
OUTPUT_FILE="${IOS_DIR}/MLBrowser/iOS/Generated/L10n.swift"

# Check for SwiftGen installation
find_swiftgen() {
    # Check common locations (order matters - prefer bundled installations first)
    local user_lib="${HOME}/.local/lib/swiftgen/bin/swiftgen"
    if [[ -x "$user_lib" ]]; then
        echo "$user_lib"
        return 0
    elif [[ -x "/tmp/swiftgen/bin/swiftgen" ]]; then
        # CI/GitHub Actions location
        echo "/tmp/swiftgen/bin/swiftgen"
        return 0
    elif [[ -x "/opt/homebrew/bin/swiftgen" ]]; then
        echo "/opt/homebrew/bin/swiftgen"
        return 0
    elif [[ -x "/usr/local/bin/swiftgen" ]]; then
        echo "/usr/local/bin/swiftgen"
        return 0
    elif command -v swiftgen &>/dev/null; then
        echo "swiftgen"
        return 0
    fi
    return 1
}

# Convert .xcstrings to .strings format using Swift
convert_xcstrings_to_strings() {
    local input="$1"
    local output="$2"
    local script_dir="$(dirname "${BASH_SOURCE[0]}")"

    swift "${script_dir}/xcstrings-to-strings.swift" "$input" "$output"
}

# Main logic
case "${1:-generate}" in
    --verify)
        if SWIFTGEN=$(find_swiftgen); then
            echo "SwiftGen found: $SWIFTGEN"
            $SWIFTGEN --version
            exit 0
        else
            echo "Error: SwiftGen not found"
            echo "Install with: brew install swiftgen"
            exit 1
        fi
        ;;
    generate|"")
        # Find SwiftGen
        if ! SWIFTGEN=$(find_swiftgen); then
            echo "Error: SwiftGen not installed." >&2
            echo "Install it with: brew install swiftgen" >&2
            exit 1
        fi

        echo "Using SwiftGen: $SWIFTGEN"

        # Check if xcstrings file exists
        if [[ ! -f "$XCSTRINGS_FILE" ]]; then
            echo "Error: $XCSTRINGS_FILE not found" >&2
            exit 1
        fi

        # Ensure output directory exists
        mkdir -p "$(dirname "$OUTPUT_FILE")"

        # Convert xcstrings to strings format
        echo "Converting xcstrings to strings format..."
        convert_xcstrings_to_strings "$XCSTRINGS_FILE" "$TEMP_STRINGS_FILE"

        # Validate iOS directory exists
        if [[ ! -d "$IOS_DIR" ]]; then
            echo "Error: iOS directory not found: $IOS_DIR" >&2
            exit 1
        fi

        # Run SwiftGen
        echo "Running SwiftGen..."
        cd "$IOS_DIR"
        $SWIFTGEN run strings "$TEMP_STRINGS_FILE" \
            --templateName structured-swift5 \
            --param enumName=L10n \
            --output "$OUTPUT_FILE"

        # Clean up temporary file
        rm -f "$TEMP_STRINGS_FILE"

        echo "Generated: $OUTPUT_FILE"
        ;;
    *)
        echo "Usage: $0 [--verify|generate]"
        exit 1
        ;;
esac
