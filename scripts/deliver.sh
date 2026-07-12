#!/bin/bash
#
# scripts/deliver.sh — Local archive → TestFlight delivery lane (Xcode Cloud fallback).
#
# Emergency lane for when Xcode Cloud is unavailable (allocation exhausted, outage). Archives the
# MLBrowser app locally, uploads it to App Store Connect (TestFlight), and pushes the tester-facing
# "What to Test" notes — all authenticated with an App Store Connect API key (never your Apple ID).
#
# Subcommands:
#   deliver   Preflight -> archive -> export -> validate -> upload to App Store Connect.
#   validate  Preflight -> archive -> export -> validate against App Store Connect (NO upload) —
#             the CLI equivalent of Xcode Organizer's "Validate App".
#   notes     Get-or-create the build's en-US "What to Test" from ios/TestFlight/WhatToTest.en-US.txt.
#   selftest  Offline self-tests (ES256 JWT sign/verify + dry-run redaction). No credentials needed.
#
# Usage:
#   ./scripts/deliver.sh deliver  [--build-number N] [--dry-run] [--skip-validate] [--export-only]
#                                 [--ref <tag|sha>] [--skip-tests] [--allow-dirty] [--online-preflight]
#   ./scripts/deliver.sh validate [--build-number N] [--dry-run] [--ref <tag|sha>] [--skip-tests] [--allow-dirty]
#   ./scripts/deliver.sh notes    [--build-number N] [--dry-run]
#   ./scripts/deliver.sh selftest
#   ./scripts/deliver.sh --help
#
# `deliver` validates the archive against App Store Connect (like Xcode's "Validate App") BEFORE
# uploading; --skip-validate bypasses that gate. Validation uses `xcrun altool` (deprecated but the
# only CLI that does pre-upload validation); the upload itself uses xcodebuild and does not depend on it.
#
# Credentials (App Store Connect API key — see README "Emergency delivery lane"):
#   ASC_KEY_ID       Key ID (or an op:// 1Password secret reference).
#   ASC_ISSUER_ID    Issuer ID (or an op:// reference).
#   ASC_KEY_PATH     Path to the AuthKey_XXXX.p8 file,  OR
#   ASC_KEY_OP_REF   A 1Password secret reference whose contents are the .p8 body.
#
# --dry-run makes NO network call, NO 1Password read, and NO JWT: it prints the exact commands it
# would run (auth redacted) and requires --build-number (App Store Connect is not queried offline).
# Downgraded preflight checks print "WOULD FAIL LIVE: ...".
#
# This script performs NO destructive local action. `deliver` (without --dry-run) uploads a build to
# App Store Connect and `notes` writes tester notes — both are outward, so run `--dry-run` first.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- project constants (see README / ios/ARCHITECTURE.md) --------------------------------------
WORKSPACE="${REPO_ROOT}/ios/MLBrowser.xcworkspace"
SCHEME="MLBrowser"
CONFIGURATION="Release"
BUNDLE_ID="com.aiarcheology.ios"
TEAM_ID="ZLR4X4U8UQ"
EXPORT_OPTIONS="${REPO_ROOT}/ios/ExportOptions.plist"
WHATSNEW_FILE="${REPO_ROOT}/ios/TestFlight/WhatToTest.en-US.txt"
BUILD_DIR="${REPO_ROOT}/build/delivery"                 # gitignored (.gitignore: build/)
ARCHIVE_PATH="${BUILD_DIR}/MLBrowser.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"                       # IPA for validation / --export-only
UPLOAD_PATH="${BUILD_DIR}/upload"                       # xcodebuild upload output/receipt
DERIVED_DATA="${BUILD_DIR}/DerivedData"                 # pinned: never share the open Xcode's DerivedData
ASC_HOST="https://api.appstoreconnect.apple.com"
JWT_TTL=900                                             # 15 min (App Store Connect max is 20)
WHATSNEW_MAX=4000                                       # App Store Connect whatsNew limit

# ---- flags / state -----------------------------------------------------------------------------
SUBCOMMAND=""
DRY_RUN=0
BUILD_NUMBER=""
SKIP_TESTS=0
ALLOW_DIRTY=0
ONLINE_PREFLIGHT=0
EXPORT_ONLY=0
VALIDATE_ONLY=0                                          # set by the `validate` subcommand
SKIP_VALIDATE=0
REF=""
PREFLIGHT_WOULD_FAIL=0

