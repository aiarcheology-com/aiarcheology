#!/bin/bash
#
# Uninstalls the ML Browser app from this Mac and removes its app data -- the
# Core Data SQLite store, the findings and their images, preferences, caches,
# cookies and WebKit state.
#
# Usage:
#   ./scripts/uninstall_macos.sh              # list targets, confirm, then remove
#   ./scripts/uninstall_macos.sh --dry-run    # list targets only, remove nothing
#   ./scripts/uninstall_macos.sh --yes        # remove without the confirmation prompt
#   ./scripts/uninstall_macos.sh --keep-app   # remove the data, leave the app installed
#   ./scripts/uninstall_macos.sh --keep-data  # remove the app, leave the data in place
#   ./scripts/uninstall_macos.sh --help
#
# This is irreversible: any finding, note or image that was never synced to the
# cloud is gone. Run --dry-run first if you are not sure what is installed.
#
# ML Browser on a Mac is the iOS app in a wrapper bundle, so its data lives in a
# sandbox container under ~/Library/Containers. That container is usually named
# after a UUID rather than the bundle id, and the metadata plist naming its
# owner is unreadable without Full Disk Access -- hence the marker-file fallback
# in looks_like_our_container below.
#
# Not covered: keychain items in the data-protection keychain -- the Clerk
# sign-in session and the free-access anchor (#557). No macOS command line tool
# can reach that keychain, so sign out in the app before uninstalling if you
# want the session gone. The script still tries the login keychain, which is
# where a locally built, non-sandboxed copy may have put them.
#
set -euo pipefail
shopt -s nullglob

BUNDLE_ID="${MLBROWSER_BUNDLE_ID:-com.aiarcheology.ios}"   # PRODUCT_BUNDLE_IDENTIFIER
APP_NAME="${MLBROWSER_APP_NAME:-ML Browser}"               # PRODUCT_NAME
STORE_NAME="MLBrowser"                                     # DataController.containerName

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

DRY_RUN=0
ASSUME_YES=0
REMOVE_APP=1
REMOVE_DATA=1

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Uninstall $APP_NAME ($BUNDLE_ID) from this Mac and delete its app data."
    echo ""
    echo "Options:"
    echo "  --dry-run, -n    List what would be removed, remove nothing"
    echo "  --yes, -y        Do not ask for confirmation"
    echo "  --keep-app       Remove app data only, leave the app installed"
    echo "  --keep-data      Remove the app only, leave app data in place"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Environment:"
    echo "  MLBROWSER_BUNDLE_ID   Override the bundle identifier (default: $BUNDLE_ID)"
    echo "  MLBROWSER_APP_NAME    Override the app name (default: $APP_NAME)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --keep-app)   REMOVE_APP=0 ;;
        --keep-data)  REMOVE_DATA=0 ;;
        --help|-h)    show_help; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "" >&2; show_help >&2; exit 1 ;;
    esac
    shift
done

if [ "$REMOVE_APP" -eq 0 ] && [ "$REMOVE_DATA" -eq 0 ]; then
    echo "Error: --keep-app and --keep-data together leave nothing to do." >&2
    exit 1
fi

# --- target collection -------------------------------------------------------

APP_TARGETS=()
DATA_TARGETS=()
CONTAINERS=()

# Refuses anything outside the two trees this script may delete from, so a
# mistyped override or an empty variable can never expand into a wide path.
is_safe_target() {
    local path="$1"
    case "$path" in
        ""|"/"|"$HOME"|"$HOME/"|"/Applications"|"/Applications/") return 1 ;;
    esac
    case "$path" in
        "$HOME"/Library/?*|/Applications/?*.app|"$HOME"/Applications/?*.app) return 0 ;;
        *) return 1 ;;
    esac
}

# Appends to the named array if the path exists, is safe, and is not already in.
add_target() {
    # shellcheck disable=SC2034  # $existing is read by the eval-built loop below.
    local array_name="$1" path="$2" existing
    [ -e "$path" ] || return 0
    if ! is_safe_target "$path"; then
        echo "Warning: refusing unsafe path '$path'" >&2
        return 0
    fi
    eval 'for existing in ${'"$array_name"'[@]+"${'"$array_name"'[@]}"}; do
              [ "$existing" = "$path" ] && return 0
          done
          '"$array_name"'+=("$path")'
}

