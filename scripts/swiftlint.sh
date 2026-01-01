#!/bin/bash
#
# Convenience wrapper for running SwiftLint.
#
# Usage:
#   ./scripts/swiftlint.sh              # Lint ios/ directory
#   ./scripts/swiftlint.sh lint         # Same as above
#   ./scripts/swiftlint.sh fix          # Autocorrect ios/ directory
#   ./scripts/swiftlint.sh lint MyFile.swift  # Lint specific file
#   ./scripts/swiftlint.sh fix MyFile.swift   # Fix specific file
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Require SwiftLint to be installed
if ! command -v swiftlint &>/dev/null; then
  echo "Error: SwiftLint is not installed." >&2
  echo "Install it with: brew install swiftlint" >&2
  exit 1
fi

ACTION="${1:-lint}"
shift || true

# Collect files into array for proper handling of paths with spaces
if [[ $# -eq 0 ]]; then
  TARGET_FILES=("${REPO_ROOT}/ios")
else
  TARGET_FILES=("$@")
fi

cd "${REPO_ROOT}/ios"

case "${ACTION}" in
  lint)
    echo "Running SwiftLint lint on ${TARGET_FILES[*]}..."
    exec swiftlint lint --force-exclude "${TARGET_FILES[@]}"
    ;;
  fix|autocorrect)
    echo "Running SwiftLint autocorrect on ${TARGET_FILES[*]}..."
    exec swiftlint lint --fix --force-exclude "${TARGET_FILES[@]}"
    ;;
  *)
    # Pass through any other command directly to swiftlint
    exec swiftlint "${ACTION}" "$@"
    ;;
esac
