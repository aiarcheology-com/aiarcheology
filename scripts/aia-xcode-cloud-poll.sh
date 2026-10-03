#!/bin/bash
# Read-only Xcode Cloud observation; see --help for build/branch selection and watch mode.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
exec swift run --package-path "$REPO_ROOT/Tools" ProjectTool asc cloud "$@"