# Convenience: source ios/asc.env (op:// references for the ASC key) if present AND the caller has
# not already provided the credentials in the environment. Explicit env vars always win; the file is
# a fallback so operators don't re-export three vars every session. It holds references, not secrets.
if [[ -z "${ASC_KEY_ID:-}${ASC_KEY_PATH:-}${ASC_KEY_OP_REF:-}" && -f "${REPO_ROOT}/ios/asc.env" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/ios/asc.env"
fi

# ASC credentials (resolved lazily; never echoed).
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_KEY_OP_REF="${ASC_KEY_OP_REF:-}"
RESOLVED_KEY_PATH=""

# All temp files (the .p8 private key, cached ASC responses, the export-only plist) live under one
# parent-owned dir so cleanup removes them regardless of which subshell created them. (A per-file
# array does NOT work: mktemp_tracked runs inside command substitutions, so array mutations happen
# in a subshell and never reach the parent — the .p8 would leak.)
TMP_DIR=""
cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    return 0   # never let the trap's last short-circuit leak into the script's exit code
}
trap cleanup EXIT

# ---- logging (never prints secrets) ------------------------------------------------------------
info()  { printf '\n▸ %s\n' "$*"; }
log()   { printf '  %s\n' "$*"; }
warn()  { printf '⚠️  %s\n' "$*" >&2; }
die()   { printf '❌ %s\n' "$*" >&2; exit "${2:-1}"; }

mktemp_tracked() {
    # TMP_DIR is created once in the parent (main) before any subcommand runs, so files land under
    # it no matter which subshell calls this. Cleanup removes the whole dir on exit.
    mktemp "${TMP_DIR}/deliver.XXXXXX"
}

show_help() {
    # Print the leading comment header (from line 2 until the first non-comment line), stripping "# ".
    awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# ================================================================================================
# Toolchain
# ================================================================================================
discover_developer_dir() {
    if [[ -n "${DEVELOPER_DIR:-}" && -d "${DEVELOPER_DIR}/usr/bin" ]]; then return; fi
    local sel
    sel="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$sel" && "$sel" == */Contents/Developer && -d "$sel" ]]; then
        export DEVELOPER_DIR="$sel"; return
    fi
    local cand
    for cand in /Applications/Xcode-26*.app /Applications/Xcode.app /Applications/Xcode*.app; do
        if [[ -d "$cand/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$cand/Contents/Developer"; return
        fi
    done
    die "No full Xcode toolchain found (checked DEVELOPER_DIR, xcode-select -p, /Applications/Xcode*.app)."
}

# ================================================================================================
# App Store Connect: JWT (ES256), self-test, and REST helpers
# ================================================================================================
# The Ruby helper owns the crypto so the DER<->JOSE conversion lives in exactly one place.
#   _ruby_jwt sign <key_path> <kid> <issuer> <ttl>   -> prints a signed JWT for the current instant
#   _ruby_jwt selftest                               -> prints JWT-SELFTEST-OK, exits non-zero on failure
_ruby_jwt() {
    ruby - "$@" <<'RUBY'
require 'openssl'
require 'json'
require 'base64'

def b64url(bin)
  Base64.urlsafe_encode64(bin).delete('=')
end

# ECDSA/DER (SEQUENCE{ INTEGER r, INTEGER s }) -> JOSE (r||s, each 32 bytes big-endian).
def der_to_jose(der)
  seq = OpenSSL::ASN1.decode(der)
  r = seq.value[0].value.to_s(2)
  s = seq.value[1].value.to_s(2)
  raise "r/s too large" if r.bytesize > 32 || s.bytesize > 32
  r.rjust(32, "\x00") + s.rjust(32, "\x00")
end

def jose_to_der(jose)
  raise "jose must be 64 bytes" unless jose.bytesize == 64
  r = OpenSSL::BN.new(jose[0, 32], 2)
  s = OpenSSL::BN.new(jose[32, 32], 2)
  OpenSSL::ASN1::Sequence.new(
    [OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]
  ).to_der
end

def sign_es256(key, header, claims)
  input = b64url(JSON.generate(header)) + '.' + b64url(JSON.generate(claims))
  der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(input))
  input + '.' + b64url(der_to_jose(der))
end

case ARGV[0]
when 'sign'
  key_path, kid, issuer, ttl = ARGV[1], ARGV[2], ARGV[3], Integer(ARGV[4])
  key = OpenSSL::PKey.read(File.read(key_path))
  raise "not an EC key" unless key.is_a?(OpenSSL::PKey::EC)
  now = Time.now.to_i
  header = { alg: 'ES256', kid: kid, typ: 'JWT' }
  claims = { iss: issuer, iat: now, exp: now + ttl, aud: 'appstoreconnect-v1' }
  print sign_es256(key, header, claims)
when 'selftest'
  key = OpenSSL::PKey::EC.generate('prime256v1')
  now = 1_700_000_000
  header = { alg: 'ES256', kid: 'SELFTEST', typ: 'JWT' }
  claims = { iss: 'selftest-issuer', iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }
  token = sign_es256(key, header, claims)
  parts = token.split('.')
  raise "expected 3 JWT segments, got #{parts.length}" unless parts.length == 3
  sig_b64 = parts[2] + '=' * ((4 - parts[2].length % 4) % 4)
  jose = Base64.urlsafe_decode64(sig_b64)
  raise "signature is #{jose.bytesize} bytes, expected 64" unless jose.bytesize == 64
  digest = OpenSSL::Digest::SHA256.digest(parts[0] + '.' + parts[1])
  # Positive: JOSE -> DER round-trip must still verify (proves the conversion is lossless & correct).
  raise "round-trip signature failed to verify" unless key.dsa_verify_asn1(digest, jose_to_der(jose))
  # Negative control: a tampered digest must be rejected. LibreSSL raises on an invalid signature
  # where OpenSSL returns false — treat either as correct rejection.
  bad = digest.dup
  bad.setbyte(0, bad.getbyte(0) ^ 0xFF)
  rejected = begin
    !key.dsa_verify_asn1(bad, jose_to_der(jose))
  rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::ECError
    true
  end
  raise "tampered signature was accepted" unless rejected
  puts 'JWT-SELFTEST-OK'
else
  warn "unknown _ruby_jwt mode: #{ARGV[0]}"
  exit 2
end
RUBY
}

jwt_selftest() {
    local out
    out="$(_ruby_jwt selftest 2>&1)" || die "JWT self-test failed: ${out}"
    [[ "$out" == *"JWT-SELFTEST-OK"* ]] || die "JWT self-test did not confirm success: ${out}"
}

resolve_asc_credentials() {
    # Resolves ASC_KEY_ID / ASC_ISSUER_ID / RESOLVED_KEY_PATH. Never echoes key material.
    [[ "$ASC_KEY_ID" == op://* ]]    && ASC_KEY_ID="$(op read "$ASC_KEY_ID")"
    [[ "$ASC_ISSUER_ID" == op://* ]] && ASC_ISSUER_ID="$(op read "$ASC_ISSUER_ID")"
    [[ -n "$ASC_KEY_ID" ]]    || die "ASC_KEY_ID is required (env or op:// reference)."
    [[ -n "$ASC_ISSUER_ID" ]] || die "ASC_ISSUER_ID is required (env or op:// reference)."
    if [[ -n "$ASC_KEY_PATH" ]]; then
        [[ -f "$ASC_KEY_PATH" && -r "$ASC_KEY_PATH" ]] || die "ASC_KEY_PATH is not a readable file: ${ASC_KEY_PATH}"
        RESOLVED_KEY_PATH="$ASC_KEY_PATH"
    elif [[ -n "$ASC_KEY_OP_REF" ]]; then
        local prev; prev="$(umask)"; umask 077
        RESOLVED_KEY_PATH="$(mktemp_tracked)"       # mktemp already creates 0600; umask is belt-and-suspenders
        umask "$prev"
        op read "$ASC_KEY_OP_REF" > "$RESOLVED_KEY_PATH" || die "op read failed for ASC_KEY_OP_REF"
    else
        die "No ASC key: set ASC_KEY_PATH (a .p8 file) or ASC_KEY_OP_REF (a 1Password secret reference)."
    fi
}

# Writes a curl config file (0600, under TMP_DIR) carrying a freshly-minted bearer token, and prints
# its path. Keeps the token out of curl's argv — argv is visible to same-user `ps`. Per-request
# token: a single JWT can expire mid-pagination or during the notes poll.
_asc_auth_config() {
    local token cfg
    token="$(mint_jwt)"
    cfg="$(mktemp_tracked)"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$cfg"
    printf '%s' "$cfg"
}

# GET a full ASC URL; prints body, dies on non-2xx. No `-f`: curl exits 0 for any completed HTTP
# response so the real status code AND the JSON error body survive (needed to tell a 403 wrong-role
# key from a 429 rate-limit from a still-processing build). curl fails only on a transport error.
asc_get() {
    local url="$1" cfg http body tmp
    cfg="$(_asc_auth_config)"
    tmp="$(mktemp_tracked)"
    if ! http="$(curl -sS -K "$cfg" -o "$tmp" -w '%{http_code}' -H 'Accept: application/json' "$url" 2>/dev/null)"; then
        die "App Store Connect GET transport error (network/DNS/TLS): ${url}"
    fi
    body="$(cat "$tmp")"
    if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
        die "App Store Connect GET failed (HTTP ${http}): ${url}
${body}"
    fi
    printf '%s' "$body"
}

# METHOD PATH JSON-body ; prints body, dies on non-2xx.
asc_send() {
    local method="$1" path="$2" data="$3" cfg http body tmp
    cfg="$(_asc_auth_config)"
    tmp="$(mktemp_tracked)"
    if ! http="$(curl -sS -K "$cfg" -o "$tmp" -w '%{http_code}' -X "$method" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        --data "$data" "${ASC_HOST}${path}" 2>/dev/null)"; then
        die "App Store Connect ${method} ${path} transport error (network/DNS/TLS)."
    fi
    body="$(cat "$tmp")"
    if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
        die "App Store Connect ${method} ${path} failed (HTTP ${http}):
${body}"
    fi
    printf '%s' "$body"
}

mint_jwt() {
    _ruby_jwt sign "$RESOLVED_KEY_PATH" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$JWT_TTL"
}

# ================================================================================================
# App id + build-number resolution
# ================================================================================================
resolve_app_id() {
    local resp id
    resp="$(asc_get "${ASC_HOST}/v1/apps?filter%5BbundleId%5D=${BUNDLE_ID}&fields%5Bapps%5D=bundleId&limit=200")"
    id="$(printf '%s' "$resp" | jq -r --arg b "$BUNDLE_ID" '[.data[] | select(.attributes.bundleId==$b) | .id][0] // empty')"
    [[ -n "$id" ]] || die "No App Store Connect app found for bundleId ${BUNDLE_ID}."
    printf '%s' "$id"
}

# Numeric max CFBundleVersion across ALL of the app's builds (0 if none). Monotonic global build
# numbers are always valid (a build number need only exceed the prior build in its own train), so
# max+1 is collision-free without needing to know the marketing-version train. Paginates.
fetch_max_build_number() {
    local app_id="$1" url resp versions max
    url="${ASC_HOST}/v1/builds?filter%5Bapp%5D=${app_id}&fields%5Bbuilds%5D=version&limit=200"
    versions=""
    while [[ -n "$url" ]]; do
        resp="$(asc_get "$url")"
        versions+="$(printf '%s' "$resp" | jq -r '.data[].attributes.version // empty')"$'\n'
        url="$(printf '%s' "$resp" | jq -r '.links.next // empty')"
    done
    max="$(printf '%s' "$versions" | ruby -e 'v=STDIN.read.split.map { |x| Integer(x) rescue nil }.compact; puts(v.empty? ? 0 : v.max)')"
    printf '%s' "$max"
}

# Resolve the build resource id for a given CFBundleVersion. Exit 75 (EX_TEMPFAIL) if not found yet
# (still processing); die on ambiguity.
resolve_build_id() {
    local app_id="$1" num="$2" resp count
    resp="$(asc_get "${ASC_HOST}/v1/builds?filter%5Bapp%5D=${app_id}&filter%5Bversion%5D=${num}&fields%5Bbuilds%5D=version&limit=10")"
    count="$(printf '%s' "$resp" | jq -r '.data | length')"
    if [[ "$count" == "0" ]]; then
        die "Build ${num} is not on App Store Connect yet (still processing). Re-run 'notes' shortly." 75
    fi
    if [[ "$count" != "1" ]]; then
        die "Ambiguous: ${count} builds match version ${num}. Pass --build-number for a specific build."
    fi
    printf '%s' "$resp" | jq -r '.data[0].id'
}

# ================================================================================================
# Preflight
# ================================================================================================
preflight_fail() {
    if [[ "$DRY_RUN" == 1 ]]; then
        warn "WOULD FAIL LIVE: $*"
        PREFLIGHT_WOULD_FAIL=1
    else
        die "Preflight failed: $*"
    fi
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool not found on PATH: $1"
}

preflight() {
    local subcommand="$1" dr=""
    [[ "$DRY_RUN" == 1 ]] && dr=", dry-run"
    info "Preflight (${subcommand}${dr})…"

    # Always-required local tools (used by both dry-run and live paths).
    require_tool ruby
    require_tool git

    # Clean worktree.
    if [[ "$ALLOW_DIRTY" == 1 ]]; then
        warn "--allow-dirty: NOT a full release preflight (delivering an uncommitted tree)."
    elif [[ -n "$(cd "$REPO_ROOT" && git status --porcelain)" ]]; then
        preflight_fail "working tree is dirty (commit/stash, or pass --allow-dirty)."
    fi

    # Branch / ref invariant. We always archive the CURRENT working tree, so --ref is an assertion
    # that HEAD already points at that tag/sha (not a checkout directive) — verify and refuse a
    # mismatch, otherwise `--ref v1` from a feature branch would silently ship the feature branch.
    local current head_sha ref_sha
    current="$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD)"
    if [[ -n "$REF" ]]; then
        head_sha="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
        if ! ref_sha="$(cd "$REPO_ROOT" && git rev-parse --verify --quiet "${REF}^{commit}")"; then
            preflight_fail "--ref '${REF}' is not a valid commit/tag."
        elif [[ "$ref_sha" != "$head_sha" ]]; then
            preflight_fail "--ref '${REF}' (${ref_sha:0:9}) is not checked out (HEAD is ${head_sha:0:9}). Check it out first."
        else
            log "Delivering ref ${REF} (${ref_sha:0:9}) — matches HEAD."
        fi
    elif [[ "$current" == release/* ]]; then
        log "Delivering from release branch '${current}'."
    else
        preflight_fail "not on a 'release/*' branch (on '${current}'). Create one from develop — e.g. 'git checkout -b release/<desc> develop' — or pass --ref <tag|sha>. (Xcode Cloud's Release workflow archives release/* branches only; this lane mirrors it.)"
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
        # Dry-run is strictly local & read-only: NO crypto, NO swift/xcode, NO 1Password, NO network.
        log "dry-run: skipping (WOULD RUN live) — JWT self-test, ProjectTool secrets validate,"
        log "         swiftlint + harmonize + unittest, credential resolution, and all network."
        log "         Use 'selftest' for the crypto/redaction checks; a live run performs the sweep."
        [[ "$SKIP_TESTS" == 1 ]] && warn "--skip-tests noted (a live run would skip the sweep)."
        if [[ "$PREFLIGHT_WOULD_FAIL" == 1 ]]; then
            warn "Dry-run completed but checks above marked WOULD FAIL LIVE — a live run would stop."
        fi
        return 0
    fi

    # ---- live only: network tools, crypto, sweep, credentials ----
    local t
    for t in jq curl xcodebuild plutil; do require_tool "$t"; done

    jwt_selftest
    log "JWT ES256 self-test OK."

    if [[ "$SKIP_TESTS" == 1 ]]; then
        warn "--skip-tests: skipping ProjectTool secrets validation + the full sweep. NOT a full release preflight."
    else
        log "Validating build secrets (ProjectTool)…"
        (cd "$REPO_ROOT" && swift run --package-path Tools ProjectTool secrets validate) \
            || die "Preflight failed: ProjectTool secrets validate (run: swift run --package-path Tools ProjectTool secrets generate)."
        log "Running the pre-push sweep (lint + harmonize + unit tests)…"
        (cd "$REPO_ROOT" && ./scripts/swiftlint.sh && ./scripts/harmonize.sh && ./scripts/unittest.sh) \
            || die "Preflight failed: pre-push sweep (swiftlint / harmonize / unittest)."
    fi

    resolve_asc_credentials
    log "App Store Connect credentials resolved (key id + issuer + .p8)."

    if [[ "$ONLINE_PREFLIGHT" == 1 ]]; then
        local app_id
        app_id="$(resolve_app_id)"
        log "Online preflight OK: authenticated; app id ${app_id} resolved for ${BUNDLE_ID}."
    fi
}

# ================================================================================================
# deliver
# ================================================================================================
run_step() {
    # In dry-run, print the command (already auth-redacted by the caller) instead of running it.
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '  [dry-run] '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

make_export_plist() {
    # Export-to-disk options (destination=export) for the validation / --export-only IPA.
    local out; out="$(mktemp_tracked)"
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key><string>export</string>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
    printf '%s' "$out"
}

find_exported_ipa() {
    local ipa
    ipa="$(find "$EXPORT_PATH" -maxdepth 2 -name '*.ipa' 2>/dev/null | head -1)"
    [[ -n "$ipa" ]] || die "No .ipa found under ${EXPORT_PATH} after export."
    printf '%s' "$ipa"
}

# Server-side App Store validation of the exported IPA WITHOUT uploading — mirrors Xcode Organizer's
# "Validate App" (icons, entitlements, Info.plist keys, provisioning, unsupported architectures).
# altool is the ONLY CLI that does this (deprecated but functional on Xcode 26.6). It is deliberately
# isolated to this optional, --skip-validate-able gate so the recommended xcodebuild upload path never
# depends on it.
validate_ipa() {
    local ipa="$1"
    command -v xcrun >/dev/null 2>&1 || die "xcrun not found (Xcode toolchain missing)."
    # altool locates the key by NAME in API_PRIVATE_KEYS_DIR: AuthKey_<KEYID>.p8.
    local kdir="${TMP_DIR}/private_keys"
    mkdir -p "$kdir"; chmod 700 "$kdir"
    local keyfile="${kdir}/AuthKey_${ASC_KEY_ID}.p8"
    cp "$RESOLVED_KEY_PATH" "$keyfile"; chmod 600 "$keyfile"
    info "Validating the archive against App Store Connect (altool --validate-app)…"
    local out rc=0
    out="$(API_PRIVATE_KEYS_DIR="$kdir" xcrun altool --validate-app -f "$ipa" -t ios \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        local errs
        errs="$(printf '%s' "$out" | jq -r '.["product-errors"][]?.message // empty' 2>/dev/null)"
        die "App Store validation FAILED:
${errs:-$out}"
    fi
    log "Validation passed — the archive is acceptable to App Store Connect."
}

# Handles `deliver`, `validate` (VALIDATE_ONLY), and `deliver --export-only`.
cmd_deliver() {
    preflight "$SUBCOMMAND"

    # Resolve the build number to archive.
    local num
    if [[ -n "$BUILD_NUMBER" ]]; then
        num="$BUILD_NUMBER"
        info "Using build number ${num} (explicit --build-number)."
    elif [[ "$DRY_RUN" == 1 ]]; then
        die "--dry-run requires --build-number (App Store Connect is not queried offline)."
    else
        local app_id maxb
        app_id="$(resolve_app_id)"
        maxb="$(fetch_max_build_number "$app_id")"
        num=$((maxb + 1))
        info "Resolved build number ${num} (App Store Connect max ${maxb} + 1)."
        warn "Build-number selection is not atomic: if another operator uploads concurrently, pass --build-number."
    fi

    # Auth values for the upload step. Under dry-run these stay placeholders so the printed command
    # (and the validation command) never contain real credentials.
    local kid iss keyp
    if [[ "$DRY_RUN" == 1 ]]; then
        kid="<ASC_KEY_ID>"; iss="<ASC_ISSUER_ID>"; keyp="<ASC_KEY_PATH>"
    else
        kid="$ASC_KEY_ID"; iss="$ASC_ISSUER_ID"; keyp="$RESOLVED_KEY_PATH"
    fi

    # xcodebuild/xcrun only run on the live path; a dry-run rehearsal must not require an Xcode install.
    [[ "$DRY_RUN" == 1 ]] || { discover_developer_dir; rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$UPLOAD_PATH"; mkdir -p "$BUILD_DIR"; }

    info "Archiving (${CONFIGURATION}, CURRENT_PROJECT_VERSION=${num})…"
    run_step xcodebuild archive \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        CURRENT_PROJECT_VERSION="$num"

    # Validate before uploading (default), like Xcode Organizer's Validate → Distribute. Needs a disk
    # IPA; --export-only / `validate` also need it. The upload path re-exports from the archive
    # internally, and App Store validation checks archive content (identical across the two exports).
    local do_validate=1
    [[ "$SKIP_VALIDATE" == 1 ]] && do_validate=0
    [[ "$VALIDATE_ONLY" == 1 ]] && do_validate=1     # `validate` always validates
    if [[ "$do_validate" == 1 || "$EXPORT_ONLY" == 1 || "$VALIDATE_ONLY" == 1 ]]; then
        local eo; eo="$(make_export_plist)"
        info "Exporting IPA to ${EXPORT_PATH}…"
        run_step xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportOptionsPlist "$eo" \
            -exportPath "$EXPORT_PATH" \
            -allowProvisioningUpdates
    fi

    if [[ "$do_validate" == 1 ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            log "[dry-run] would validate: xcrun altool --validate-app -f ${EXPORT_PATH}/<app>.ipa -t ios --apiKey ${kid} --apiIssuer ${iss} --output-format json"
        else
            validate_ipa "$(find_exported_ipa)"
        fi
    else
        warn "--skip-validate: skipping App Store pre-upload validation."
    fi

    if [[ "$VALIDATE_ONLY" == 1 ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            info "Dry-run complete (validate). No archive, export, validation, or credential access occurred."
        else
            info "Validate-only: build ${num} archived and validated; no upload performed."
        fi
        return 0
    fi

    if [[ "$EXPORT_ONLY" == 1 ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            info "Dry-run complete (export-only). No archive, export, or upload occurred."
        else
            info "Export-only: IPA written under ${EXPORT_PATH}; upload manually with altool (see README)."
        fi
        return 0
    fi

    # Re-check the number against ASC right before upload to shrink the selection→upload TOCTOU window.
    # NOT a distributed lock — true concurrent-operator safety needs a shared reservation (README
    # residual-risk note); this cheaply catches the common case and fails before a bad upload.
    if [[ "$DRY_RUN" != 1 ]]; then
        local app_id_recheck max_now
        app_id_recheck="$(resolve_app_id)"
        max_now="$(fetch_max_build_number "$app_id_recheck")"
        if [[ "$num" -le "$max_now" ]]; then
            die "Build ${num} is no longer free (App Store Connect max is now ${max_now}). Re-run to pick $((max_now + 1)), or pass an explicit --build-number."
        fi
        log "Re-checked: build ${num} is still free (current App Store Connect max ${max_now})."
    fi

    info "Exporting + uploading to App Store Connect…"
    run_step xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$UPLOAD_PATH" \
        -authenticationKeyID "$kid" \
        -authenticationKeyIssuerID "$iss" \
        -authenticationKeyPath "$keyp" \
        -allowProvisioningUpdates

    if [[ "$DRY_RUN" == 1 ]]; then
        info "Dry-run complete. No archive, export, validation, upload, or credential access occurred."
    else
        info "Upload submitted for build ${num}. After App Store Connect finishes processing, attach notes:"
        log "    ./scripts/deliver.sh notes --build-number ${num}"
    fi
}

# ================================================================================================
# notes
# ================================================================================================
build_whatsnew_json() {
    # Substitutes the resolved build number into the WhatToTest 'Build:' line and emits a
    # betaBuildLocalizations JSON payload (PATCH form if $2 given, else POST form with $3 = build id).
    local num="$1" loc_id="${2:-}" build_id="${3:-}"
    [[ -f "$WHATSNEW_FILE" ]] || die "Missing ${WHATSNEW_FILE}."
    ruby -e '
      num, path, loc_id, build_id, maxlen = ARGV
      text = File.read(path)
      raise "WhatToTest is empty" if text.strip.empty?
      text = text.sub(/^Build:.*\R?/, "Build: #{num}\n")
      raise "whatsNew exceeds #{maxlen} chars (#{text.length})" if text.length > maxlen.to_i
      require "json"
      attrs = { "whatsNew" => text }
      if loc_id.empty?
        payload = { "data" => { "type" => "betaBuildLocalizations", "attributes" => attrs.merge("locale" => "en-US"),
                                "relationships" => { "build" => { "data" => { "type" => "builds", "id" => build_id } } } } }
      else
        payload = { "data" => { "type" => "betaBuildLocalizations", "id" => loc_id, "attributes" => attrs } }
      end
      print JSON.generate(payload)
    ' "$num" "$WHATSNEW_FILE" "$loc_id" "$build_id" "$WHATSNEW_MAX"
}

cmd_notes() {
    # Always require an explicit build number. Guessing "the latest build on App Store Connect" could
    # attach these tester notes to a build another operator uploaded in between; `deliver` prints the
    # exact `notes --build-number <n>` line to copy after an upload.
    [[ -n "$BUILD_NUMBER" ]] || die "notes requires --build-number <n> (deliver echoes the exact command after upload)."
    preflight notes
    local num="$BUILD_NUMBER"

    if [[ "$DRY_RUN" == 1 ]]; then
        info "Dry-run: would push What to Test for build ${num}."
        log "Source: ${WHATSNEW_FILE} (Build: line rewritten to ${num})."
        log "Flow: GET betaBuildLocalizations for the build → PATCH existing en-US, else POST a new one."
        log "Request auth header would be: Authorization: Bearer <redacted>"
        # Prove the payload builds and stays within limits, offline.
        build_whatsnew_json "$num" "SAMPLE_LOC_ID" >/dev/null && log "Payload builds within the ${WHATSNEW_MAX}-char limit."
        info "Dry-run complete. No network call, no credential access."
        return 0
    fi

    resolve_asc_credentials
    local app_id
    app_id="$(resolve_app_id)"

    local build_id
    build_id="$(resolve_build_id "$app_id" "$num")"      # may exit 75 if still processing
    log "Build ${num} → resource id ${build_id}."

    # Get-or-create the en-US localization.
    local locs loc_id
    locs="$(asc_get "${ASC_HOST}/v1/builds/${build_id}/betaBuildLocalizations?fields%5BbetaBuildLocalizations%5D=locale&limit=200")"
    loc_id="$(printf '%s' "$locs" | jq -r '[.data[] | select(.attributes.locale=="en-US") | .id][0] // empty')"

    local payload
    if [[ -n "$loc_id" ]]; then
        payload="$(build_whatsnew_json "$num" "$loc_id")"
        asc_send PATCH "/v1/betaBuildLocalizations/${loc_id}" "$payload" >/dev/null
        info "Updated existing en-US What to Test for build ${num}."
    else
        payload="$(build_whatsnew_json "$num" "" "$build_id")"
        asc_send POST "/v1/betaBuildLocalizations" "$payload" >/dev/null
        info "Created en-US What to Test for build ${num}."
    fi
}

# ================================================================================================
# selftest (offline, repeatable — safe to run in CI)
# ================================================================================================
cmd_selftest() {
    # Offline only: no Xcode, no credentials, no network.
    info "ES256 JWT sign/verify self-test (ephemeral key)…"
    jwt_selftest
    log "OK."

    info "Dry-run redaction self-test…"
    # Run the child dry-run with SENTINEL credentials in the environment and assert none of them (nor
    # any token/private-key pattern) appear in the trace. Preserve the child's exit status — a crashed
    # child must fail the test, not pass it via a swallowed error.
    local trace rc=0
    trace="$(ASC_KEY_ID=SENTINEL_KEYID_9Z ASC_ISSUER_ID=SENTINEL_ISSUER_9Z ASC_KEY_OP_REF='op://SENTINEL/9Z/p8' \
        bash "${BASH_SOURCE[0]}" deliver --dry-run --build-number 999999 --skip-tests --allow-dirty 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        die "Redaction self-test: child dry-run exited ${rc} (expected 0). Trace:
${trace}"
    fi
    if printf '%s' "$trace" | grep -Eq 'Bearer [A-Za-z0-9._-]{20,}|-----BEGIN|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]+'; then
        die "Dry-run trace leaked a token or private key."
    fi
    if printf '%s' "$trace" | grep -Eq 'SENTINEL_KEYID_9Z|SENTINEL_ISSUER_9Z|op://SENTINEL'; then
        die "Dry-run trace leaked a credential value (key id / issuer / key reference)."
    fi
    log "OK — no token, key, id, issuer, or key-reference in the dry-run trace."
    info "All self-tests passed."
}

# ================================================================================================
# Arg parsing + dispatch
# ================================================================================================
main() {
    if [[ $# -eq 0 ]]; then show_help; exit 1; fi
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        deliver|notes|selftest) SUBCOMMAND="$1"; shift ;;
        validate) SUBCOMMAND="validate"; VALIDATE_ONLY=1; shift ;;
        *) die "Unknown subcommand '$1' (expected: deliver | validate | notes | selftest). Use --help." ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)          DRY_RUN=1; shift ;;
            --build-number)     [[ $# -ge 2 ]] || die "--build-number requires a value."; BUILD_NUMBER="$2"; shift 2 ;;
            --skip-tests)       SKIP_TESTS=1; shift ;;
            --skip-validate)    SKIP_VALIDATE=1; shift ;;
            --allow-dirty)      ALLOW_DIRTY=1; shift ;;
            --online-preflight) ONLINE_PREFLIGHT=1; shift ;;
            --export-only)      EXPORT_ONLY=1; shift ;;
            --ref)              [[ $# -ge 2 ]] || die "--ref requires a value."; REF="$2"; shift 2 ;;
            -h|--help)          show_help; exit 0 ;;
            *) die "Unknown option '$1' for '${SUBCOMMAND}'. Use --help." ;;
        esac
    done

    # Validate arguments immediately (before any crypto/network/build work).
    if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
        die "--build-number must be a positive integer with no leading zero (got '${BUILD_NUMBER}')."
    fi
    # Dry-run cannot query App Store Connect, so the build number must be supplied up front.
    if [[ "$DRY_RUN" == 1 && "$SUBCOMMAND" != "selftest" && -z "$BUILD_NUMBER" ]]; then
        die "--dry-run requires --build-number (App Store Connect is not queried offline)."
    fi

    # Parent-owned temp dir (0700) for the .p8 + cached responses; removed by the EXIT trap.
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deliver.XXXXXX")"

    # discover_developer_dir is deferred into the live paths (cmd_deliver runs it only when not
    # dry-run); selftest, dry-run rehearsals, and notes never invoke xcodebuild/xcrun, so they must
    # not require an Xcode toolchain.
    case "$SUBCOMMAND" in
        selftest)          cmd_selftest ;;
        deliver|validate)  cmd_deliver ;;
        notes)             cmd_notes ;;
    esac
}

main "$@"
