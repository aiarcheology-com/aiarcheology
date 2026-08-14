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

# Verification is mandatory — this installs an executable onto the machine's PATH.
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

# Install into the first location the consumers already look in, rather than insisting on
# /usr/local/bin. `upload_symbols.sh` and `sentry_release.sh` both resolve
# PATH → /usr/local/bin → ${HOME}/bin, so the third rung already exists and needs no changes.
#
# Xcode Cloud runners do not grant write access to /usr/local/bin. Build 990 — the first release
# run of `release/1.0.7-2026-08-14` — died there with `Permission denied` *after*
# `CI_XCODEBUILD_EXIT_CODE=0`: the archive was fine and the workflow failed on its own tooling.
# Local machines with Homebrew do have that directory writable, which is why every local
# `deliver.sh` archive worked and this surfaced only on the first Xcode Cloud archive.
#
# Tested for writability rather than assumed from `$CI_XCODE_CLOUD`: the failure is about the
# directory, so the directory is what should be asked. That also covers a local machine without
# Homebrew, where the old code would have failed the same way.
if [[ -w /usr/local/bin ]]; then
    INSTALL_DIR="/usr/local/bin"
else
    # An unset HOME must be caught here, not further down. This script has no `set -u`, so
    # `${HOME}/bin` would silently become `/bin` — which exists, so `mkdir -p` succeeds and the
    # failure finally surfaces as a `mv: Permission denied` on /bin: the same confusing symptom
    # this change exists to remove, one directory over.
    if [[ -z "${HOME:-}" ]]; then
        echo "   ❌ /usr/local/bin is not writable and HOME is unset — nowhere to install sentry-cli"
        exit 1
    fi
    INSTALL_DIR="${HOME}/bin"
    mkdir -p "$INSTALL_DIR"
fi

mv "$DOWNLOAD_PATH" "${INSTALL_DIR}/sentry-cli"
chmod +x "${INSTALL_DIR}/sentry-cli"
echo "   ✅ sentry-cli ${SENTRY_VERSION} installed to ${INSTALL_DIR}"
