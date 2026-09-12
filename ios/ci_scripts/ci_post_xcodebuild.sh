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

# The archive action must have produced an archive. This used to `exit 0` — sensible when the only
# consumer was a dSYM upload, fatal-by-omission now that the backend assertion below depends on it:
# the check would "pass" by never running. CI_XCODEBUILD_ACTION is already known to be `archive`
# here, so a missing archive is a broken build, not a skip (AIA-0791).
if [[ -z "${CI_ARCHIVE_PATH:-}" ]] || [[ ! -d "${CI_ARCHIVE_PATH:-}" ]]; then
    echo "❌ Archive action produced no archive at CI_ARCHIVE_PATH — cannot verify the backend."
    exit 1
fi

# --- Assert the backend this archive talks to (AIA-0791) ---
# Xcode Cloud only ever archives under Release, which sets AIA_BACKEND_ENVIRONMENT=production, and
# it cannot pass a command-line override. So this cannot fail unless someone changed a build
# setting — which is exactly the change that must not reach TestFlight unnoticed.
#
# Deliberately BEFORE the Sentry token checks, so a wrong backend fails even when Sentry is
# unconfigured (those checks `exit 0` on a missing token).
APP_PLIST=$(find "${CI_ARCHIVE_PATH}/Products/Applications" -maxdepth 2 -name Info.plist | head -1)
if [[ -z "$APP_PLIST" ]]; then
    echo "❌ Could not find the archived app's Info.plist under ${CI_ARCHIVE_PATH}"
    exit 1
fi
BUILT_ENV=$(plutil -extract BackendEnvironment raw -o - "$APP_PLIST" 2>/dev/null || true)
if [[ "$BUILT_ENV" != "production" ]]; then
    echo "❌ Xcode Cloud archives must target the production backend, got '${BUILT_ENV}'."
    echo "   Check AIA_BACKEND_ENVIRONMENT in the Release configuration of the MLBrowser target."
    exit 1
fi
echo "   ✅ BackendEnvironment=production"

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
