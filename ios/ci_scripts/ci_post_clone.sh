#!/bin/zsh
# ci_post_clone.sh
# ================
# Xcode Cloud build script that runs ONCE after cloning the repository.
# Use this for one-time setup that applies to all actions (build, test, archive, analyze).
#
# See: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts

set -eo pipefail

echo "🔧 Running ci_post_clone.sh..."

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

# --- Install SwiftLint ---
echo "📦 Installing SwiftLint..."

if command -v swiftlint &> /dev/null; then
    echo "   ✅ SwiftLint already available: $(which swiftlint)"
    swiftlint version
else
    if command -v brew &> /dev/null; then
        brew install swiftlint
        echo "   ✅ SwiftLint installed via Homebrew"
        swiftlint version
    else
        echo "   ⚠️  Homebrew not available, skipping SwiftLint installation"
    fi
fi

# --- Install sentry-cli ---
# Install once here so it's available for all subsequent build actions

echo "📦 Installing sentry-cli..."

if command -v sentry-cli &> /dev/null; then
    echo "   ✅ sentry-cli already available: $(which sentry-cli)"
    sentry-cli --version
else
    # Try Homebrew first (available on Xcode Cloud macOS images)
    if command -v brew &> /dev/null; then
        if brew install getsentry/tools/sentry-cli; then
            echo "   ✅ sentry-cli installed via Homebrew"
            sentry-cli --version
        else
            echo "   ⚠️  Homebrew installation failed, trying direct download..."
            # Fallback to direct download
            curl -sL https://sentry.io/get-cli/ | INSTALL_DIR=/usr/local/bin bash
            echo "   ✅ sentry-cli installed via direct download"
            sentry-cli --version
        fi
    else
        # Direct download if Homebrew not available
        curl -sL https://sentry.io/get-cli/ | INSTALL_DIR=/usr/local/bin bash
        echo "   ✅ sentry-cli installed to /usr/local/bin"
        sentry-cli --version
    fi
fi

echo "✅ ci_post_clone.sh completed successfully"
