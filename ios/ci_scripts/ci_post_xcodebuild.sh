#!/bin/zsh
# ci_post_xcodebuild.sh
# =====================
# Uploads dSYM files to Sentry for crash symbolication.
# Runs after xcodebuild completes in Xcode Cloud.
#
# Required Xcode Cloud Environment Variables:
#   - SENTRY_AUTH_TOKEN: Sentry authentication token (mark as Secret)
#   - SENTRY_ORG: Sentry organization slug (e.g., "ai-archeology")
#   - SENTRY_PROJECT: Sentry project slug
#
# Reference: https://docs.sentry.io/platforms/apple/dsym/

set -eo pipefail

echo "🔧 Running ci_post_xcodebuild.sh..."
echo "   CI_XCODEBUILD_ACTION: ${CI_XCODEBUILD_ACTION:-<not set>}"

# Only upload dSYMs for archive builds
if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    echo "⏭️  Skipping dSYM upload (only needed for archive builds)"
    exit 0
fi

# Only run if archive exists
if [[ -z "${CI_ARCHIVE_PATH:-}" ]] || [[ ! -d "${CI_ARCHIVE_PATH:-}" ]]; then
    echo "⏭️  Archive path not available - skipping dSYM upload"
    exit 0
fi

# Check required environment variables
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    echo "⚠️  SENTRY_AUTH_TOKEN not set - skipping dSYM upload"
    exit 0
fi

if [[ -z "${SENTRY_ORG:-}" ]]; then
    echo "❌ SENTRY_ORG environment variable not set"
    exit 1
fi

if [[ -z "${SENTRY_PROJECT:-}" ]]; then
    echo "❌ SENTRY_PROJECT environment variable not set"
    exit 1
fi

# Install sentry-cli
SCRIPT_DIR="${0:A:h}"
export INSTALL_DIR="$SCRIPT_DIR"

if ! command -v sentry-cli &> /dev/null && [[ ! -f "$SCRIPT_DIR/sentry-cli" ]]; then
    echo "📦 Installing sentry-cli..."
    curl -sL https://sentry.io/get-cli/ | bash
fi

echo "📤 Uploading dSYM files to Sentry..."
echo "   Organization: ${SENTRY_ORG}"
echo "   Project: ${SENTRY_PROJECT}"
echo "   Archive path: ${CI_ARCHIVE_PATH}"

# Use local sentry-cli if available
if [[ -f "$SCRIPT_DIR/sentry-cli" ]]; then
    SENTRY_CLI="$SCRIPT_DIR/sentry-cli"
else
    SENTRY_CLI="sentry-cli"
fi

$SENTRY_CLI --auth-token "$SENTRY_AUTH_TOKEN" \
    upload-dif \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$CI_ARCHIVE_PATH"

echo "✅ dSYM upload complete"
