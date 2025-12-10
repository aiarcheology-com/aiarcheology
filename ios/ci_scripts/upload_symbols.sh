#!/bin/zsh
# upload_symbols.sh
# =================
# Unified script for uploading debug symbols to Sentry.
# Called from both Xcode Build Phase (local) and ci_post_xcodebuild.sh (CI).
#
# Usage:
#   ./upload_symbols.sh <path_to_dsyms>
#
# Environment variables:
#   SENTRY_ORG      - Sentry organization slug (required)
#   SENTRY_PROJECT  - Sentry project slug (required)
#   SENTRY_AUTH_TOKEN - Auth token (optional if .sentryclirc exists)

set -eo pipefail

DSYM_PATH="${1:-}"

if [[ -z "$DSYM_PATH" ]]; then
    echo "error: No dSYM path provided"
    echo "Usage: $0 <path_to_dsyms>"
    exit 1
fi

if [[ ! -e "$DSYM_PATH" ]]; then
    echo "warning: dSYM path does not exist: $DSYM_PATH"
    exit 0
fi

# Set defaults if not provided
export SENTRY_ORG="${SENTRY_ORG:-ai-archeology}"
export SENTRY_PROJECT="${SENTRY_PROJECT:-apple-ios-ml-browser}"

# Find sentry-cli
if command -v sentry-cli &> /dev/null; then
    SENTRY_CLI="sentry-cli"
elif [[ -f "/usr/local/bin/sentry-cli" ]]; then
    SENTRY_CLI="/usr/local/bin/sentry-cli"
elif [[ -f "${HOME}/bin/sentry-cli" ]]; then
    SENTRY_CLI="${HOME}/bin/sentry-cli"
else
    echo "warning: sentry-cli not installed, download from https://github.com/getsentry/sentry-cli/releases"
    exit 0
fi

echo "📤 Uploading debug symbols to Sentry..."
echo "   Organization: ${SENTRY_ORG}"
echo "   Project: ${SENTRY_PROJECT}"
echo "   Path: ${DSYM_PATH}"

# Build command with optional auth token
CMD=("$SENTRY_CLI")

if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
    CMD+=("--auth-token" "$SENTRY_AUTH_TOKEN")
fi

CMD+=("debug-files" "upload" "--include-sources")
CMD+=("--org" "$SENTRY_ORG")
CMD+=("--project" "$SENTRY_PROJECT")
CMD+=("$DSYM_PATH")

# Execute
if "${CMD[@]}"; then
    echo "✅ Debug symbols uploaded successfully"
else
    echo "warning: sentry-cli upload failed (exit code: $?)"
fi
