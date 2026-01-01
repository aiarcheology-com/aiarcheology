#!/bin/zsh
# ci_post_clone.sh
# ================
# Xcode Cloud build script that runs ONCE after cloning the repository.
# Use this for one-time setup that applies to all actions (build, test, archive, analyze).
#
# See: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts

set -eo pipefail

echo "🔧 Running ci_post_clone.sh..."

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

echo ""
echo "📦 Running ProjectTool setup..."

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(git rev-parse --show-toplevel)}"

if swift run --package-path Tools ProjectTool setup --install; then
    echo "   ✅ ProjectTool setup completed"
else
    echo "   ⚠️  ProjectTool setup failed, attempting manual fallback..."

    # Fallback: Install SwiftLint via direct download (pinned version)
    if ! command -v swiftlint &> /dev/null; then
        echo "   Installing SwiftLint fallback..."
        SWIFTLINT_VERSION="0.62.2"
        curl -fsSL -o /tmp/swiftlint.zip "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
        unzip -q /tmp/swiftlint.zip -d /tmp/swiftlint
        cp /tmp/swiftlint/swiftlint /usr/local/bin/swiftlint
        chmod +x /usr/local/bin/swiftlint
        rm -rf /tmp/swiftlint /tmp/swiftlint.zip
        echo "   ✅ SwiftLint ${SWIFTLINT_VERSION} installed"
    fi

    # Fallback: Install sentry-cli via direct download (pinned version)
    if ! command -v sentry-cli &> /dev/null; then
        echo "   Installing sentry-cli fallback..."
        SENTRY_VERSION="2.58.2"
        curl -fsSL -o /usr/local/bin/sentry-cli "https://github.com/getsentry/sentry-cli/releases/download/${SENTRY_VERSION}/sentry-cli-Darwin-universal"
        chmod +x /usr/local/bin/sentry-cli
        echo "   ✅ sentry-cli ${SENTRY_VERSION} installed"
    fi
fi

# --- Verify tools are available ---
echo ""
echo "📋 Verifying tool availability..."
echo "   swiftlint: $(swiftlint version 2>/dev/null || echo 'not installed')"
echo "   sentry-cli: $(sentry-cli --version 2>/dev/null || echo 'not installed')"

echo ""
echo "✅ ci_post_clone.sh completed successfully"
