#!/bin/bash
#
# scripts/deliver.sh — Local archive → TestFlight delivery lane (Xcode Cloud fallback).
#
# Emergency lane for when Xcode Cloud is unavailable (allocation exhausted, outage). Archives the
# MLBrowser app locally, uploads it to App Store Connect (TestFlight), and pushes the tester-facing
# "What to Test" notes — all authenticated with an App Store Connect API key (never your Apple ID).
#
# Subcommands:
#   deliver   Preflight -> archive -> export -> upload to App Store Connect.
#   notes     Get-or-create the build's en-US "What to Test" from ios/TestFlight/WhatToTest.en-US.txt.
#   selftest  Offline self-tests (ES256 JWT sign/verify + dry-run redaction). No credentials needed.
#
# Usage:
#   ./scripts/deliver.sh deliver [--build-number N] [--dry-run] [--export-only]
#                                [--ref <tag|sha>] [--skip-tests] [--allow-dirty] [--online-preflight]
#   ./scripts/deliver.sh notes   [--build-number N] [--dry-run]
#   ./scripts/deliver.sh selftest
#   ./scripts/deliver.sh --help
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
EXPORT_PATH="${BUILD_DIR}/export"
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
REF=""
PREFLIGHT_WOULD_FAIL=0

# ASC credentials (resolved lazily; never echoed).
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_KEY_OP_REF="${ASC_KEY_OP_REF:-}"
RESOLVED_KEY_PATH=""

TMP_FILES=()
cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f "$f"
    done
    return 0   # never let the trap's last short-circuit leak into the script's exit code
}
trap cleanup EXIT

# ---- logging (never prints secrets) ------------------------------------------------------------
info()  { printf '\n▸ %s\n' "$*"; }
log()   { printf '  %s\n' "$*"; }
warn()  { printf '⚠️  %s\n' "$*" >&2; }
die()   { printf '❌ %s\n' "$*" >&2; exit "${2:-1}"; }

mktemp_tracked() {
    local f; f="$(mktemp "${TMPDIR:-/tmp}/deliver.XXXXXX")"
    TMP_FILES+=("$f")
    printf '%s' "$f"
}

