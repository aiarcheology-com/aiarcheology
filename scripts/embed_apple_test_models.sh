#!/bin/bash
# Xcode build phase: embed an already-fetched fixture only in explicitly opted-in Debug builds.
# No network access here. Ordinary and Release builds remove any stale fixture from their product.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR is required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode resource path is required}"
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
fixture_name=FastViTT8F16
# Only these known, generated resources are removed; never delete a build/cache directory.
rm -rf "${resources}/${fixture_name}.mlmodelc" "${resources}/FastViT-LICENSE.txt" "${resources}/FastViT-ACKNOWLEDGEMENTS.txt"
if [[ "${AIA_INCLUDE_TEST_FIXTURES:-NO}" != YES ]]; then
    echo 'Apple test fixtures disabled.'
    exit 0
fi
if [[ "${CONFIGURATION:-}" != Debug ]]; then
    echo 'error: Apple test fixtures are allowed only in Debug test builds.' >&2
    exit 1
fi
if ! "${REPO_ROOT}/scripts/fetch_apple_test_models.sh" --verify; then
    echo 'error: Run ./scripts/fetch_apple_test_models.sh before building with AIA_INCLUDE_TEST_FIXTURES=YES.' >&2
    exit 1
fi
mkdir -p "$resources"
xcrun coremlcompiler compile "${REPO_ROOT}/.apple-test-fixtures/${fixture_name}.mlpackage" "$resources"
cp "${REPO_ROOT}/ios/TestFixtures/FastViT/FastViT-LICENSE.txt" "$resources/"
cp "${REPO_ROOT}/ios/TestFixtures/FastViT/FastViT-ACKNOWLEDGEMENTS.txt" "$resources/"
