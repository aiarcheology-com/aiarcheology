#!/bin/zsh
# install_sentry_cli.sh
# =====================
# Installs the pinned sentry-cli, on demand.
#
# Only archive builds upload dSYMs, so sentry-cli is installed here rather than in
# ci_post_clone.sh: fetching it for every test/build workflow exposed the most frequently run
# workflows to release-host flakiness, and a single connection reset aborted the whole build
# before Xcode compiled anything.
#
# Called by ci_post_xcodebuild.sh *after* its `archive` gate. Safe to call when sentry-cli is
# already present — it verifies the version and returns without downloading.

set -eo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(git rev-parse --show-toplevel)}"
TOOLS_JSON="${REPO_ROOT}/.tools.json"

if [[ ! -f "$TOOLS_JSON" ]]; then
    echo "   ❌ .tools.json not found at $TOOLS_JSON"
    exit 1
fi

# .tools.json is JSON and needs a real parser (AGENTS.md §10); plutil ships with macOS.
tool_field() {  # $1 = field
    local out
    if ! out=$(plutil -extract "tools.sentry-cli.$1" raw -o - "$TOOLS_JSON" 2>&1); then
        echo "   ❌ Cannot read tools.sentry-cli.$1 from .tools.json: $out" >&2
        exit 1
    fi
    printf '%s' "$out"
}

SENTRY_VERSION=$(tool_field version)
SENTRY_SHA256=$(tool_field sha256)

# Validate the shape, don't just test for emptiness — a malformed but non-empty value is exactly
# what once reached curl and produced a "Malformed input" failure. The regex MUST stay quoted:
# this script is zsh, where quote removal would strip the backslash and degrade `\.` to `.`.
if [[ ! "$SENTRY_VERSION" =~ "^[0-9]+\.[0-9]+\.[0-9]+$" ]]; then
    echo "   ❌ Invalid sentry-cli version in .tools.json: [$SENTRY_VERSION]"
    exit 1
fi
if [[ ! "$SENTRY_SHA256" =~ "^[a-f0-9]{64}$" ]]; then
    echo "   ❌ Invalid sentry-cli sha256 in .tools.json: [$SENTRY_SHA256]"
    exit 1
fi

if command -v sentry-cli &> /dev/null; then
    # `|| true` is required, not defensive noise: under `set -eo pipefail` a `grep` that matches
    # nothing exits 1 and takes the whole script — and therefore the archive build — down with it.
    # An unreadable version simply means "unknown", which the pinned reinstall below handles.
    INSTALLED_VERSION=$(sentry-cli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "$INSTALLED_VERSION" == "$SENTRY_VERSION" ]]; then
        echo "   ✅ sentry-cli ${SENTRY_VERSION} already installed"
        exit 0
    fi
    echo "   ↻ sentry-cli ${INSTALLED_VERSION:-unknown} present, pinned is ${SENTRY_VERSION} — reinstalling"
fi

echo "   Downloading sentry-cli ${SENTRY_VERSION}..."
DOWNLOAD_PATH=$(mktemp -t sentry-cli)
# Retry transient network failures: one `curl (35) Recv failure: Connection reset by peer` from
# the release host used to fail an entire CI build.
curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 \
    -o "$DOWNLOAD_PATH" \
    "https://github.com/getsentry/sentry-cli/releases/download/${SENTRY_VERSION}/sentry-cli-Darwin-universal"

# Verification is mandatory — this installs an executable into /usr/local/bin.
echo "   Verifying SHA256 checksum..."
ACTUAL_SHA256=$(shasum -a 256 "$DOWNLOAD_PATH" | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$SENTRY_SHA256" ]]; then
    echo "   ❌ SHA256 checksum mismatch!"
    echo "      Expected: $SENTRY_SHA256"
    echo "      Actual:   $ACTUAL_SHA256"
    rm -f "$DOWNLOAD_PATH"
    exit 1
fi
echo "   ✅ SHA256 checksum verified"

mv "$DOWNLOAD_PATH" /usr/local/bin/sentry-cli
chmod +x /usr/local/bin/sentry-cli
echo "   ✅ sentry-cli ${SENTRY_VERSION} installed"
