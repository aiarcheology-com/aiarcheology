#!/bin/bash
#
# Hermetic tests for deliver.sh's App Store Connect credential resolution (AIA-0475).
#
# The headline assertion is negative and therefore easy to get wrong by accident: with
# ios/asc.auth/ populated, deliver.sh must make ZERO 1Password calls. We prove it by putting an
# `op` stub first on PATH that FAILS and records every invocation — so a regression that reaches
# for 1Password cannot pass silently.
#
# No network, no Xcode, no simulator, no real credentials. Runs in about a second.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# An `op` that always fails and logs the attempt — the point is that it must never be reached.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/op" <<'STUB'
#!/bin/sh
echo "op $*" >> "$OP_CALL_LOG"
echo "op: (stub) refusing — this run should not have needed 1Password" >&2
exit 1
STUB
chmod +x "$WORK/bin/op"

# Source deliver.sh's functions without running main(). DELIVER_SH_NO_MAIN is honoured by the
# script's entrypoint guard.
load_deliver() { DELIVER_SH_NO_MAIN=1 . "${REPO_ROOT}/scripts/deliver.sh"; }

KEY_ID="62BW4FH93L"
ISSUER="69a6de70-03db-47e3-e053-5b8c7c11a4d1"

make_asc_auth() {
    local dir="$1"
    mkdir -p "$dir"
    printf '%s\n' "$KEY_ID" > "$dir/key-id"
    printf '%s\n' "$ISSUER" > "$dir/issuer-id"
    printf -- '-----BEGIN PRIVATE KEY-----\nMIGTAgEA\n-----END PRIVATE KEY-----\n' \
        > "$dir/AuthKey_${KEY_ID}.p8"
    chmod 700 "$dir"; chmod 600 "$dir"/*
}

echo "▸ deliver.sh credential resolution"

# ------------------------------------------------------------------------------------------------
# 1. Materialized credentials are used, and 1Password is never contacted.
# ------------------------------------------------------------------------------------------------
(
    export OP_CALL_LOG="$WORK/calls1.txt"; : > "$OP_CALL_LOG"
    export PATH="$WORK/bin:$PATH"
    load_deliver
    make_asc_auth "$ASC_AUTH_DIR.test"
    ASC_AUTH_DIR="$ASC_AUTH_DIR.test"
    ASC_KEY_ID='op://Personal/ASC/key id'
    ASC_ISSUER_ID='op://Personal/ASC/Issuer ID'
    ASC_KEY_OP_REF='op://Personal/ASC/AuthKey.p8'
    ASC_KEY_PATH=''
    resolve_asc_credentials >/dev/null

    [[ "$ASC_KEY_ID" == "$KEY_ID" ]]       || { echo "key id was '$ASC_KEY_ID'" >&2; exit 1; }
    [[ "$ASC_ISSUER_ID" == "$ISSUER" ]]    || { echo "issuer was '$ASC_ISSUER_ID'" >&2; exit 1; }
    [[ "$RESOLVED_KEY_PATH" == *"AuthKey_${KEY_ID}.p8" ]] || { echo "key path was '$RESOLVED_KEY_PATH'" >&2; exit 1; }
    [[ ! -s "$OP_CALL_LOG" ]]              || { echo "1Password WAS contacted:"; cat "$OP_CALL_LOG"; exit 1; }
    rm -rf "$ASC_AUTH_DIR"
) && pass "materialized credentials resolve with zero op calls" \
  || fail "materialized credentials resolve with zero op calls"

# ------------------------------------------------------------------------------------------------
# 2. An explicit ASC_KEY_PATH still wins over the materialized directory.
#    (Regression guard: "prefer asc.auth" must not hijack an operator's deliberate choice.)
# ------------------------------------------------------------------------------------------------
(
    export OP_CALL_LOG="$WORK/calls2.txt"; : > "$OP_CALL_LOG"
    export PATH="$WORK/bin:$PATH"
    load_deliver
    make_asc_auth "$ASC_AUTH_DIR.test"
    ASC_AUTH_DIR="$ASC_AUTH_DIR.test"
    printf -- '-----BEGIN PRIVATE KEY-----\nOTHER\n-----END PRIVATE KEY-----\n' > "$WORK/explicit.p8"
    # Only ASC_KEY_PATH is set. This is the case that ISOLATES the ASC_KEY_PATH guard: setting an
    # explicit ASC_KEY_ID too would be caught by a different guard, so the test would still pass
    # with the ASC_KEY_PATH check deleted (verified by mutation). Note deliver.sh:78-86 suppresses
    # sourcing ios/asc.env entirely once any explicit ASC_* var is set, which is why the id and
    # issuer are empty here rather than op:// references.
    ASC_KEY_ID=''
    ASC_ISSUER_ID=''
    ASC_KEY_PATH="$WORK/explicit.p8"
    ASC_KEY_OP_REF=''
    ( resolve_asc_credentials ) >/dev/null 2>&1 || true
    # Whatever happens, the operator's explicit key must never be silently swapped for the
    # materialized one. Capture the resolved path from a contained subshell.
    resolved="$( ( resolve_asc_credentials >/dev/null 2>&1; printf '%s' "$RESOLVED_KEY_PATH" ) || true )"
    [[ "$resolved" != *"AuthKey_${KEY_ID}.p8" ]] \
        || { echo "materialized dir hijacked an explicit ASC_KEY_PATH" >&2; exit 1; }
    [[ ! -s "$OP_CALL_LOG" ]] || { echo "1Password WAS contacted" >&2; exit 1; }
    rm -rf "$ASC_AUTH_DIR"
) && pass "explicit ASC_KEY_PATH overrides ios/asc.auth" \
  || fail "explicit ASC_KEY_PATH overrides ios/asc.auth"

# ------------------------------------------------------------------------------------------------
# 3. An incomplete directory does NOT silently half-resolve — it falls back to 1Password.
#    Here the stub's failure is the EXPECTED outcome.
# ------------------------------------------------------------------------------------------------
(
    export OP_CALL_LOG="$WORK/calls3.txt"; : > "$OP_CALL_LOG"
    export PATH="$WORK/bin:$PATH"
    load_deliver
    mkdir -p "$ASC_AUTH_DIR.test"
    printf '%s\n' "$KEY_ID" > "$ASC_AUTH_DIR.test/key-id"   # issuer-id and the .p8 are missing
    ASC_AUTH_DIR="$ASC_AUTH_DIR.test"
    ASC_KEY_ID='op://Personal/ASC/key id'
    ASC_ISSUER_ID='op://Personal/ASC/Issuer ID'
    ASC_KEY_OP_REF='op://Personal/ASC/AuthKey.p8'
    ASC_KEY_PATH=''
    # resolve_asc_credentials calls die(), which exits — contain it in its own subshell so the
    # assertions below still run.
    if ( resolve_asc_credentials ) >/dev/null 2>&1; then
        echo "an incomplete asc.auth was accepted" >&2; exit 1
    fi
    [[ -s "$OP_CALL_LOG" ]] || { echo "did not fall back to 1Password" >&2; exit 1; }
    rm -rf "$ASC_AUTH_DIR"
) && pass "incomplete ios/asc.auth falls back to 1Password instead of half-resolving" \
  || fail "incomplete ios/asc.auth falls back to 1Password instead of half-resolving"

# ------------------------------------------------------------------------------------------------
# 4. A tampered key-id is rejected rather than interpolated into a path.
# ------------------------------------------------------------------------------------------------
(
    export OP_CALL_LOG="$WORK/calls4.txt"; : > "$OP_CALL_LOG"
    export PATH="$WORK/bin:$PATH"
    load_deliver
    make_asc_auth "$ASC_AUTH_DIR.test"
    ASC_AUTH_DIR="$ASC_AUTH_DIR.test"
    printf '%s\n' '../../../../tmp/evil' > "$ASC_AUTH_DIR/key-id"
    ASC_KEY_ID=''; ASC_ISSUER_ID=''; ASC_KEY_OP_REF=''; ASC_KEY_PATH=''

    err="$( ( resolve_asc_credentials ) 2>&1 >/dev/null || true )"
    # Assert on WHICH check rejected it. Merely asserting failure is vacuous: a traversal path also
    # happens not to exist, so the file-missing check fires and the test passes even with the
    # validation deleted (verified by mutation). Only the identifier check makes this test binding.
    case "$err" in
        *"not a plain identifier"*) : ;;
        *) echo "rejected, but not by identifier validation. stderr was: $err" >&2; exit 1 ;;
    esac
    rm -rf "$ASC_AUTH_DIR"
) && pass "a path-traversal key-id is rejected" \
  || fail "a path-traversal key-id is rejected"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "✅ deliver.sh credential resolution: all checks passed"
else
    echo "❌ deliver.sh credential resolution: ${FAILURES} check(s) failed" >&2
    exit 1
fi
