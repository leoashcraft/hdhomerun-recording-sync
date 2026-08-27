#!/usr/bin/env bash
#
# HDHomeRun Recording Sync - macOS and Linux version
#
# Moves completed recordings off an HDHomeRun FLEX DVR to another storage
# location, then deletes the source only after the copy is verified.
#
# Unix port of HDHomeRunRecordingsSync.ps1. Behavior is intentionally
# identical; see README.md for details.
#
# Written for bash 3.2 (the version macOS ships) so it runs unmodified on
# macOS and on Linux, where bash is normally much newer.

SCRIPT_VERSION="1.0.0"

HDHOMERUN="http://hdhomerun.local"
DESTINATION_ROOT="$HOME/Media/TV"
COMPLETION_BUFFER_SECONDS=90
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/hdhomerun-archive.log"
LOCK_DIR="$LOG_DIR/.sync.lock"

MIN_RECORDING_BYTES=1048576

usage() {
    cat <<'USAGE'
Usage: hdhomerun-recordings-sync.sh [options]

Options:
  --hdhomerun URL   HDHomeRun base URL   (default: http://hdhomerun.local)
  --dest PATH       Destination root     (default: $HOME/Media/TV)
  --buffer SECONDS  Completion buffer    (default: 90)
  --dry-run         Report what would happen; copy and delete nothing
  -h, --help        Show this help

Examples:
  ./hdhomerun-recordings-sync.sh --dest "/Volumes/Media/TV"
  ./hdhomerun-recordings-sync.sh --hdhomerun "http://192.168.1.50" --dry-run
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hdhomerun)
            HDHOMERUN="$2"; shift 2 ;;
        --dest|--destination-root)
            DESTINATION_ROOT="$2"; shift 2 ;;
        --buffer|--completion-buffer-seconds)
            COMPLETION_BUFFER_SECONDS="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

# Trailing slashes break URL construction below.
HDHOMERUN="${HDHOMERUN%/}"
DESTINATION_ROOT="${DESTINATION_ROOT%/}"

mkdir -p "$LOG_DIR"

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S')  $1"
    printf '%s\n' "$line" >> "$LOG_FILE"
    printf '%s\n' "$line"
}

require_tools() {
    local missing=false
    local tool
    for tool in curl jq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log "FATAL: Required tool '$tool' not found in PATH."
            missing=true
        fi
    done
    if [ "$missing" = true ]; then
        log "PATH was: $PATH"
        return 1
    fi
    return 0
}

# Replace characters that are invalid on Windows and SMB shares as well as
# macOS. The destination is often a NAS or a library shared with Windows
# machines, so we sanitize against the stricter Windows set.
safe_name() {
    printf '%s' "$1" \
        | tr '/\\:*?"<>|' '_________' \
        | tr -d '\000-\037' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\.*$//'
}

unix_time() {
    date '+%s'
}

# stat and date take incompatible flags in BSD userland (macOS) and GNU
# userland (Linux), so the two calls that need them are wrapped here.
case "$(uname -s)" in
    Darwin|*BSD*) PLATFORM="bsd" ;;
    *)            PLATFORM="gnu" ;;
esac

file_size() {
    if [ "$PLATFORM" = "bsd" ]; then
        stat -f%z "$1"
    else
        stat -c%s "$1"
    fi
}

epoch_to_date() {
    if [ "$PLATFORM" = "bsd" ]; then
        date -r "$1" '+%Y-%m-%d' 2>/dev/null
    else
        date -d "@$1" '+%Y-%m-%d' 2>/dev/null
    fi
}

is_positive_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] ;;
    esac
}

