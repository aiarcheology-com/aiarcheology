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

    # Fallback: Install SwiftLint manually
    if ! command -v swiftlint &> /dev/null; then
        if command -v brew &> /dev/null; then
            brew install swiftlint || echo "   ⚠️  SwiftLint installation failed"
        fi
    fi

    # Fallback: Install sentry-cli manually (with curl fallback)
    if ! command -v sentry-cli &> /dev/null; then
        if command -v brew &> /dev/null; then
            brew install getsentry/tools/sentry-cli || \
                curl -sL https://sentry.io/get-cli/ | INSTALL_DIR=/usr/local/bin bash
        else
            curl -sL https://sentry.io/get-cli/ | INSTALL_DIR=/usr/local/bin bash
        fi
    fi
fi

# --- Verify tools are available ---
echo ""
echo "📋 Verifying tool availability..."
echo "   swiftlint: $(swiftlint version 2>/dev/null || echo 'not installed')"
echo "   sentry-cli: $(sentry-cli --version 2>/dev/null || echo 'not installed')"

echo ""
echo "✅ ci_post_clone.sh completed successfully"
