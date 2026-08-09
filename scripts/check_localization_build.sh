#!/bin/bash
#
# Build the app and prove Xcode did not rewrite either source String Catalog.
#
# Xcode's String Catalog extraction is source-mutating when the committed catalog has drifted
# from the literals in the target. A normal localization check cannot see that: it only parses the
# already-committed JSON. This guard snapshots both catalogs, performs the CI-shaped build, and
# compares the bytes afterwards. It therefore catches both semantic drift and a future Xcode
# re-serialization before either can be staged in a pull request.
#
# The project is used deliberately instead of the workspace: this guard only needs the app's build
# products, while the workspace additionally schedules the package test products. The app target
# still resolves all of its package dependencies, so the check exercises the same catalog-producing
# build phase with less unrelated work.
#
# Usage:
#   ./scripts/check_localization_build.sh
#   DERIVED_DATA_PATH=/tmp/derived XCODEBUILD_DESTINATION='generic/platform=iOS Simulator' \
#     ./scripts/check_localization_build.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

DERIVED_DATA="${DERIVED_DATA_PATH:-${REPO_ROOT}/.deriveddata-localization}"
DESTINATION="${XCODEBUILD_DESTINATION:-generic/platform=iOS Simulator}"

localizable_snapshot="$(mktemp)"
infoplist_snapshot="$(mktemp)"
cleanup() {
    rm -f "${localizable_snapshot}" "${infoplist_snapshot}"
}
trap cleanup EXIT

cp ios/MLBrowser/iOS/Resources/Localizable.xcstrings "${localizable_snapshot}"
cp ios/MLBrowser/iOS/Resources/InfoPlist.xcstrings "${infoplist_snapshot}"
status_before="$(git status --short)"

echo "Building MLBrowser to verify String Catalog stability…"
XCODEBUILD_ARGS=(
    build-for-testing
    -quiet
    -project ios/MLBrowser.xcodeproj
    -scheme MLBrowser
    -destination "${DESTINATION}"
    -derivedDataPath "${DERIVED_DATA}"
    -skipPackagePluginValidation
    -skipMacroValidation
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)
if [[ -n "${SPM_CACHE_PATH:-}" ]]; then
    XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${SPM_CACHE_PATH}")
fi
xcodebuild "${XCODEBUILD_ARGS[@]}"

changed=0
for pair in \
    "${localizable_snapshot}:ios/MLBrowser/iOS/Resources/Localizable.xcstrings" \
    "${infoplist_snapshot}:ios/MLBrowser/iOS/Resources/InfoPlist.xcstrings"; do
    snapshot="${pair%%:*}"
    catalog="${pair#*:}"
    if ! cmp -s "${snapshot}" "${catalog}"; then
        changed=1
        echo "::error::Xcode rewrote ${catalog} during the build."
        # `git diff --no-index` is informational; it exits 1 when files differ, so keep it in an
        # `if` under `set -e`.
        if ! git diff --no-index -- "${snapshot}" "${catalog}"; then
            true
        fi
    fi
done

if [[ "${changed}" -ne 0 ]]; then
    echo "Restore the catalog from the build snapshot, reconcile it with xcstrings_tool.py, and rerun this guard."
    exit 1
fi

status_after="$(git status --short)"
if [[ "${status_after}" != "${status_before}" ]]; then
    echo "::error::The build changed tracked or untracked repository files:"
    diff -u <(printf '%s\n' "${status_before}") <(printf '%s\n' "${status_after}") || true
    exit 1
fi

echo "String Catalogs unchanged by build."