# Mirrors Get-EpisodeDestination: "Season 09/Show - S09E08 - Title.mpg" when
# SxxExx metadata exists, otherwise a date-based name in the show folder.
episode_destination() {
    local title="$1" episode_title="$2" episode_number="$3"
    local original_airdate="$4" start_time="$5"

    local safe_title safe_episode_title show_dir file_base
    local season_number season_dir air_date

    safe_title="$(safe_name "$title")"
    safe_episode_title="$(safe_name "$episode_title")"
    show_dir="$DESTINATION_ROOT/$safe_title"
    file_base="$safe_title"

    if [[ "$episode_number" =~ ^S([0-9]+)E([0-9]+)$ ]]; then
        # 10# forces base 10 so "09" is not read as invalid octal.
        season_number=$((10#${BASH_REMATCH[1]}))
        season_dir="$(printf '%s/Season %02d' "$show_dir" "$season_number")"

        file_base="$file_base - $episode_number"
        if [ -n "$safe_episode_title" ]; then
            file_base="$file_base - $safe_episode_title"
        fi

        printf '%s/%s.mpg' "$season_dir" "$(safe_name "$file_base")"
        return 0
    fi

    air_date=""
    if is_positive_int "$original_airdate"; then
        air_date="$(epoch_to_date "$original_airdate")"
    fi
    if [ -z "$air_date" ] && is_positive_int "$start_time"; then
        air_date="$(epoch_to_date "$start_time")"
    fi

    if [ -n "$air_date" ]; then
        file_base="$file_base - $air_date"
    fi
    if [ -n "$safe_episode_title" ]; then
        file_base="$file_base - $safe_episode_title"
    fi

    printf '%s/%s.mpg' "$show_dir" "$(safe_name "$file_base")"
}

test_destination() {
    local write_test

    if [ ! -d "$DESTINATION_ROOT" ]; then
        log "OFFLINE: Destination is not accessible: $DESTINATION_ROOT. Nothing will be copied or deleted."
        return 1
    fi

    write_test="$DESTINATION_ROOT/.hdhomerun_write_test_$$"

    if ! : > "$write_test" 2>/dev/null; then
        rm -f "$write_test" 2>/dev/null
        log "OFFLINE/READ-ONLY: Destination is not writable: $DESTINATION_ROOT. Nothing will be copied or deleted."
        return 1
    fi

    rm -f "$write_test" 2>/dev/null
    log "DESTINATION OK: $DESTINATION_ROOT is accessible and writable."
    return 0
}

# Returns 0 only when a verified copy now exists at the destination, which is
# the sole condition under which the caller may delete the source.
download_recording() {
    local url="$1" destination="$2"
    local partial="$2.partial"
    local dest_dir size final_size

    if [ -e "$destination" ]; then
        log "SKIP: Destination already exists; source will NOT be deleted: $destination"
        return 1
    fi

    [ -e "$partial" ] && rm -f "$partial"

    dest_dir="$(dirname "$destination")"
    if ! mkdir -p "$dest_dir"; then
        log "ERROR: Could not create destination directory: $dest_dir. Source retained."
        return 1
    fi

    log "COPY: $url -> $destination"

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would download and then delete the source recording."
        return 1
    fi

    if ! curl --fail --location --silent --show-error --output "$partial" "$url"; then
        log "ERROR: curl failed. Source retained."
        [ -e "$partial" ] && rm -f "$partial"
        return 1
    fi

    if [ ! -f "$partial" ]; then
        log "ERROR: Download produced no file. Source retained."
        return 1
    fi

    size="$(file_size "$partial")"

    if [ "$size" -lt "$MIN_RECORDING_BYTES" ]; then
        log "ERROR: Downloaded file is suspiciously small ($size bytes). Source retained."
        rm -f "$partial"
        return 1
    fi

    if ! mv -f "$partial" "$destination"; then
        log "ERROR: Could not move file into place. Source retained."
        return 1
    fi

    if [ ! -f "$destination" ]; then
        log "ERROR: Final file missing after move. Source retained."
        return 1
    fi

    final_size="$(file_size "$destination")"

    if [ "$final_size" != "$size" ]; then
        log "ERROR: Final size mismatch ($final_size vs $size). Source retained."
        return 1
    fi

    log "COPIED: $destination ($final_size bytes)"
    return 0
}

delete_recording() {
    local cmd_url="$1"
    local separator="?"
    local delete_url

    case "$cmd_url" in
        *\?*) separator="&" ;;
    esac

    delete_url="${cmd_url}${separator}cmd=delete&rerecord=0"

    log "DELETE: Removing successfully archived recording from HDHomeRun."

    if ! curl --fail --silent --show-error --request POST "$delete_url" >/dev/null; then
        log "ERROR: HDHomeRun delete command failed. Archived copy remains safe."
        return 1
    fi

    log "DELETED: HDHomeRun source removed."
    return 0
}

# launchd already refuses to run two copies of the same job, but this also
# covers manual runs overlapping a scheduled one.
acquire_lock() {
    local lock_pid

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s' "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"

    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        log "SKIP: Another sync is already running (pid $lock_pid)."
        return 1
    fi

    log "WARN: Removing stale lock from pid ${lock_pid:-unknown}."
    rm -rf "$LOCK_DIR"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s' "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    log "ERROR: Could not acquire lock."
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

main() {
    local series_json episodes_json now
    local series_title episodes_url
    local title episode_title episode_number original_airdate
    local start_time record_end play_url cmd_url filename
    local destination

    log "----- Scan started -----"
    log "Script version: $SCRIPT_VERSION"

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: No files will be copied and no recordings will be deleted."
    fi

    require_tools || return 1
    test_destination || return 0

    series_json="$(curl --fail --location --silent --show-error "$HDHOMERUN/recorded_files.json" 2>/dev/null)"

    if [ -z "$series_json" ]; then
        log "No recordings found."
        return 0
    fi

    now="$(unix_time)"

    while IFS=$'\037' read -r series_title episodes_url; do
        [ -z "$series_title$episodes_url" ] && continue

        if [ -z "$episodes_url" ]; then
            log "WARN: No EpisodesURL for '$series_title'."
            continue
        fi

        log "FOUND SERIES: $series_title"

        episodes_json="$(curl --fail --location --silent --show-error "$episodes_url" 2>/dev/null)"
        [ -z "$episodes_json" ] && continue

        while IFS=$'\037' read -r title episode_title episode_number \
            original_airdate start_time record_end play_url cmd_url filename; do

            [ -z "$title$filename$play_url" ] && continue

            if ! is_positive_int "$record_end" \
                || [ "$record_end" -gt $((now - COMPLETION_BUFFER_SECONDS)) ]; then
                log "WAIT: '$title' '$episode_number' is still recording or just finished."
                continue
            fi

            if [ -z "$play_url" ] || [ -z "$cmd_url" ]; then
                log "WARN: Missing PlayURL/CmdURL for '$filename'."
                continue
            fi

            destination="$(episode_destination "$title" "$episode_title" \
                "$episode_number" "$original_airdate" "$start_time")"

            if download_recording "$play_url" "$destination"; then
                delete_recording "$cmd_url" || true
            fi
        done <<EPISODES
$(printf '%s' "$episodes_json" | jq -r '
    (if type == "array" then .[] else . end)
    | [ (.Title // ""), (.EpisodeTitle // ""), (.EpisodeNumber // ""),
        (.OriginalAirdate // 0), (.StartTime // 0), (.RecordEndTime // 0),
        (.PlayURL // ""), (.CmdURL // ""), (.Filename // "") ]
    | map(tostring | gsub("[\n\r\t]"; " "))
    | join("\u001f")' 2>/dev/null)
EPISODES

    done <<SERIES
$(printf '%s' "$series_json" | jq -r '
    (if type == "array" then .[] else . end)
    | [ (.Title // ""), (.EpisodesURL // "") ]
    | map(tostring | gsub("[\n\r\t]"; " "))
    | join("\u001f")' 2>/dev/null)
SERIES

    log "----- Scan finished -----"
    return 0
}

acquire_lock || exit 0
trap release_lock EXIT INT TERM

main
exit $?