# The authoritative owner of a container, when it can be read at all.
container_identifier() {
    local plist="$1/.com.apple.containermanagerd.metadata.plist"
    [ -r "$plist" ] || return 1
    plutil -extract MCMMetadataIdentifier raw -o - "$plist" 2>/dev/null
}

looks_like_our_container() {
    local dir="$1" ident
    # Trust the metadata plist when it is readable -- including when it names a
    # different app, which settles the question without guessing further.
    if ident="$(container_identifier "$dir")" && [ -n "$ident" ]; then
        [ "$ident" = "$BUNDLE_ID" ]
        return
    fi
    # Without Full Disk Access the plist is off limits, so fall back to the
    # artefacts the app writes under its own bundle id or name. Those names are
    # namespaced per app, so another app's container cannot carry them.
    [ -e "$dir/Data/Library/Preferences/$BUNDLE_ID.plist" ] && return 0
    [ -d "$dir/Data/Library/Caches/$BUNDLE_ID" ] && return 0
    [ -d "$dir/Data/Library/HTTPStorages/$BUNDLE_ID" ] && return 0
    [ -e "$dir/Data/Library/Application Support/$APP_NAME/$STORE_NAME.sqlite" ] && return 0
    return 1
}

collect_containers() {
    local dir
    for dir in "$HOME"/Library/Containers/*/; do
        dir="${dir%/}"
        if looks_like_our_container "$dir"; then
            add_target CONTAINERS "$dir"
        fi
    done
}

collect_app_targets() {
    local path
    add_target APP_TARGETS "/Applications/$APP_NAME.app"
    add_target APP_TARGETS "$HOME/Applications/$APP_NAME.app"
    for path in /Applications/*/"$APP_NAME.app"; do
        add_target APP_TARGETS "$path"
    done
}

