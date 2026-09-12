#!/bin/zsh
# sentry_release.sh
# ================
# Creates a Sentry release and associates commits so Sentry can show:
# - commitCount / lastCommit on releases
# - suspect commits / suggested owners (when supported)
#
# Intended to run in CI after an archive build (Xcode Cloud), using the produced .xcarchive
# to read version/build and generate a stable release identifier.
#
# Usage:
#   ./sentry_release.sh <path_to_xcarchive>
#
# Environment variables:
#   SENTRY_ORG        - Sentry org slug (default: ai-archeology)
#   SENTRY_PROJECT    - Sentry project slug (default: apple-ios-ml-browser)
#   SENTRY_AUTH_TOKEN - optional (if .sentryclirc exists)
#
# Docs:
#   https://docs.sentry.io/product/releases/associate-commits/

set -eo pipefail

ARCHIVE_PATH="${1:-}"
if [[ -z "$ARCHIVE_PATH" ]]; then
  echo "error: No archive path provided"
  echo "Usage: $0 <path_to_xcarchive>"
  exit 1
fi

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "warning: archive path does not exist: $ARCHIVE_PATH"
  exit 0
fi

# Defaults if not provided
export SENTRY_ORG="${SENTRY_ORG:-ai-archeology}"
export SENTRY_PROJECT="${SENTRY_PROJECT:-apple-ios-ml-browser}"

# Find sentry-cli (same strategy as upload_symbols.sh)
if command -v sentry-cli &> /dev/null; then
  SENTRY_CLI="sentry-cli"
elif [[ -f "/usr/local/bin/sentry-cli" ]]; then
  SENTRY_CLI="/usr/local/bin/sentry-cli"
elif [[ -f "${HOME}/bin/sentry-cli" ]]; then
  SENTRY_CLI="${HOME}/bin/sentry-cli"
else
  echo "warning: sentry-cli not installed; skipping release/commit association"
  exit 0
fi

# Locate the built .app inside the archive
APP_DIR="${ARCHIVE_PATH}/Products/Applications"
APP_PATH="$(find "$APP_DIR" -maxdepth 1 -name "*.app" -print -quit 2>/dev/null || true)"
if [[ -z "$APP_PATH" ]]; then
  echo "warning: no .app found in archive at: $APP_DIR"
  exit 0
fi

INFO_PLIST="${APP_PATH}/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "warning: Info.plist not found at: $INFO_PLIST"
  exit 0
fi

# Read version/build from Info.plist
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"

if [[ -z "$SHORT_VERSION" ]] || [[ -z "$BUILD_NUMBER" ]]; then
  echo "warning: could not read CFBundleShortVersionString/CFBundleVersion from Info.plist"
  exit 0
fi

# Keep release naming consistent with app-side Sentry options.releaseName
RELEASE_VERSION="mlbrowser@${SHORT_VERSION}+${BUILD_NUMBER}"

echo "🚀 Creating Sentry release + associating commits..."
echo "   Org: ${SENTRY_ORG}"
echo "   Project: ${SENTRY_PROJECT}"
echo "   Release: ${RELEASE_VERSION}"

# Optional auth token
CMD=("$SENTRY_CLI")
if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
  CMD+=("--auth-token" "$SENTRY_AUTH_TOKEN")
fi

# Ensure we run inside the git repo when possible (for local commit association).
if [[ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]] && [[ -d "${CI_PRIMARY_REPOSITORY_PATH}/.git" ]]; then
  cd "${CI_PRIMARY_REPOSITORY_PATH}"
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "warning: not in a git repository; cannot associate commits automatically"
  # Still create the release (useful for grouping)
  "${CMD[@]}" releases new -p "$SENTRY_PROJECT" "$RELEASE_VERSION" || true
  "${CMD[@]}" releases finalize "$RELEASE_VERSION" || true
  exit 0
fi

# If repository is shallow, try to unshallow (best-effort)
if git rev-parse --is-shallow-repository >/dev/null 2>&1 && [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "ℹ️  Shallow git clone detected; attempting to fetch full history (best-effort)..."
  git fetch --unshallow 2>/dev/null || true
fi

# 1) Create release
"${CMD[@]}" releases new -p "$SENTRY_PROJECT" "$RELEASE_VERSION" || true

# 2) Associate commits (best-effort)
# Try --auto first (prefers repo integration when present, else uses local git range)
if ! "${CMD[@]}" releases set-commits --auto "$RELEASE_VERSION"; then
  echo "warning: set-commits --auto failed; retrying with --local --initial-depth 20"
  "${CMD[@]}" releases set-commits --local --initial-depth 20 "$RELEASE_VERSION" || true
fi

# 3) Finalize release
"${CMD[@]}" releases finalize "$RELEASE_VERSION" || true

echo "✅ Sentry release step finished (best-effort)."


