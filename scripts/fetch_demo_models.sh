#!/usr/bin/env bash
#
# Verifies — and can restore — the demo models this repository did not produce, against the
# published sources recorded in scripts/demo_models.json.
#
# Unlike its siblings (fetch_native_test_models.sh, fetch_adaf_checkpoints.sh) this script does
# NOT fetch by default. The models it covers are committed and are build inputs: the Debug build
# fails with "Build input file cannot be found" if one is missing, so there is no lazy-fetch
# story to tell. What this script adds is provenance you can check rather than trust, plus a way
# back if a working copy gets damaged.
#
# Be precise about what a default run proves: that the tree matches the digests recorded in
# scripts/demo_models.json. Those digests were taken from Apple's published archive, but this mode
# does not contact Apple — only --restore downloads, and only once a difference has been found.
#
# Usage:
#   scripts/fetch_demo_models.sh              # verify committed copies against recorded SHA-256
#   scripts/fetch_demo_models.sh --restore    # re-download and reinstall anything that differs
#   scripts/fetch_demo_models.sh --help
#
# Exit status: 0 = every covered model matches; 1 = a difference remains, or a check could not
# be completed. It never reports success for a check it did not actually run.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/demo_models.json"
RESTORE=0

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's|^#||; s|^ ||'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --restore) RESTORE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "✗ manifest not found: $MANIFEST" >&2; exit 1; }

WORK="$(mktemp -d)"
RESTORE_TMP=""
trap 'rm -rf "$WORK"; [ -n "$RESTORE_TMP" ] && rm -rf "$RESTORE_TMP"' EXIT

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# The manifest path is passed to Python as an argument, never interpolated into its source: a
# checkout path containing a quote would otherwise be a syntax error at best, an injection point
# at worst.

# Rejects a manifest that would let a model escape verification: a blank or duplicated name, an
# empty file list, or two models writing to the same destination (where restoring the second would
# silently invalidate the first, which is only rechecked before that happens).
validate_manifest() {
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
models = m.get('models')
if not isinstance(models, list) or not models:
    sys.exit('manifest lists no models')
seen_names, seen_paths, problems = set(), {}, []
for i, model in enumerate(models):
    name = model.get('name', '')
    if not isinstance(name, str) or not name.strip():
        problems.append('model %d has a blank name' % i); continue
    if name in seen_names:
        problems.append('duplicate model name: %s' % name)
    seen_names.add(name)
    if not model.get('files'):
        problems.append('%s lists no files' % name)
    path = model.get('installPath', '')
    member = model.get('archiveMember', '')
    # Both values are used to build filesystem paths -- \$REPO_ROOT/\$installPath and
    # \$tmp/unpacked/\$archiveMember -- so an absolute path or a '..' component would let a
    # manifest edit make --restore write outside the checkout, or copy arbitrary local data
    # into the model destination. Contain them here, before anything uses them.
    for label, value in (('installPath', path), ('archiveMember', member)):
        if not value:
            problems.append('%s has no %s' % (name, label)); continue
        if value.startswith('/') or value.startswith('~'):
            problems.append('%s %s must be relative: %s' % (name, label, value))
        if '..' in value.split('/'):
            problems.append('%s %s must not contain \'..\': %s' % (name, label, value))
    if path and path in seen_paths:
        problems.append('%s and %s share installPath %s' % (seen_paths[path], name, path))
    elif path:
        seen_paths[path] = name
if problems:
    sys.exit('; '.join(problems))
" "$MANIFEST"
}

# Model names, one per line.
model_names() {
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
for model in m['models']:
    print(model['name'])
" "$MANIFEST"
}

