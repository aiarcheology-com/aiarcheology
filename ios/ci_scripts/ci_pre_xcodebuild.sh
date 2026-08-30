#!/bin/zsh
# ci_pre_xcodebuild.sh
# ====================
# Xcode Cloud build script that runs before xcodebuild.
# Generates secrets files from environment variables configured in Xcode Cloud.
#
# Required Xcode Cloud Environment Variables (set in workflow settings):
#   - SENTRY_DSN: The Sentry Data Source Name
#   - SENTRY_AUTH_TOKEN: The Sentry CLI authentication token (mark as Secret)
#   - CLERK_PUBLISHABLE_KEY: dev/test Clerk publishable key (pk_test_…), mark as Secret.
#   - CLERK_PUBLISHABLE_KEY_LIVE: production Clerk publishable key (pk_live_…), mark as Secret.
#       Both are consumed ONLY by the ARCHIVE action (test/build workflows ignore them —
#       those run the mock auth path). Archive requires BOTH (it ships to TestFlight + App Store,
#       and a Debug build can be pointed at either instance). Which key the binary actually uses
#       is fixed at build time by AIA_BACKEND_ENVIRONMENT, not inferred from the receipt
#       (AIA-0791) — an Xcode Cloud archive is always `production`.
#   - CONFIGCAT_SDK_KEY_LIVE: ConfigCat Production environment SDK key, mark as Secret.
#       Consumed ONLY by the ARCHIVE action. A Release binary reads ConfigCatSDKKeyLive
#       (the Test-environment key is a Debug-only path), so archive requires this one key.
#       Without it the app silently falls back to compiled defaults and no flag can ever
#       be flipped from the dashboard — so archive hard-fails rather than ship a dead
#       kill switch (AIA-0350).
#   - TELEMETRYDECK_APP_ID: TelemetryDeck app identifier. Required only for ARCHIVE so a
#       distributable build cannot silently ship with optional analytics unconfigured.
#
# See: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts

set -eo pipefail

echo "🔧 Running ci_pre_xcodebuild.sh..."
echo "   CI_XCODEBUILD_ACTION: ${CI_XCODEBUILD_ACTION:-<not set>}"

# Skip for test-without-building (secrets already in compiled app)
if [[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]]; then
    echo "⏭️  Skipping secrets generation (test-without-building uses pre-built app)"
    exit 0
fi

