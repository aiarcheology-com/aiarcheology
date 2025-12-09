#!/bin/zsh
# ci_post_clone.sh
# ================
# Xcode Cloud build script that runs ONCE after cloning the repository.
# Use this for one-time setup that applies to all actions (build, test, archive, analyze).
#
# See: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts

set -eo pipefail

echo "🔧 Running ci_post_clone.sh..."

# --- Install sentry-cli ---
# Install once here so it's available for all subsequent build actions

echo "📦 Installing sentry-cli..."

if command -v sentry-cli &> /dev/null; then
    echo "   ✅ sentry-cli already available: $(which sentry-cli)"
    sentry-cli --version
else
    # Homebrew is available on Xcode Cloud macOS images
    if command -v brew &> /dev/null; then
        brew install getsentry/tools/sentry-cli
        echo "   ✅ sentry-cli installed via Homebrew"
    else
        # Fallback to direct download
        curl -sL https://sentry.io/get-cli/ | INSTALL_DIR=/usr/local/bin bash
        echo "   ✅ sentry-cli installed to /usr/local/bin"
    fi
    sentry-cli --version
fi

echo "✅ ci_post_clone.sh completed successfully"