# One tab-separated line: installPath, url, archiveSha256, archiveMember.
model_meta() {
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
for model in m['models']:
    if model['name'] == sys.argv[2]:
        print('\t'.join([model['installPath'], model['url'],
                         model['archiveSha256'], model['archiveMember']]))
" "$MANIFEST" "$1"
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

# Compares a directory tree against a model's manifest entry. Prints one human-readable
# difference per line; prints nothing when the tree matches exactly.
#
# Deliberately BIDIRECTIONAL. Checking only that every listed file is present and correct would
# say nothing about a file that was ADDED inside the package, and NOTICE claims these bytes are
# identical to Apple's published download — a claim a one-directional check cannot support.
diff_tree_against_manifest() {
  local name="$1" root="$2" listed="$WORK/listed.$$" present="$WORK/present.$$"
  local rel expected got

  # The per-file symlink checks below cannot catch a symlinked ROOT: replacing the package
  # directory with a link to a matching tree elsewhere would otherwise verify clean, and would
  # point --restore at a directory outside the checkout.
  if [ -L "$root" ]; then
    echo "the package directory is a symlink, not a real directory"
    return 0
  fi

  if ! expected_files_for "$name" > "$WORK/exp.$$" || [ ! -s "$WORK/exp.$$" ]; then
    echo "could not read the file list for $name from the manifest"
    return 0
  fi

  while IFS=$'\t' read -r rel expected; do
    if [ -L "$root/$rel" ]; then
      # -f follows symlinks, so without this a symlink pointing at correct bytes would pass.
      echo "$rel is a symlink, not a regular file"
    elif [ ! -f "$root/$rel" ]; then
      echo "$rel is missing"
    else
      got="$(sha_of "$root/$rel")"
      [ "$got" = "$expected" ] || echo "$rel sha256 mismatch: expected $expected, got $got"
    fi
  done < "$WORK/exp.$$"

  # Both inventories are status-checked. Bash 3.2 disables errexit inside command substitutions,
  # so a `find` that died would otherwise leave an empty inventory — which `comm -13` happily
  # reports as "no extra files", turning a broken check into a pass.
  if ! cut -f1 < "$WORK/exp.$$" | LC_ALL=C sort > "$listed"; then
    echo "could not list the expected files for $name"
    return 0
  fi
  # `! -type d` rather than `-type f`: a symlink added inside the package — including a dangling
  # one — would be invisible to a regular-files-only inventory, and could carry content past a
  # check whose whole purpose is to prove the tree is exactly upstream's.
  if ! ( cd "$root" && find . ! -type d ) > "$WORK/raw.$$"; then
    echo "could not inventory the files in $name"
    return 0
  fi
  if ! sed 's|^\./||' < "$WORK/raw.$$" | LC_ALL=C sort > "$present"; then
    echo "could not inventory the files in $name"
    return 0
  fi
  # comm's status is checked rather than swallowed with `|| true`: a failure here must not read
  # as "no extra files".
  if ! comm -13 "$listed" "$present" > "$WORK/extra.$$"; then
    echo "could not compare the file list for $name"
    return 0
  fi
  # Read line by line: an unquoted expansion would word-split a filename containing a space.
  while IFS= read -r rel; do
    [ -n "$rel" ] && echo "$rel is not listed in the manifest"
  done < "$WORK/extra.$$"
}

# Downloads the archive, verifies the whole thing against the manifest in a temp directory, and
# only then swaps it in — keeping the previous package until the new one is in place, so a failed
# swap restores what was there rather than leaving nothing.
restore_model() {
  local name="$1" install_path="$2" url="$3" archive_sha="$4" member="$5"
  local dest="$REPO_ROOT/$install_path"
  local tmp
  # Checked explicitly: errexit is suspended in this function, so an unchecked failure would
  # leave $tmp empty and send every path below to /archive.zip and /unpacked.
  if ! tmp="$(mktemp -d)" || [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    echo "  ✗ $name: could not create a temporary directory" >&2
    return 1
  fi
  # Also recorded globally: the RETURN trap covers a normal return, but not the shell being
  # killed mid-download, and the EXIT trap is what runs then.
  RESTORE_TMP="$tmp"
  # shellcheck disable=SC2064  # expand $tmp now: the trap must survive the variable going away.
  trap "rm -rf '$tmp'; RESTORE_TMP=''" RETURN

  echo "  ↓ downloading $name"
  # Every step is status-checked explicitly. This function is called from a context that suspends
  # `set -e` for its whole body, so an unchecked failure would fall through to the next line —
  # which, around the swap, would mean destroying a good copy on the way to reporting success.
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
  if [ -L "$tmp/unpacked/$member" ]; then
    echo "  ✗ $name: '$member' is a symlink inside the archive — refusing to follow it" >&2
    return 1
  fi
  if [ ! -d "$tmp/unpacked/$member" ]; then
    echo "  ✗ $name: archive does not contain '$member'" >&2
    return 1
  fi

  # Validate what we are about to install BEFORE touching $dest — including the extra-file
  # direction. Doing this afterwards would install an unlisted file and only then report the
  # failure, leaving a package the manifest rejects.
  local problems; problems="$(diff_tree_against_manifest "$name" "$tmp/unpacked/$member")"
  if [ -n "$problems" ]; then
    echo "  ✗ $name: the downloaded package does not match the manifest — not installing:" >&2
    # Indent every line: a single printf with a multi-line argument indents only the first.
    printf '%s\n' "$problems" | while IFS= read -r line; do echo "      $line" >&2; done
    return 1
  fi

  # Staged and backed up beside $dest: `mv` is only a rename — and so only atomic — within one
  # filesystem. Both names are dot-prefixed and gitignored so an interrupted run leaves nothing
  # visible in the working tree. __MACOSX resource forks from Apple's zip stay behind in $tmp.
  local dir; dir="$(dirname "$dest")"
  local staging="$dir/.$(basename "$dest").incoming"
  local backup="$dir/.$(basename "$dest").backup"

  if ! mkdir -p "$dir"; then
    echo "  ✗ $name: could not create the destination directory" >&2
    return 1
  fi
  if ! rm -rf "$staging"; then
    echo "  ✗ $name: could not clear the previous staging directory" >&2
    return 1
  fi
  # A backup left by an interrupted run is the ONLY copy when the destination is gone. Deleting it
  # here and then failing to stage would destroy the last recoverable bytes, so put it back first.
  if [ -e "$backup" ]; then
    if [ ! -e "$dest" ]; then
      if ! mv "$backup" "$dest"; then
        echo "  ✗ $name: a previous run left its only copy at $backup and it could not be restored" >&2
        return 1
      fi
    elif ! rm -rf "$backup"; then
      echo "  ✗ $name: could not clear the stale backup directory" >&2
      return 1
    fi
  fi
  if ! cp -R "$tmp/unpacked/$member" "$staging"; then
    echo "  ✗ $name: could not stage the restored package" >&2
    rm -rf "$staging"
    return 1
  fi

  # Move the old package aside rather than deleting it, so the swap is reversible.
  if [ -e "$dest" ] && ! mv "$dest" "$backup"; then
    echo "  ✗ $name: could not set the existing package aside" >&2
    rm -rf "$staging"
    return 1
  fi
  if ! mv "$staging" "$dest"; then
    echo "  ✗ $name: could not move the restored package into place" >&2
    if [ -e "$backup" ] && mv "$backup" "$dest"; then
      echo "    the previous package was put back" >&2
    else
      echo "    WARNING: could not put the previous package back; it is at $backup" >&2
    fi
    rm -rf "$staging"
    return 1
  fi
  # Checked like every other step: an unchecked failure here would be masked by the trailing
  # echo, the function would return success, and a stale backup would sit in the tree while
  # later runs kept reporting a clean result.
  if ! rm -rf "$backup"; then
    echo "  ✗ $name: restored, but the old copy could not be removed from $backup" >&2
    return 1
  fi
  echo "  ✓ $name restored"
  return 0
}

if ! validate_manifest; then
  echo "✗ $MANIFEST is not usable — refusing to report success" >&2
  exit 1
fi

MODELS="$WORK/models"
if ! model_names > "$MODELS"; then
  echo "✗ could not read $MANIFEST" >&2
  exit 1
fi
if [ ! -s "$MODELS" ]; then
  echo "✗ $MANIFEST lists no models — refusing to report success" >&2
  exit 1
fi

status=0
checked=0

while IFS= read -r name; do
  [ -n "$name" ] || continue
  meta="$(model_meta "$name")"
  IFS=$'\t' read -r install_path url archive_sha member <<EOF
$meta
EOF
  pkg="$REPO_ROOT/$install_path"

  # One diff decides everything: whether a restore is warranted, and — recomputed afterwards —
  # whether the model passes. A restore's own exit status is never the verdict, so a transient
  # failure that a retry repairs leaves no stale failure behind, and a package whose only damage
  # is an ADDED file is still repaired rather than merely reported.
  if [ -d "$pkg" ]; then
    problems="$(diff_tree_against_manifest "$name" "$pkg")"
  else
    problems="the package directory is missing"
  fi

  if [ -n "$problems" ] && [ "$RESTORE" = 1 ]; then
    echo "✗ $name differs — restoring"
    restore_model "$name" "$install_path" "$url" "$archive_sha" "$member" || true
    if [ -d "$pkg" ]; then
      problems="$(diff_tree_against_manifest "$name" "$pkg")"
    else
      problems="the package directory is missing"
    fi
  fi

  if [ -z "$problems" ]; then
    n="$(expected_files_for "$name" | wc -l | tr -d ' ')"
    checked=$((checked + n))
    echo "✓ $name ($n files)"
  else
    echo "✗ $name:" >&2
    printf '%s\n' "$problems" | while IFS= read -r line; do echo "    $line" >&2; done
    [ "$RESTORE" = 1 ] || echo "    re-run with --restore to repair" >&2
    status=1
  fi
done < "$MODELS"

echo ""
if [ "$checked" -eq 0 ] && [ "$status" -eq 0 ]; then
  echo "✗ no files were checked — refusing to report success" >&2
  exit 1
fi
if [ "$status" = 0 ]; then
  echo "All covered demo models match the digests recorded in the manifest ($checked files)."
else
  echo "Some demo models do not match. See scripts/demo_models.json for the expected digests." >&2
fi
exit "$status"
