#!/bin/bash
#
# scripts/localization.sh — String Catalog check. Same gate the Localization CI workflow runs.
#
# English is the language the app is authored in, so its authored-key count is the expected count
# for all 16 other locales. Add strings in code and translate none, and this fails with the exact
# slot counts. It also catches the two subtler ways a string goes untranslated: a hardcoded SwiftUI
# literal (auto-extracted, so it never reaches L10n.swift and no locale can ever translate it), and
# an orphaned translation left behind by a rename.
#
# Pure Python over the catalog JSON — no Xcode, no simulator, no network. Runs in about a second.
#
# Usage:
#   ./scripts/localization.sh              # report + verify (the gate)
#   ./scripts/localization.sh report       # per-locale coverage only
#   ./scripts/localization.sh export <dir> # write per-locale worklists of what needs translating
#   ./scripts/localization.sh merge <dir>  # merge translated <locale>.json files back in
#   ./scripts/localization.sh --help
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO_ROOT}/scripts/xcstrings_tool.py"

PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null 2>&1 || {
    echo "Error: python3 not found. It is the only requirement." >&2
    exit 1
}

show_help() {
    sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-check}" in
    --help|-h|help)
        show_help
        ;;

    report)
        "$PYTHON" "$TOOL" report
        ;;

    export)
        [[ $# -ge 2 ]] || { echo "Usage: $0 export <dir> [--include-restricted]" >&2; exit 2; }
        shift
        out="$1"; shift
        "$PYTHON" "$TOOL" export --out "$out" "$@"
        ;;

    merge)
        [[ $# -ge 2 ]] || { echo "Usage: $0 merge <dir>" >&2; exit 2; }
        "$PYTHON" "$TOOL" merge --source "$2"
        ;;

    check|verify)
        # Coverage first so a failure below is read against real numbers, then the gate itself.
        "$PYTHON" "$TOOL" report
        echo
        if ! "$PYTHON" "$TOOL" verify --strict-parity --limit 60; then
            cat >&2 <<'EOF'

Some strings are not present in every locale. Fix them with the same tool — never hand-edit the
catalog, which is ~41 000 lines of Xcode-owned JSON:

  ./scripts/localization.sh export /tmp/worklists
  # translate each /tmp/worklists/<locale>.source.json into /tmp/translations/<locale>.json
  ./scripts/localization.sh merge  /tmp/translations
  ./scripts/localization.sh

Legal and billing copy (paywall.*, subscription.*, settings.subscription.*, auth.account.delete.*)
is held back from a routine pass: add --include-restricted to export, and use Apple's own store
terminology for it. See AIA-0575.
EOF
            exit 1
        fi
        echo
        "$PYTHON" "$TOOL" check
        ;;

    *)
        echo "Unknown subcommand: $1" >&2
        show_help >&2
        exit 2
        ;;
esac