collect_data_targets() {
    local path
    collect_containers
    for path in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
        add_target DATA_TARGETS "$path"
    done

    for path in "$HOME"/Library/Group\ Containers/*."$BUNDLE_ID" \
                "$HOME"/Library/Group\ Containers/group."$BUNDLE_ID"; do
        add_target DATA_TARGETS "$path"
    done

    add_target DATA_TARGETS "$HOME/Library/Application Scripts/$BUNDLE_ID"
    add_target DATA_TARGETS "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

    # Paths below are only populated by a non-sandboxed local build; an App
    # Store or TestFlight install keeps all of this inside the container. Both
    # are checked because both happen on a development machine.
    add_target DATA_TARGETS "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    for path in "$HOME"/Library/Preferences/ByHost/"$BUNDLE_ID".*.plist; do
        add_target DATA_TARGETS "$path"
    done
    add_target DATA_TARGETS "$HOME/Library/Caches/$BUNDLE_ID"
    add_target DATA_TARGETS "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    add_target DATA_TARGETS "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
    add_target DATA_TARGETS "$HOME/Library/Cookies/$BUNDLE_ID.binarycookies"
    add_target DATA_TARGETS "$HOME/Library/WebKit/$BUNDLE_ID"
    add_target DATA_TARGETS "$HOME/Library/Application Support/$APP_NAME"
    add_target DATA_TARGETS "$HOME/Library/Logs/$APP_NAME"
    for path in "$HOME"/Library/Logs/DiagnosticReports/"$APP_NAME"[-_]*; do
        add_target DATA_TARGETS "$path"
    done
}

# Copies Spotlight knows about that this script will not touch -- a build
# product in DerivedData, say. Reported so the list is not silently incomplete.
report_other_copies() {
    local path found=0
    command -v mdfind >/dev/null 2>&1 || return 0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            /Applications/*|"$HOME"/Applications/*) continue ;;
        esac
        [ "$found" -eq 0 ] && echo "Other copies found (not removed):"
        found=1
        echo "  $path"
    done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)
    [ "$found" -eq 1 ] && echo ""
    return 0
}

human_size() {
    du -sh -- "$1" 2>/dev/null | cut -f1 | tr -d '[:space:]'
}

print_targets() {
    local label="$1" path size
    shift
    [ $# -eq 0 ] && return 0
    echo "$label"
    for path in "$@"; do
        size="$(human_size "$path")"
        printf '  %s  (%s)\n' "$path" "${size:-?}"
    done
    echo ""
}

# The store and the findings are the only targets a reinstall cannot bring
# back, so they get named rather than left implicit inside a container path.
print_irreplaceable() {
    local dir store documents size
    for dir in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
        store="$dir/Data/Library/Application Support/$APP_NAME/$STORE_NAME.sqlite"
        documents="$dir/Data/Documents"
        [ -e "$store" ] || [ -d "$documents" ] || continue
        echo "Irreplaceable data in $dir:"
        if [ -e "$store" ]; then
            size="$(human_size "$store")"
            echo "  Core Data store  $store  (${size:-?}, plus -wal and -shm)"
        fi
        if [ -d "$documents" ]; then
            size="$(human_size "$documents")"
            echo "  Documents        $documents  (${size:-?}) -- findings and their images"
        fi
        echo "  Anything here that was never synced to the cloud cannot be recovered."
        echo ""
    done
}

# --- run ---------------------------------------------------------------------

[ "$REMOVE_APP" -eq 1 ] && collect_app_targets
[ "$REMOVE_DATA" -eq 1 ] && collect_data_targets

echo "$APP_NAME  ($BUNDLE_ID)"
echo ""

print_targets "App bundle:" ${APP_TARGETS[@]+"${APP_TARGETS[@]}"}
print_targets "App data:" ${DATA_TARGETS[@]+"${DATA_TARGETS[@]}"}
print_irreplaceable

TOTAL=$(( ${#APP_TARGETS[@]} + ${#DATA_TARGETS[@]} ))
if [ "$TOTAL" -eq 0 ]; then
    echo "Nothing to remove: no $APP_NAME install or app data found for $BUNDLE_ID."
    report_other_copies
    exit 0
fi

report_other_copies

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run: nothing was removed."
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    if [ ! -t 0 ]; then
        echo "Error: not a terminal; re-run with --yes to remove without confirmation." >&2
        exit 1
    fi
    printf 'Remove the %d item(s) above? This cannot be undone. Type "yes" to continue: ' "$TOTAL"
    read -r reply
    if [ "$reply" != "yes" ]; then
        echo "Aborted; nothing was removed."
        exit 1
    fi
fi

# Quit the app first: deleting a container out from under a running app leaves
# it writing into an unlinked store and rewriting its preferences on exit.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Quitting $APP_NAME..."
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Still running; sending SIGTERM."
        pkill -x "$APP_NAME" >/dev/null 2>&1 || true
        sleep 2
    fi
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Error: $APP_NAME is still running; quit it and re-run." >&2
        exit 1
    fi
fi

# Drop cfprefsd's in-memory copy before the plist goes, or it can write the
# cached preferences straight back out.
if [ "$REMOVE_DATA" -eq 1 ]; then
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

# rm -rf deletes a symlink, never what it points at, so the container's
# Downloads and Movies links out to the real home folders are safe.
FAILED=0
for path in ${APP_TARGETS[@]+"${APP_TARGETS[@]}"} ${DATA_TARGETS[@]+"${DATA_TARGETS[@]}"}; do
    if is_safe_target "$path" && rm -rf -- "$path"; then
        echo "Removed  $path"
    else
        echo "FAILED   $path" >&2
        FAILED=$((FAILED + 1))
    fi
done
echo ""

if [ "$REMOVE_DATA" -eq 1 ]; then
    # Only reaches the login keychain. Items in the data-protection keychain --
    # which is where an App Store or TestFlight install puts them -- survive.
    for service in "$BUNDLE_ID" "$BUNDLE_ID.freeAccess"; do
        if security delete-generic-password -s "$service" >/dev/null 2>&1; then
            echo "Removed login-keychain item for service '$service'"
        fi
    done
fi

if [ "$REMOVE_APP" -eq 1 ] && [ ${#APP_TARGETS[@]} -gt 0 ] && [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
    echo "Rebuilt the Launch Services database."
fi

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "Done with $FAILED failure(s). Re-run, or remove the paths above by hand."
    exit 1
fi

echo "Done."
if [ "$REMOVE_DATA" -eq 1 ]; then
    echo "Still on this Mac: any keychain item in the data-protection keychain"
    echo "(the Clerk sign-in session, the free-access anchor). Sign out in the app"
    echo "before uninstalling next time if you need those cleared too."
fi
