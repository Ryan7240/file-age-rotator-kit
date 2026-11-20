#!/usr/bin/env bash
# file_age_rotator_kit.sh
#
# Delete or archive files in a directory whose mtime is older than a
# specified age. Pure bash + coreutils; no third-party dependencies.
#
# Design note: we deliberately do NOT parse `ls` output. `find -printf` is a
# GNU extension, so instead we use `find ... -exec stat` which is portable
# across GNU and BSD coreutils. The age comparison is done by converting the
# mtime to an integer epoch second and comparing against `now - age`.
#
# The "now" value is passed in explicitly to every function so that tests can
# supply a fixed clock and remain deterministic.

set -euo pipefail

# Parse a duration string like "30s", "15m", "2h", "7d" into seconds.
# Returns the number of seconds on stdout. Exits non-zero on bad input.
#
# We accept only a single unit suffix to keep the grammar unambiguous; a
# compound duration such as "1h30m" is rejected rather than guessed at.
parse_duration() {
    local spec="${1:-}"
    if [[ -z "$spec" ]]; then
        echo "parse_duration: empty duration" >&2
        return 2
    fi
    local num unit
    if [[ "$spec" =~ ^([0-9]+)([smhd])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo "parse_duration: bad duration '$spec' (want e.g. 30s, 15m, 2h, 7d)" >&2
        return 2
    fi
    case "$unit" in
        s) printf '%s\n' "$num" ;;
        m) printf '%s\n' "$((num * 60))" ;;
        h) printf '%s\n' "$((num * 3600))" ;;
        d) printf '%s\n' "$((num * 86400))" ;;
        *) echo "parse_duration: unreachable unit '$unit'" >&2; return 2 ;;
    esac
}

# Emit "<mtime> <path>" for every regular file directly inside $1.
# $1 must be an existing directory. Output is one record per line.
#
# We sort by path so callers get a stable order regardless of filesystem
# iteration order; tests rely on this.
list_files_with_mtime() {
    local dir="${1:-}"
    if [[ ! -d "$dir" ]]; then
        echo "list_files_with_mtime: not a directory: '$dir'" >&2
        return 2
    fi
    # -maxdepth 1 keeps this a rotator for a single directory, not a tree.
    # -type f skips subdirectories and symlinks-to-directories.
    find "$dir" -maxdepth 1 -type f -print0 \
        | while IFS= read -r -d '' f; do
            # stat -c is GNU; -f is BSD. Try GNU first, fall back to BSD.
            local mt
            if mt=$(stat -c '%Y' -- "$f" 2>/dev/null); then
                :
            else
                mt=$(stat -f '%m' -- "$f" 2>/dev/null) || {
                    echo "list_files_with_mtime: cannot stat '$f'" >&2
                    return 3
                }
            fi
            printf '%s %s\n' "$mt" "$f"
        done \
        | LC_ALL=C sort -k2
}

# Decide whether a file with mtime $1 is older than $2 seconds relative to
# the reference time $3. All three are integer epoch seconds.
# Returns 0 if the file is strictly older than the threshold, 1 otherwise.
#
# "Strictly older" means age > max_age. A file exactly at the boundary is
# kept, which is the safer default for a destructive tool.
is_older_than() {
    local mtime="${1:-0}" max_age="${2:-0}" now="${3:-0}"
    local age=$((now - mtime))
    if (( age > max_age )); then
        return 0
    fi
    return 1
}

# Delete files under $1 older than $2 seconds relative to clock $3.
# Prints the path of each deleted file to stdout, one per line.
# Returns the number of files deleted via stdout as a final count line?
# No: the count is returned as the function's exit status is awkward for
# large counts, so we print a summary line prefixed with "deleted:".
#
# To keep the output machine-parseable we emit one "DEL <path>" line per
# file and nothing else. Callers who want a count can pipe through wc -l.
rotate_delete() {
    local dir="${1:-}" max_age="${2:-0}" now="${3:-0}"
    local line mtime path
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        mtime="${line%% *}"
        path="${line#* }"
        if is_older_than "$mtime" "$max_age" "$now"; then
            if rm -f -- "$path"; then
                printf 'DEL %s\n' "$path"
            else
                printf 'ERR %s\n' "$path" >&2
                return 3
            fi
        fi
    done < <(list_files_with_mtime "$dir")
}

# Move files under $1 older than $2 seconds (relative to clock $3) into the
# archive directory $4. $4 is created if missing. Prints "ARC <src> -> <dst>"
# for each archived file.
#
# If a destination name already exists we append a numeric suffix rather
# than overwriting; losing an archived file is worse than an ugly name.
rotate_archive() {
    local dir="${1:-}" max_age="${2:-0}" now="${3:-0}" archive_dir="${4:-}"
    if [[ -z "$archive_dir" ]]; then
        echo "rotate_archive: archive directory required" >&2
        return 2
    fi
    if [[ ! -d "$archive_dir" ]]; then
        mkdir -p -- "$archive_dir" || {
            echo "rotate_archive: cannot create '$archive_dir'" >&2
            return 3
        }
    fi
    local line mtime path base dst suffix
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        mtime="${line%% *}"
        path="${line#* }"
        if is_older_than "$mtime" "$max_age" "$now"; then
            base=$(basename -- "$path")
            dst="$archive_dir/$base"
            suffix=0
            while [[ -e "$dst" ]]; do
                suffix=$((suffix + 1))
                dst="$archive_dir/$base.$suffix"
            done
            if mv -- "$path" "$dst"; then
                printf 'ARC %s -> %s\n' "$path" "$dst"
            else
                printf 'ERR %s\n' "$path" >&2
                return 3
            fi
        fi
    done < <(list_files_with_mtime "$dir")
}

# Convenience: parse a duration then dispatch. Kept separate so the parser
# can be tested without touching the filesystem.
rotate() {
    local mode="${1:-}" dir="${2:-}" duration="${3:-}" now="${4:-}"
    local archive_dir="${5:-}"
    local seconds
    seconds=$(parse_duration "$duration")
    case "$mode" in
        delete)  rotate_delete  "$dir" "$seconds" "$now" ;;
        archive) rotate_archive "$dir" "$seconds" "$now" "$archive_dir" ;;
        *) echo "rotate: unknown mode '$mode' (want delete|archive)" >&2; return 2 ;;
    esac
}
