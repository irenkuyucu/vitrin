#!/usr/bin/env bash
# Which of the given paths are folders, with their names and icons (from GIO, as Files
# shows them). Usage: folder-info.sh <path>...
#
# Prints one line per folder (other paths are skipped):
#   <path> <display name> <icon names, comma-separated, best first>
# each followed by a NUL byte, so paths with tabs or newlines come through whole.
set -u
for p in "$@"; do
  [ -d "$p" ] || continue
  info=$(gio info -a standard::display-name,standard::icon -- "$p" 2>/dev/null)
  name=$(sed -n 's/^ *standard::display-name: //p' <<<"$info" | head -n 1)
  icons=$(sed -n 's/^ *standard::icon: //p' <<<"$info" | head -n 1 | tr -d ' ')
  [ -n "$name" ] || name=$(basename -- "$p")
  printf '%s\0%s\0%s\0' "$p" "$name" "${icons:-folder}"
done
