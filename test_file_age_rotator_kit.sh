#!/usr/bin/env bash
# Tests for file_age_rotator_kit.sh. Run with: bash test_file_age_rotator_kit.sh
set -euo pipefail

# Locate the library relative to this test file so it works from any cwd.
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=file_age_rotator_kit.sh
source "$HERE/file_age_rotator_kit.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" label="${3:-assert_eq}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf 'ok %d - %s\n' "$PASS" "$label"
    else
        FAIL=$((FAIL + 1))
        printf 'not ok %d - %s\n' "$FAIL" "$label"
        printf '  expected: %q\n' "$expected"
        printf '  actual:   %q\n' "$actual"
    fi
}

assert_status() {
    local expected="$1" actual="$2" label="${3:-assert_status}"
    assert_eq "$expected" "$actual" "$label"
}

# --- parse_duration ---------------------------------------------------------

assert_eq "30"   "$(parse_duration 30s)" "parse 30s"
assert_eq "900"  "$(parse_duration 15m)" "parse 15m"
assert_eq "7200" "$(parse_duration 2h)"  "parse 2h"
assert_eq "604800" "$(parse_duration 7d)" "parse 7d"
assert_eq "0"    "$(parse_duration 0s)"  "parse 0s"

set +e
parse_duration "" >/dev/null 2>&1
assert_status 2 $? "empty duration rejected"
parse_duration "10" >/dev/null 2>&1
assert_status 2 $? "missing unit rejected"
parse_duration "1h30m" >/dev/null 2>&1
assert_status 2 $? "compound duration rejected"
parse_duration "-5s" >/dev/null 2>&1
assert_status 2 $? "negative duration rejected"
parse_duration "5x" >/dev/null 2>&1
assert_status 2 $? "unknown unit rejected"
set -e

# --- is_older_than ----------------------------------------------------------

# now=1000, max_age=100 => threshold=900. mtime=800 is older, mtime=900 is not.
set +e
is_older_than 800 100 1000
assert_status 0 $? "mtime 800 older than 100s at now=1000"
is_older_than 900 100 1000
assert_status 1 $? "mtime exactly at boundary is kept"
is_older_than 950 100 1000
assert_status 1 $? "mtime 950 is fresh"
is_older_than 0 100 1000
assert_status 0 $? "mtime 0 is very old"
set -e

# --- list_files_with_mtime --------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/data"
: > "$TMP/data/old.txt"
: > "$TMP/data/new.txt"
: > "$TMP/data/also_old.txt"
mkdir -p "$TMP/data/subdir"

# Set mtimes deterministically. GNU touch and BSD touch both accept -t.
touch -t 202001010000.00 "$TMP/data/old.txt"
touch -t 202001010000.00 "$TMP/data/also_old.txt"
touch -t 202401010000.00 "$TMP/data/new.txt"

listing=$(list_files_with_mtime "$TMP/data")
# Expect 3 lines, sorted by path, subdir excluded.
line_count=$(printf '%s\n' "$listing" | grep -c . || true)
assert_eq "3" "$line_count" "listing has 3 regular files"

# Sorted by path: also_old.txt, new.txt, old.txt
first_path=$(printf '%s\n' "$listing" | head -n1 | cut -d' ' -f2-)
assert_eq "$TMP/data/also_old.txt" "$first_path" "listing sorted by path"

# Subdirectory must not appear.
if printf '%s\n' "$listing" | grep -q "subdir"; then
    assert_eq "absent" "present" "subdir excluded from listing"
else
    assert_eq "absent" "absent" "subdir excluded from listing"
fi

set +e
list_files_with_mtime "$TMP/does-not-exist" >/dev/null 2>&1
assert_status 2 $? "missing directory rejected"
set -e

# --- rotate_delete ----------------------------------------------------------

# Reference "now" = 2024-06-01 00:00:00 UTC = 1717200000.
NOW=1717200000
# 1 year = 31536000 seconds. Old files are from 2020, new from 2024-01-01.
YEAR=31536000

out=$(rotate_delete "$TMP/data" "$YEAR" "$NOW")
# old.txt and also_old.txt are > 4 years old; new.txt is ~5 months old.
assert_eq "2" "$(printf '%s\n' "$out" | grep -c '^DEL ')" "rotate_delete removed 2 files"
assert_eq "1" "$(find "$TMP/data" -maxdepth 1 -type f | wc -l)" "one file remains"
assert_eq "$TMP/data/new.txt" "$(find "$TMP/data" -maxdepth 1 -type f)" "new.txt remains"

# Idempotent: second run deletes nothing.
out2=$(rotate_delete "$TMP/data" "$YEAR" "$NOW")
assert_eq "0" "$(printf '%s\n' "$out2" | grep -c '^DEL ' || true)" "second delete run is a no-op"

# --- rotate_archive ---------------------------------------------------------

mkdir -p "$TMP/arch"
mkdir -p "$TMP/data2"
: > "$TMP/data2/ancient.txt"
: > "$TMP/data2/recent.txt"
touch -t 202001010000.00 "$TMP/data2/ancient.txt"
touch -t 202401010000.00 "$TMP/data2/recent.txt"

out=$(rotate_archive "$TMP/data2" "$YEAR" "$NOW" "$TMP/arch")
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^ARC ')" "rotate_archive moved 1 file"
assert_eq "1" "$(find "$TMP/arch" -maxdepth 1 -type f | wc -l)" "archive holds 1 file"
assert_eq "1" "$(find "$TMP/data2" -maxdepth 1 -type f | wc -l)" "source holds 1 file"
assert_eq "$TMP/data2/recent.txt" "$(find "$TMP/data2" -maxdepth 1 -type f)" "recent.txt stays"

# Collision handling: put another ancient file with the same basename in a
# second source directory and archive into the same target.
mkdir -p "$TMP/data3"
: > "$TMP/data3/ancient.txt"
touch -t 202001010000.00 "$TMP/data3/ancient.txt"
out=$(rotate_archive "$TMP/data3" "$YEAR" "$NOW" "$TMP/arch")
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^ARC ')" "second archive moved 1 file"
assert_eq "2" "$(find "$TMP/arch" -maxdepth 1 -type f | wc -l)" "collision did not overwrite"
assert_eq "1" "$(find "$TMP/arch" -maxdepth 1 -type f -name 'ancient.txt.*' | wc -l)" "collision got a suffix"

# --- rotate dispatcher ------------------------------------------------------

mkdir -p "$TMP/data4"
: > "$TMP/data4/old.txt"
touch -t 202001010000.00 "$TMP/data4/old.txt"
out=$(rotate delete "$TMP/data4" "1d" "$NOW")
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^DEL ')" "rotate delete dispatches"

set +e
rotate bogus "$TMP/data4" "1d" "$NOW" >/dev/null 2>&1
assert_status 2 $? "rotate rejects unknown mode"
set -e

# --- summary ----------------------------------------------------------------

printf '\n1..%d\n' "$((PASS + FAIL))"
printf '# passed: %d\n' "$PASS"
printf '# failed: %d\n' "$FAIL"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
