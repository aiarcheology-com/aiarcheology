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

# The manifest path is passed to Python as an argument, never interpolated into its source: a
# checkout path containing a quote would otherwise be a syntax error at best, an injection point
# at worst.

# One tab-separated line per file: model, installPath, url, archiveSha256, archiveMember,
# relative path within the package, expected sha256.
read_manifest() {
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
for model in m['models']:
    for rel, sha in model['files'].items():
        print('\t'.join([model['name'], model['installPath'], model['url'],
                         model['archiveSha256'], model['archiveMember'], rel, sha]))
" "$MANIFEST"
}

# One tab-separated line per file in one model: relative path, expected sha256.
expected_files_for() {
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
for model in m['models']:
    if model['name'] == sys.argv[2]:
        for rel, sha in model['files'].items():
            print('\t'.join([rel, sha]))
" "$MANIFEST" "$1"
}

# The installPath of one model.
install_path_for() {
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
for model in m['models']:
    if model['name'] == sys.argv[2]:
        print(model['installPath'])
" "$MANIFEST" "$1"
}

# Downloads the archive, verifies it whole, verifies every member against the manifest, and only
# then swaps it into place. Nothing touches the destination until all of that has passed, so a
# refused restore leaves the existing copy exactly as it was.
restore_model() {
  local name="$1" install_path="$2" url="$3" archive_sha="$4" member="$5"
  local dest="$REPO_ROOT/$install_path"
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now: the trap must survive the variable going away.
  trap "rm -rf '$tmp'" RETURN

  echo "  ↓ downloading $name"
  # Every step below is status-checked explicitly. This function is called from an `if`, which
  # suspends `set -e` for its whole body, so an unchecked failure would fall through to the next
  # line — which, at the swap, would mean deleting a good copy and installing a broken one while
  # reporting success.
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

  # Staged beside the destination, because the `mv` below is only a rename — and therefore only
  # atomic — within one filesystem. The name is dot-prefixed and gitignored so an interrupted run
  # does not leave visible debris in the working tree. __MACOSX resource forks that Apple's zip
  # carries stay behind in $tmp.
  local staging; staging="$(dirname "$dest")/.$(basename "$dest").incoming"
  if ! mkdir -p "$(dirname "$dest")"; then
    echo "  ✗ $name: could not create the destination directory" >&2
    return 1
  fi
  rm -rf "$staging"
  if ! cp -R "$tmp/unpacked/$member" "$staging"; then
    echo "  ✗ $name: could not stage the restored package" >&2
    rm -rf "$staging"
    return 1
  fi
  if ! rm -rf "$dest"; then
    echo "  ✗ $name: could not remove the old package" >&2
    rm -rf "$staging"
    return 1
  fi
  if ! mv "$staging" "$dest"; then
    echo "  ✗ $name: could not move the restored package into place" >&2
    rm -rf "$staging"
    return 1
  fi
  echo "  ✓ $name restored"
  return 0
}

status=0
# Models a restore has been ATTEMPTED for — not models it succeeded for. Recording only successes
# would re-download the whole archive once per remaining file of a model whose restore failed.
attempted=""

# The manifest is read into a file, not piped straight into the loop. A process substitution
# hides the producer's exit status, so a manifest that failed to parse would feed the loop zero
# rows, skip every check, and still report "all match" — a silent pass, which is the one outcome
# a verification tool must never produce.
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
models=""
while IFS=$'\t' read -r name install_path url archive_sha member rel expected; do
  checked=$((checked + 1))
  case " $models " in *" $name "*) ;; *) models="$models $name" ;; esac
  file="$REPO_ROOT/$install_path/$rel"

  # Restore is attempted at most once per model, and its result is NOT the verdict — the single
  # check below is. So a transient failure on one file that a later successful restore repairs
  # leaves no stale failure behind, and a permanent failure is not retried once per file.
  if [ ! -f "$file" ] || [ "$(sha_of "$file" 2>/dev/null || echo missing)" != "$expected" ]; then
    if [ "$RESTORE" = 1 ]; then
      case " $attempted " in
        *" $name "*) ;;
        *)
          attempted="$attempted $name"
          echo "✗ $name/$rel needs restoring"
          restore_model "$name" "$install_path" "$url" "$archive_sha" "$member" || true
          ;;
      esac
    fi
  fi

  if [ ! -f "$file" ]; then
    echo "✗ $name/$rel missing" >&2
    [ "$RESTORE" = 1 ] || echo "    re-run with --restore" >&2
    status=1
    continue
  fi
  actual="$(sha_of "$file")"
  if [ "$actual" = "$expected" ]; then
    echo "✓ $name/$rel"
  else
    echo "✗ $name/$rel sha256 mismatch: expected $expected, got $actual" >&2
    status=1
  fi
done < "$ROWS"

# The check above is one-directional: it proves every file the manifest lists is correct, but says
# nothing about a file that was ADDED inside the package. NOTICE claims these bytes are identical
# to Apple's published download, so the other direction has to be checked too or that claim is
# broader than the evidence.
for name in $models; do
  pkg="$REPO_ROOT/$(install_path_for "$name")"
  [ -d "$pkg" ] || continue
  listed="$(expected_files_for "$name" | cut -f1 | sort)"
  present="$(cd "$pkg" && find . -type f | sed 's|^\./||' | sort)"
  extra="$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$present") || true)"
  if [ -n "$extra" ]; then
    echo "✗ $name contains files the manifest does not list:" >&2
    printf '    %s\n' $extra >&2
    status=1
  fi
done

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
