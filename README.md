# file_age_rotator_kit

A small Bash library that deletes or archives files in a single directory whose modification time is older than a given duration.

## Usage

```bash
source ./file_age_rotator_kit.sh

# Delete files in ./logs older than 7 days (using the real clock).
now=$(date +%s)
rotate_delete ./logs "$(parse_duration 7d)" "$now"

# Archive files older than 30 minutes into ./archive instead.
rotate_archive ./logs "$(parse_duration 30m)" "$now" ./archive

# Or use the dispatcher.
rotate archive ./logs 30m "$now" ./archive
```

Every function that inspects the filesystem takes the reference time (`now`) as an explicit integer epoch-second argument. The library never calls `date` itself. That is deliberate: it makes the behaviour testable without sleeping or mocking, and it lets a caller run a rotation against a historical timestamp (for example, replaying a cleanup that should have happened yesterday).

Exported names:

- `parse_duration SPEC` — parse `30s`, `15m`, `2h`, `7d` into seconds.
- `list_files_with_mtime DIR` — print `<mtime> <path>` for regular files directly in `DIR`, sorted by path.
- `is_older_than MTIME MAX_AGE NOW` — exit 0 if the file is strictly older than `MAX_AGE`.
- `rotate_delete DIR MAX_AGE NOW` — delete matching files, print `DEL <path>` per file.
- `rotate_archive DIR MAX_AGE NOW ARCHIVE_DIR` — move matching files, print `ARC <src> -> <dst>` per file.
- `rotate MODE DIR DURATION NOW [ARCHIVE_DIR]` — parse a duration and dispatch to one of the above.

## Why this exists

Most one-liners that rotate files either parse `ls` output (fragile with spaces and newlines in filenames) or shell out to `find -mtime` (which only speaks whole days and uses its own notion of "now"). This library keeps the mtime-to-age comparison in integer arithmetic on epoch seconds, so it can express sub-day windows like `15m` and can be pointed at an arbitrary reference time. The trade-off is that the caller must supply `now`; there is no implicit clock.

## The awkward edge

The boundary is strict. A file whose age is exactly equal to the configured maximum is kept, not rotated. That is the safe default for a destructive tool, but it means `is_older_than MTIME MAX_AGE NOW` returns non-zero when `NOW - MTIME == MAX_AGE`. If you need inclusive behaviour, pass `MAX_AGE - 1`.

Two other things worth knowing:

- Only regular files directly inside the directory are considered. Subdirectories, symlinks, and their contents are left alone. This is a rotator for a flat spool directory, not a recursive cleaner.
- `rotate_archive` never overwrites an existing file in the archive. If a name is taken it appends `.1`, `.2`, and so on. The archive directory is created if it does not exist.

## Tests

```bash
bash test_file_age_rotator_kit.sh
```

The test script sources the library, uses `mktemp -d` for scratch space, sets mtimes with `touch -t`, and passes fixed `now` values, so it does not depend on wall-clock time.