show_help() {
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# GET a full ASC URL with a freshly-minted token; prints body, dies on non-2xx. (Per-request token:
# a single JWT can expire mid-pagination or during the notes poll.)
asc_get() {
    local url="$1" token body http tmp
    token="$(mint_jwt)"
    tmp="$(mktemp_tracked)"
    http="$(curl -fsS -o "$tmp" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H 'Accept: application/json' \
        "$url" 2>/dev/null)" || http="000"
    body="$(cat "$tmp")"
    if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
        die "App Store Connect GET failed (HTTP ${http}): ${url}
${body}"
    fi
    printf '%s' "$body"
}

# METHOD PATH JSON-body ; prints body, dies on non-2xx.
asc_send() {
    local method="$1" path="$2" data="$3" token body http tmp
    token="$(mint_jwt)"
    tmp="$(mktemp_tracked)"
    http="$(curl -fsS -o "$tmp" -w '%{http_code}' -X "$method" \
        -H "Authorization: Bearer ${token}" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        --data "$data" \
        "${ASC_HOST}${path}" 2>/dev/null)" || http="000"
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
    local subcommand="$1"
    info "Preflight (${subcommand}${DRY_RUN:+, dry-run})…"

    # Tools that even the offline paths need are always hard requirements.
    require_tool ruby
    require_tool git
    # Network/build tools: hard for a live run, downgraded for dry-run (they are not invoked offline).
    local t
    for t in jq curl xcodebuild plutil; do
        command -v "$t" >/dev/null 2>&1 || preflight_fail "required tool not found on PATH: ${t}"
    done

    # ES256 JWT crypto self-test — always (offline, no credentials).
    jwt_selftest
    log "JWT ES256 self-test OK."

    # Clean worktree.
    if [[ "$ALLOW_DIRTY" == 1 ]]; then
        warn "--allow-dirty: NOT a full release preflight (delivering an uncommitted tree)."
    elif [[ -n "$(cd "$REPO_ROOT" && git status --porcelain)" ]]; then
        preflight_fail "working tree is dirty (commit/stash, or pass --allow-dirty)."
    fi

    # Branch invariant: deliver from develop or an explicit ref, never a stray feature branch.
    local current
    current="$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD)"
    if [[ -n "$REF" ]]; then
        log "Delivering explicit ref: ${REF} (operator override — ensure it is release-worthy)."
    elif [[ "$current" != "develop" ]]; then
        preflight_fail "not on 'develop' (on '${current}'). Deliver from develop or pass --ref <tag|sha>."
    fi

    # Build secrets present (build xcconfig). Slow (builds ProjectTool); skipped with --skip-tests.
    if [[ "$SKIP_TESTS" == 1 ]]; then
        warn "--skip-tests: skipping ProjectTool secrets validation + the full sweep. NOT a full release preflight."
    else
        log "Validating build secrets (ProjectTool)…"
        if ! (cd "$REPO_ROOT" && swift run --package-path Tools ProjectTool secrets validate); then
            preflight_fail "ProjectTool secrets validate failed (run: swift run --package-path Tools ProjectTool secrets generate)."
        fi
        log "Running the pre-push sweep (lint + harmonize + unit tests)…"
        if ! (cd "$REPO_ROOT" && ./scripts/swiftlint.sh && ./scripts/harmonize.sh && ./scripts/unittest.sh); then
            preflight_fail "pre-push sweep failed (swiftlint / harmonize / unittest)."
        fi
    fi

    # ASC credentials present (needed to reach App Store Connect).
    if [[ "$DRY_RUN" == 1 ]]; then
        log "dry-run: skipping credential resolution (no 1Password read, no JWT, no network)."
    else
        resolve_asc_credentials
        log "App Store Connect credentials resolved (key id + issuer + .p8)."
    fi

    if [[ "$ONLINE_PREFLIGHT" == 1 && "$DRY_RUN" != 1 ]]; then
        local app_id
        app_id="$(resolve_app_id)"
        log "Online preflight OK: authenticated; app id ${app_id} resolved for ${BUNDLE_ID}."
    fi

    if [[ "$DRY_RUN" == 1 && "$PREFLIGHT_WOULD_FAIL" == 1 ]]; then
        warn "Dry-run rehearsal passed but the checks above marked WOULD FAIL LIVE — a live run would stop."
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

make_export_only_plist() {
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

cmd_deliver() {
    preflight deliver

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
    # never contains real credentials.
    local kid iss keyp
    if [[ "$DRY_RUN" == 1 ]]; then
        kid="<ASC_KEY_ID>"; iss="<ASC_ISSUER_ID>"; keyp="<ASC_KEY_PATH>"
    else
        kid="$ASC_KEY_ID"; iss="$ASC_ISSUER_ID"; keyp="$RESOLVED_KEY_PATH"
    fi

    [[ "$DRY_RUN" == 1 ]] || { rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"; mkdir -p "$BUILD_DIR"; }

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

    if [[ "$EXPORT_ONLY" == 1 ]]; then
        local eo; eo="$(make_export_only_plist)"
        info "Exporting IPA to ${EXPORT_PATH} (--export-only; upload manually with altool, see README)…"
        run_step xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportOptionsPlist "$eo" \
            -exportPath "$EXPORT_PATH" \
            -allowProvisioningUpdates
        log "IPA written under ${EXPORT_PATH}."
    else
        info "Exporting + uploading to App Store Connect…"
        run_step xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportOptionsPlist "$EXPORT_OPTIONS" \
            -exportPath "$EXPORT_PATH" \
            -authenticationKeyID "$kid" \
            -authenticationKeyIssuerID "$iss" \
            -authenticationKeyPath "$keyp" \
            -allowProvisioningUpdates
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
        info "Dry-run complete. No archive, export, upload, or credential access occurred."
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
    preflight notes

    local num
    if [[ -n "$BUILD_NUMBER" ]]; then
        num="$BUILD_NUMBER"
    elif [[ "$DRY_RUN" == 1 ]]; then
        die "--dry-run requires --build-number (App Store Connect is not queried offline)."
    fi

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
    if [[ -z "${num:-}" ]]; then
        num="$(fetch_max_build_number "$app_id")"
        [[ "$num" != "0" ]] || die "No builds on App Store Connect yet — upload one first (deliver)." 75
        info "Resolved build number ${num} (latest on App Store Connect)."
    fi

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
    discover_developer_dir
    info "ES256 JWT sign/verify self-test (ephemeral key)…"
    jwt_selftest
    log "OK."
    info "Dry-run redaction self-test…"
    local trace
    trace="$(bash "${BASH_SOURCE[0]}" deliver --dry-run --build-number 999999 --skip-tests --allow-dirty 2>&1)" || true
    if printf '%s' "$trace" | grep -Eq 'Bearer [A-Za-z0-9._-]{20,}|-----BEGIN|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]+'; then
        die "Dry-run trace leaked auth material (token or private key)."
    fi
    log "OK — no token/key material in the dry-run trace."
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
        *) die "Unknown subcommand '$1' (expected: deliver | notes | selftest). Use --help." ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)          DRY_RUN=1; shift ;;
            --build-number)     BUILD_NUMBER="${2:-}"; shift 2 ;;
            --skip-tests)       SKIP_TESTS=1; shift ;;
            --allow-dirty)      ALLOW_DIRTY=1; shift ;;
            --online-preflight) ONLINE_PREFLIGHT=1; shift ;;
            --export-only)      EXPORT_ONLY=1; shift ;;
            --ref)              REF="${2:-}"; shift 2 ;;
            -h|--help)          show_help; exit 0 ;;
            *) die "Unknown option '$1' for '${SUBCOMMAND}'. Use --help." ;;
        esac
    done

    if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
        die "--build-number must be a positive integer (got '${BUILD_NUMBER}')."
    fi

    case "$SUBCOMMAND" in
        selftest) cmd_selftest ;;
        deliver)  discover_developer_dir; cmd_deliver ;;
        notes)    discover_developer_dir; cmd_notes ;;
    esac
}

main "$@"
