#!/usr/bin/env bash
#
# Verifies — and can restore — the demo models this repository did not produce, against the
# published sources recorded in scripts/demo_models.json.
#
# Unlike its siblings (fetch_native_test_models.sh, fetch_adaf_checkpoints.sh) this script does
# NOT fetch by default. The models it covers are committed and are build inputs: the Debug build
# fails with "Build input file cannot be found" if one is missing, so there is no lazy-fetch
# story to tell. What this script adds is provenance you can check rather than trust — proof that
# the committed FastViT bytes are exactly Apple's published bytes — plus a way back if a working
# copy gets damaged.
#
# Usage:
#   scripts/fetch_demo_models.sh              # verify committed copies against recorded SHA-256
#   scripts/fetch_demo_models.sh --restore    # re-download and reinstall anything missing/corrupt
#   scripts/fetch_demo_models.sh --help
#
# Exit status: 0 = every covered model matches; 1 = a mismatch or a missing file remains.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/demo_models.json"
RESTORE=0

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's|^#||; s|^ ||'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --restore) RESTORE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "✗ manifest not found: $MANIFEST" >&2; exit 1; }

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# One tab-separated line per file in one model: relative path within the package, expected sha256.
expected_files_for() {
  python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
for model in m['models']:
    if model['name'] == sys.argv[1]:
        for rel, sha in model['files'].items():
            print('\t'.join([rel, sha]))
" "$1"
}

# One tab-separated line per file: model, installPath, url, archiveSha256, archiveMember,
# relative path within the package, expected sha256.
read_manifest() {
  python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
for model in m['models']:
    for rel, sha in model['files'].items():
        print('\t'.join([model['name'], model['installPath'], model['url'],
                         model['archiveSha256'], model['archiveMember'], rel, sha]))
"
}

# Downloads the archive once per model, verifies it whole, and installs it atomically: the
# package is assembled under a temp dir and only swapped in after every member has been
# checked, so an interrupted run can never leave a half-written .mlpackage where the build
# expects a complete one.
restore_model() {
  local name="$1" install_path="$2" url="$3" archive_sha="$4" member="$5"
  local dest="$REPO_ROOT/$install_path"
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now: the trap must survive the variable going away.
  trap "rm -rf '$tmp'" RETURN

  echo "  ↓ downloading $name"
  # --retry-connrefused covers a refused handshake, which a bare --retry does not treat as
  # retryable; the same reasoning as ToolsConfiguration.swift's tool downloader.
  # The status is checked explicitly: this function is called from an `if`, which suspends
  # `set -e` for its whole body, so a failing command here would otherwise fall through.
  if ! curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 -o "$tmp/archive.zip" "$url"; then
    echo "  ✗ $name download failed" >&2
    return 1
  fi

  local actual; actual="$(sha_of "$tmp/archive.zip")"
  if [ "$actual" != "$archive_sha" ]; then
    echo "  ✗ $name archive sha256 mismatch: expected $archive_sha, got $actual" >&2
    echo "    The upstream asset changed, or the download was tampered with. Not installing." >&2
    return 1
  fi

  if ! unzip -q "$tmp/archive.zip" -d "$tmp/unpacked"; then
    echo "  ✗ $name: archive could not be extracted" >&2
    return 1
  fi
  if [ ! -d "$tmp/unpacked/$member" ]; then
    echo "  ✗ $name: archive does not contain '$member'" >&2
    return 1
  fi

  # Verify every member BEFORE anything touches $dest. Checking only the archive digest would
  # not be enough: it says the download was whole, not that what we are about to install is.
  # Nothing is removed or moved until this passes, so a failure here leaves the existing copy
  # exactly as it was.
  # Materialised rather than piped from a process substitution, whose exit status is not
  # observable: a reader that died would otherwise yield an empty loop and look like success.
  local members="$tmp/members.tsv"
  if ! expected_files_for "$name" > "$members" || [ ! -s "$members" ]; then
    echo "  ✗ $name: could not read the file list from the manifest" >&2
    return 1
  fi

  local rel expected got
  while IFS=$'\t' read -r rel expected; do
    if [ ! -f "$tmp/unpacked/$member/$rel" ]; then
      echo "  ✗ $name: extracted archive is missing $rel" >&2
      return 1
    fi
    got="$(sha_of "$tmp/unpacked/$member/$rel")"
    if [ "$got" != "$expected" ]; then
      echo "  ✗ $name: extracted $rel sha256 mismatch: expected $expected, got $got" >&2
      return 1
    fi
  done < "$members"

  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest.incoming"
  # Copy into place, then swap, so a copy that dies part-way cannot leave a half-written
  # .mlpackage where the build expects a complete one. __MACOSX resource forks that Apple's
  # zip carries are left behind in $tmp.
  if ! cp -R "$tmp/unpacked/$member" "$dest.incoming"; then
    echo "  ✗ $name: could not stage the restored package" >&2
    rm -rf "$dest.incoming"
    return 1
  fi
  rm -rf "$dest"
  mv "$dest.incoming" "$dest"
  echo "  ✓ $name restored"
}

status=0
declare -a restored_models=()

# The manifest is read into a file, not piped straight into the loop. A process substitution
# hides the producer's exit status, so a manifest that failed to parse would feed the loop zero
# rows, skip every check, and still report "all match" -- a silent pass, which is the one
# outcome a verification tool must never produce.
ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT
if ! read_manifest > "$ROWS"; then
  echo "✗ could not read $MANIFEST" >&2
  exit 1
fi
if [ ! -s "$ROWS" ]; then
  echo "✗ $MANIFEST listed no files to verify — refusing to report success" >&2
  exit 1
fi

checked=0
while IFS=$'\t' read -r name install_path url archive_sha member rel expected; do
  checked=$((checked + 1))
  file="$REPO_ROOT/$install_path/$rel"

  if [ ! -f "$file" ]; then
    if [ "$RESTORE" = 1 ] && [[ ! " ${restored_models[*]-} " == *" $name "* ]]; then
      echo "✗ $name/$rel missing"
      if restore_model "$name" "$install_path" "$url" "$archive_sha" "$member"; then
        restored_models+=("$name")
      else
        status=1; continue
      fi
    else
      echo "✗ $name/$rel missing — re-run with --restore" >&2
      status=1; continue
    fi
  fi

  actual="$(sha_of "$file")"
  if [ "$actual" = "$expected" ]; then
    echo "✓ $name/$rel"
    continue
  fi

  if [ "$RESTORE" = 1 ] && [[ ! " ${restored_models[*]-} " == *" $name "* ]]; then
    echo "✗ $name/$rel sha256 mismatch — restoring"
    if restore_model "$name" "$install_path" "$url" "$archive_sha" "$member"; then
      restored_models+=("$name")
      actual="$(sha_of "$file")"
      if [ "$actual" = "$expected" ]; then echo "✓ $name/$rel"; continue; fi
    fi
  fi

  echo "✗ $name/$rel sha256 mismatch: expected $expected, got $actual" >&2
  status=1
done < "$ROWS"

echo ""
if [ "$checked" -eq 0 ]; then
  echo "✗ no files were checked — refusing to report success" >&2
  exit 1
fi
if [ "$status" = 0 ]; then
  echo "All covered demo models match their recorded upstream digests ($checked files)."
else
  echo "Some demo models do not match. See scripts/demo_models.json for the expected digests." >&2
fi
exit "$status"
