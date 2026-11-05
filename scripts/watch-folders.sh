#!/usr/bin/env bash
# Watches folders for files arriving, leaving or being renamed, and prints the folder's path
# (as given) once per change. Usage: watch-folders.sh DIR...
# Folders that don't exist are skipped (the dock lists them as missing). inotifywait comes
# with inotify-tools, part of Omarchy's base install.
set -u
dirs=()
for d in "$@"; do [ -d "$d" ] && dirs+=("$d"); done
[ ${#dirs[@]} -gt 0 ] || exit 0
# Not close_write: the dock doesn't show file contents, and a download being written would
# fire it constantly. A finished download is renamed into place (moved_to) or created.
exec inotifywait -m -q -e create,delete,moved_to,moved_from,delete_self,move_self \
  --format '%w' -- "${dirs[@]}"
