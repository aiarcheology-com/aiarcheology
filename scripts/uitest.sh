#!/bin/bash
#
# scripts/uitest.sh — Run the UI test plan on an iPhone AND an iPad, in one invocation.
#
# Why both, always (AIA-0626): this app is deliberately not device-agnostic. `HostPlatform`
# resolves `.iPadOS` from `userInterfaceIdiom`, `Testability.Checkpoint.deviceIdiom` exists because
# the idiom drives chrome layout (AIA-0294), and SwiftUI itself differs — a `.confirmationDialog`
# is a popover on iPad that omits cancel-role actions, and a Settings sheet does not cover the app
# behind it. So a UI suite that ran on one family has not tested the app; it has tested half of it.
#
# That is not hypothetical. `AnalyticsChoiceUITests.testRestoreDefaults…` passed on iPhone and
# failed on iPad for as long as it existed, because it looked a back button up as
# `app.navigationBars.buttons.element(boundBy: 0)` and on iPad index 0 belongs to the drawer behind
# the sheet. It reached Xcode Cloud red after a local sweep had been reported green — the sweep was
# ad-hoc and iPhone-only, because before this script there was no lane to be non-ad-hoc with.
#
# Deliberately NOT rotating device families by wall clock (a rejected proposal, recorded so it is
# not re-proposed): red/green would depend on the hour, one family would go unexercised on every
# run, and a failure could not be re-run in the same configuration without waiting.
#
# Usage:
#   ./scripts/uitest.sh                       # whole plan, iPhone + iPad
#   ./scripts/uitest.sh --iphone              # one family (fast loop; NOT a green sweep)
#   ./scripts/uitest.sh --ipad
#   ./scripts/uitest.sh -only-testing:MLBrowserUITests/FooUITests/testBar   # extra args pass through
#
# Environment:
#   DERIVED_DATA_PATH   build cache location (default ./.deriveddata-ui)
#   SPM_CACHE_PATH      SPM package cache (for CI)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

WANT_IPHONE=1
WANT_IPAD=1
PASSTHROUGH=()

for arg in "$@"; do
    case "$arg" in
        --iphone) WANT_IPAD=0 ;;
        --ipad)   WANT_IPHONE=0 ;;
        --help|-h) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) PASSTHROUGH+=("$arg") ;;
    esac
done

# Pick the named family's simulator on the NEWEST iOS runtime, mirroring unittest.sh: simctl reports
# devices on runtimes below the deployment target as "available" while xcodebuild rejects them as
# destinations, and the newest runtime is always >= the target on a sane install.
pick_simulator() {
    local family="$1"
    xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, re, sys
family = sys.argv[1]
data = json.load(sys.stdin)
best = None  # ((major, minor), udid, name)
for runtime, devices in data.get('devices', {}).items():
    match = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for d in devices:
        if not d.get('isAvailable'):
            continue
        name = d.get('name', '')
        if not name.startswith(family):
            continue
        if best is None or version > best[0]:
            best = (version, d['udid'], name)
if best is None:
    sys.exit(1)
print(f'{best[1]}\t{best[2]}')
" "$family" 2>/dev/null
}

DESTINATIONS=()
LABELS=()

add_family() {
    local family="$1" picked udid name
    if ! picked="$(pick_simulator "$family")"; then
        echo "❌ No available ${family} simulator found."
        echo "   Install one via Xcode > Settings > Platforms, or scope the run with --iphone / --ipad."
        exit 1
    fi
    udid="${picked%%$'\t'*}"
    name="${picked##*$'\t'}"
    DESTINATIONS+=(-destination "platform=iOS Simulator,id=${udid}")
    LABELS+=("${name} (${udid})")
}

[[ $WANT_IPHONE -eq 1 ]] && add_family "iPhone"
[[ $WANT_IPAD  -eq 1 ]] && add_family "iPad"

DERIVED_DATA="${DERIVED_DATA_PATH:-${REPO_ROOT}/.deriveddata-ui}"

echo "Running MLBrowser UI tests..."
for label in "${LABELS[@]}"; do
    echo "Destination: ${label}"
done
if [[ ${#LABELS[@]} -lt 2 ]]; then
    # Said loudly and every time: a one-family run is a fast loop, not evidence. The whole point of
    # this script is that "UI tests green" must not be ambiguous about which family it covered.
    echo "⚠️  ONE DEVICE FAMILY ONLY — this is not a full sweep. Re-run without --iphone/--ipad before"
    echo "    claiming the UI suite is green."
fi
echo ""

# No CODE_SIGNING_ALLOWED=NO / CODE_SIGNING_REQUIRED=NO here, deliberately — see the long note in
# unittest.sh (AGENTS §13): entitlements are embedded by the codesign step, so an unsigned binary
# belongs to no keychain access group, and on this machine the simulator additionally refuses to
# launch it, surfacing as a flat "tests failed" with zero assertion failures in the log.
XCODEBUILD_ARGS=(
    test
    -workspace ios/MLBrowser.xcworkspace
    -scheme MLBrowser
    -testPlan MLBrowserUITests
    "${DESTINATIONS[@]}"
    -derivedDataPath "${DERIVED_DATA}"
    -skipPackagePluginValidation
    -skipMacroValidation
)

if [[ -n "${SPM_CACHE_PATH:-}" ]]; then
    XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${SPM_CACHE_PATH}")
fi

if [[ ${#PASSTHROUGH[@]} -gt 0 ]]; then
    XCODEBUILD_ARGS+=("${PASSTHROUGH[@]}")
fi

# The if-form, not `xcodebuild …; rc=$?`: under `set -e` the latter aborts before the capture, so
# the failure branch would be dead code and the real exit status (65 for test failures) would be
# lost. Never report this lane's result from a trailing command's status — that is how a run that
# exited 65 got read as green (AGENTS §13).
if xcodebuild "${XCODEBUILD_ARGS[@]}"; then
    echo ""
    echo "UI tests completed successfully on: ${LABELS[*]}"
else
    TEST_EXIT_CODE=$?
    echo ""
    echo "UI tests FAILED (xcodebuild exit ${TEST_EXIT_CODE}) on one or more of: ${LABELS[*]}"
    echo "Which destination failed is in the log above — a multi-destination run reports per-device."
    exit $TEST_EXIT_CODE
fi
