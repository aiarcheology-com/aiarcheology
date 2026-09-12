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

# Install sentry-cli now that we know this is an archive build that will actually use it.
# ci_post_clone.sh deliberately skips it so test/build workflows don't download a binary they
# never run (and can't be failed by its release host being flaky).
SCRIPT_DIR="${0:A:h}"
echo "📦 Ensuring sentry-cli is installed..."
"${SCRIPT_DIR}/install_sentry_cli.sh"

# Use unified upload script
"${SCRIPT_DIR}/upload_symbols.sh" "$CI_ARCHIVE_PATH"

# Create Sentry release and associate commits (best-effort)
# This enables commit metadata (commitCount/lastCommit/suspects) on releases/issues.
"${SCRIPT_DIR}/sentry_release.sh" "$CI_ARCHIVE_PATH" || true

echo "✅ ci_post_xcodebuild.sh completed successfully"
