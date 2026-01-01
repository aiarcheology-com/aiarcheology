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

# Default path is ios/ if no files specified
if [[ $# -eq 0 ]]; then
  TARGET_PATH="${REPO_ROOT}/ios"
else
  TARGET_PATH="$*"
fi

cd "${REPO_ROOT}/ios"

case "${ACTION}" in
  lint)
    echo "Running SwiftLint lint on ${TARGET_PATH}..."
    # shellcheck disable=SC2086
    exec swiftlint lint --force-exclude ${TARGET_PATH}
    ;;
  fix|autocorrect)
    echo "Running SwiftLint autocorrect on ${TARGET_PATH}..."
    # shellcheck disable=SC2086
    exec swiftlint lint --fix --force-exclude ${TARGET_PATH}
    ;;
  *)
    # Pass through any other command directly to swiftlint
    exec swiftlint "${ACTION}" "$@"
    ;;
esac