# Verify we're on the build machine
if [[ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
    echo "⏭️  CI_PRIMARY_REPOSITORY_PATH not set - skipping"
    exit 0
fi

echo "   CI_PRIMARY_REPOSITORY_PATH: ${CI_PRIMARY_REPOSITORY_PATH}"

# Navigate to the ios directory
cd "${CI_PRIMARY_REPOSITORY_PATH}/ios"
echo "   Working directory: $(pwd)"

# --- Generate Secrets.xcconfig ---

SECRETS_FILE="Secrets.xcconfig"

echo "📝 Generating $SECRETS_FILE from environment variables..."

if [[ -z "${SENTRY_DSN:-}" ]]; then
    echo "⚠️  Warning: SENTRY_DSN environment variable not set"
    echo "   Sentry crash reporting will be disabled in this build"
    SENTRY_DSN=""
fi

# Escape :// as :$()/$()/ for xcconfig compatibility (// is treated as a comment)
ESCAPED_DSN=$(echo "$SENTRY_DSN" | sed 's|://|:$()/$()/|g')

# Clerk publishable key is only needed for distribution (archive) builds. Test and
# plain build actions run the DEBUG mock auth path and never touch Clerk, so they
# get no key — this keeps the test workflows hermetic and independent of Clerk.
CLERK_LINES=""
if [[ "${CI_XCODEBUILD_ACTION:-}" == "archive" ]]; then
    # An archive ships to both TestFlight and the App Store from the same binary, and a Debug
    # build can be pointed at either instance, so the binary carries BOTH public keys. Which one
    # is used is fixed at build time by AIA_BACKEND_ENVIRONMENT — not inferred from the receipt
    # (AIA-0791). See AUTH-SUBSCRIPTION.md, "Which backend a build talks to".
    if [[ -z "${CLERK_PUBLISHABLE_KEY:-}" || -z "${CLERK_PUBLISHABLE_KEY_LIVE:-}" ]]; then
        echo "❌ Archive builds require BOTH CLERK_PUBLISHABLE_KEY (pk_test_…) and CLERK_PUBLISHABLE_KEY_LIVE (pk_live_…)."
        echo "   Set both in the Xcode Cloud archive workflow's environment."
        echo "   Refusing to produce a distributable with authentication unconfigured."
        exit 1
    fi
    # Clerk publishable keys are base64url (pk_test_… / pk_live_…) — no `//`, no escaping needed.
    CLERK_LINES="CLERK_PUBLISHABLE_KEY = ${CLERK_PUBLISHABLE_KEY}
CLERK_PUBLISHABLE_KEY_LIVE = ${CLERK_PUBLISHABLE_KEY_LIVE}"
else
    echo "ℹ️  Action '${CI_XCODEBUILD_ACTION:-<unset>}' is not 'archive' — skipping Clerk keys (tests use the mock auth path)"
fi

# ConfigCat, like Clerk, is only needed for distribution (archive) builds. Debug builds
# read the Test-environment key, and every test target is pinned to
# StaticFeatureFlagProvider, so test/build actions need no key at all.
CONFIGCAT_LINES=""
if [[ "${CI_XCODEBUILD_ACTION:-}" == "archive" ]]; then
    # A Release binary only ever reads ConfigCatSDKKeyLive (the Debug/Test key path is
    # compiled out), so the Production key is the only one an archive requires.
    if [[ -z "${CONFIGCAT_SDK_KEY_LIVE:-}" ]]; then
        echo "❌ Archive builds require CONFIGCAT_SDK_KEY_LIVE (ConfigCat Production environment)."
        echo "   Set it in the Xcode Cloud archive workflow's environment."
        echo "   Without it the remote kill switch is silently dead: the app falls back to"
        echo "   compiled defaults (both flags ON) and no dashboard change can ever reach it."
        exit 1
    fi
    # ConfigCat SDK keys are base64url segments joined by single `/` (configcat-sdk-1/…/…).
    # Only `//` opens an xcconfig comment, so no escaping is needed.
    CONFIGCAT_LINES="CONFIGCAT_SDK_KEY_LIVE = ${CONFIGCAT_SDK_KEY_LIVE}"
else
    echo "ℹ️  Action '${CI_XCODEBUILD_ACTION:-<unset>}' is not 'archive' — skipping ConfigCat keys (tests pin StaticFeatureFlagProvider)"
fi

# TelemetryDeck is optional at runtime (the user must actively enable it), but an archive
# must contain the app identifier so the choice can work after distribution. The identifier
# is not a secret; no value is logged here regardless.
TELEMETRYDECK_LINES=""
if [[ "${CI_XCODEBUILD_ACTION:-}" == "archive" ]]; then
    if [[ -z "${TELEMETRYDECK_APP_ID:-}" ]]; then
        echo "❌ Archive builds require TELEMETRYDECK_APP_ID."
        echo "   Set it in the Xcode Cloud archive workflow's environment."
        exit 1
    fi
    TELEMETRYDECK_LINES="TELEMETRYDECK_APP_ID = ${TELEMETRYDECK_APP_ID}"
else
    echo "ℹ️  Action '${CI_XCODEBUILD_ACTION:-<unset>}' is not 'archive' — skipping TelemetryDeck key"
fi

cat > "$SECRETS_FILE" << EOF
// Secrets.xcconfig
// Auto-generated by ci_pre_xcodebuild.sh - DO NOT EDIT
// Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

SENTRY_DSN = ${ESCAPED_DSN}
${CLERK_LINES}
${CONFIGCAT_LINES}
${TELEMETRYDECK_LINES}
EOF

echo "   ✅ Created $SECRETS_FILE"

# --- Generate .sentryclirc ---

SENTRY_CLI_RC=".sentryclirc"

echo "📝 Generating $SENTRY_CLI_RC from environment variables..."

if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    echo "⚠️  Warning: SENTRY_AUTH_TOKEN environment variable not set"
    echo "   dSYM upload will be skipped in this build"
else
    cat > "$SENTRY_CLI_RC" << EOF
# .sentryclirc
# Auto-generated by ci_pre_xcodebuild.sh - DO NOT EDIT

[auth]
token=${SENTRY_AUTH_TOKEN}
EOF
    echo "   ✅ Created $SENTRY_CLI_RC"
fi

echo "✅ ci_pre_xcodebuild.sh completed successfully"
