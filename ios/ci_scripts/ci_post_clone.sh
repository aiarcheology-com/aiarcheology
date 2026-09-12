#!/bin/zsh
# ci_post_clone.sh
# ================
# Xcode Cloud build script that runs ONCE after cloning the repository.
# Use this for one-time setup that applies to all actions (build, test, archive, analyze).
#
# See: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts

set -eo pipefail

echo "🔧 Running ci_post_clone.sh..."

# --- Check for [ci skip] in commit message ---
# If present, exit early to save build minutes
COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "")
if [[ "$COMMIT_MSG" == *"[ci skip]"* ]] || [[ "$COMMIT_MSG" == *"[skip ci]"* ]]; then
    echo "⏭️  Found [ci skip] in commit message - stopping build"
    echo "   Commit message: $(git log -1 --pretty=%s 2>/dev/null)"
    exit 1
fi
echo "   ✅ No [ci skip] flag - proceeding with build"

# --- Ensure PATH includes common binary locations ---
# Xcode Cloud may use Intel (/usr/local/bin) or Apple Silicon (/opt/homebrew/bin)
# ProjectTool installs to /usr/local/bin by default
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
echo "   PATH configured for Intel and Apple Silicon compatibility"

# --- Disable Xcode package plugin + macro validation ---
# Only do this on Xcode Cloud (avoid mutating local developer machines if run manually)
if [[ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
  echo "⏭️  Not running on Xcode Cloud (CI_PRIMARY_REPOSITORY_PATH not set) - skipping Xcode defaults"
else
  echo "🔐 Disabling Xcode package plugin + macro validation (CI only)..."

  # Skip Macro Validation
  defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

  # Skip Package Plugin Validation
  defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

  echo "   ✅ Successfully disabled Macro and Plugin validation."
fi

# --- Install required tools via ProjectTool ---
# Uses .tools.json for version pinning
# Skips git configuration in CI (detected via CI env var)
#
# Only swiftlint and swiftgen are installed here: every action needs them (swiftgen generates
# L10n.swift, so the app doesn't even compile without it). sentry-cli is deliberately NOT
# installed — it is used solely by ci_post_xcodebuild.sh for archive builds, which installs it
# itself. Downloading it for every test/build workflow only exposed the most frequently run
# workflows to release-host flakiness: one connection reset here aborts the whole build (this
# script runs under `set -eo pipefail`), and the failure looks like a test failure.

echo ""
echo "📦 Running ProjectTool setup..."

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(git rev-parse --show-toplevel)}"

if swift run --package-path Tools ProjectTool setup --only swiftlint --only swiftgen; then
    echo "   ✅ ProjectTool setup completed"
else
    echo "   ⚠️  ProjectTool setup failed, attempting manual fallback..."

    # Parse .tools.json to extract tool versions dynamically
    TOOLS_JSON="${CI_PRIMARY_REPOSITORY_PATH:-$(git rev-parse --show-toplevel)}/.tools.json"
    
    if [[ ! -f "$TOOLS_JSON" ]]; then
        echo "   ❌ .tools.json not found at $TOOLS_JSON"
        exit 1
    fi

    # .tools.json is JSON and needs a real parser (AGENTS.md §10). plutil ships with macOS,
    # so it needs no install on a runner — unlike jq.
    #
    # The previous `grep -A 10 '"tool"' | grep '"version"'` matched a fixed 10-line window, so
    # it captured the *next* tool's value whenever a block's field count changed. SwiftLint has
    # one field fewer than SwiftGen, so its window reached into SwiftGen and yielded
    # "0.62.2\n6.6.3" — a URL with an embedded newline, i.e. curl (3) "Malformed input".
    # A read failure is fatal: every tool in .tools.json pins both keys, so a failure means the
    # file or the key is wrong — never something to paper over. plutil's own message is
    # surfaced instead of discarded, so malformed JSON doesn't masquerade as an empty value.
    tool_field() {  # $1 = tool name, $2 = field
        local out
        if ! out=$(plutil -extract "tools.$1.$2" raw -o - "$TOOLS_JSON" 2>&1); then
            echo "   ❌ Cannot read tools.$1.$2 from .tools.json: $out" >&2
            exit 1
        fi
        printf '%s' "$out"
    }

    # Validate the shape, don't just test for emptiness: the value that broke the build was
    # non-empty, so the old `-z` guard passed it straight to curl.
    #
    # The regex MUST stay quoted. This script is zsh, where quote removal strips the backslash
    # before the ERE engine sees it — unquoted, `\.` degrades to `.` (any character) and the
    # pattern then accepts `1/2.3` (a different release path) and even newline-bearing values,
    # i.e. exactly the bug this is meant to catch. Quoting in zsh keeps it a live regex.
    require_version() {  # $1 = value, $2 = tool name
        if [[ ! "$1" =~ "^[0-9]+\.[0-9]+\.[0-9]+$" ]]; then
            echo "   ❌ Invalid $2 version in .tools.json: [$1]"
            exit 1
        fi
    }

    require_sha256() {  # $1 = value, $2 = tool name
        if [[ ! "$1" =~ "^[a-f0-9]{64}$" ]]; then
            echo "   ❌ Invalid $2 sha256 in .tools.json: [$1]"
            exit 1
        fi
    }

    # Where a downloaded tool can actually land. Xcode Cloud runners do not grant write access to
    # /usr/local/bin, and this script runs under `set -eo pipefail`, so a `cp` there aborts the
    # whole build before Xcode compiles anything — with a permission error that looks nothing like
    # a build problem. Xcode Cloud build 990 hit the same wall in install_sentry_cli.sh (AIA-0632).
    # Writability is tested rather than inferred from a CI variable: the failure is about the
    # directory, so the directory is what gets asked.
    if [[ -w /usr/local/bin ]]; then
        TOOL_BIN_DIR="/usr/local/bin"
    elif [[ -n "${HOME:-}" ]]; then
        TOOL_BIN_DIR="${HOME}/bin"
        mkdir -p "$TOOL_BIN_DIR"
        export PATH="${TOOL_BIN_DIR}:$PATH"
    else
        echo "   ❌ /usr/local/bin is not writable and HOME is unset — nowhere to install tools"
        exit 1
    fi

    # Fallback: Install SwiftLint via direct download (version from .tools.json)
    if ! command -v swiftlint &> /dev/null; then
        echo "   Installing SwiftLint fallback..."
        SWIFTLINT_VERSION=$(tool_field swiftlint version)
        SWIFTLINT_SHA256=$(tool_field swiftlint sha256)

        require_version "$SWIFTLINT_VERSION" "SwiftLint"

        # Retry transient network failures. THIS path is where the reported incident actually
        # died (`curl (35) Recv failure` while fetching SwiftLint), so it needs the retries at
        # least as much as ProjectTool's downloader does (review).
        curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 \
            -o /tmp/swiftlint.zip "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
        
        # Verification is mandatory — this installs an executable into /usr/local/bin.
        require_sha256 "$SWIFTLINT_SHA256" "SwiftLint"
        echo "   Verifying SHA256 checksum..."
        ACTUAL_SHA256=$(shasum -a 256 /tmp/swiftlint.zip | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$SWIFTLINT_SHA256" ]]; then
            echo "   ❌ SHA256 checksum mismatch!"
            echo "      Expected: $SWIFTLINT_SHA256"
            echo "      Actual:   $ACTUAL_SHA256"
            exit 1
        fi
        echo "   ✅ SHA256 checksum verified"
        
        unzip -q /tmp/swiftlint.zip -d /tmp/swiftlint
        cp /tmp/swiftlint/swiftlint "${TOOL_BIN_DIR}/swiftlint"
        chmod +x "${TOOL_BIN_DIR}/swiftlint"
        rm -rf /tmp/swiftlint /tmp/swiftlint.zip
        echo "   ✅ SwiftLint ${SWIFTLINT_VERSION} installed"
    fi

    # Fallback: Install SwiftGen via direct download (version from .tools.json)
    if ! command -v swiftgen &> /dev/null; then
        echo "   Installing SwiftGen fallback..."
        SWIFTGEN_VERSION=$(tool_field swiftgen version)
        SWIFTGEN_SHA256=$(tool_field swiftgen sha256)

        require_version "$SWIFTGEN_VERSION" "SwiftGen"

        curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 \
            -o /tmp/swiftgen.zip "https://github.com/SwiftGen/SwiftGen/releases/download/${SWIFTGEN_VERSION}/swiftgen-${SWIFTGEN_VERSION}.zip"

        # Verification is mandatory — this installs an executable into /usr/local/bin.
        require_sha256 "$SWIFTGEN_SHA256" "SwiftGen"
        echo "   Verifying SHA256 checksum..."
        ACTUAL_SHA256=$(shasum -a 256 /tmp/swiftgen.zip | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$SWIFTGEN_SHA256" ]]; then
            echo "   ❌ SHA256 checksum mismatch!"
            echo "      Expected: $SWIFTGEN_SHA256"
            echo "      Actual:   $ACTUAL_SHA256"
            exit 1
        fi
        echo "   ✅ SHA256 checksum verified"

        unzip -q /tmp/swiftgen.zip -d /tmp/swiftgen
        cp /tmp/swiftgen/bin/swiftgen "${TOOL_BIN_DIR}/swiftgen"
        chmod +x "${TOOL_BIN_DIR}/swiftgen"
        rm -rf /tmp/swiftgen /tmp/swiftgen.zip
        echo "   ✅ SwiftGen ${SWIFTGEN_VERSION} installed"
    fi

    # sentry-cli is intentionally absent from this fallback: only archive builds use it, and
    # ci_post_xcodebuild.sh installs it there (see install_sentry_cli.sh).
fi

# --- Verify tools are available ---
echo ""
echo "📋 Verifying tool availability..."
echo "   swiftlint: $(swiftlint version 2>/dev/null || echo 'not installed')"
echo "   swiftgen: $(swiftgen --version 2>/dev/null || echo 'not installed')"
echo "   sentry-cli: installed on demand by archive builds (ci_post_xcodebuild.sh)"

echo ""
echo "✅ ci_post_clone.sh completed successfully"
