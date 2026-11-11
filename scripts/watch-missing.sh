#!/usr/bin/env bash
# Watches for folders that don't exist yet (or any more) to appear, and prints the folder's
# path (as given) once per arrival. Usage: watch-missing.sh DIR...
# Folders that exist are skipped (watch-folders.sh covers those). What's watched is each
# missing folder's nearest existing parent, and only the next missing name below it counts,
# so a busy parent like the home folder stays quiet (inotifywait can't filter folder names
# itself). When a name appears, the dock starts both watchers again: a folder that's there
# now gets watched itself, and one that's still missing deeper down gets a closer parent.
set -u
parents=()
targets=()     # the next missing path below each parent
given=()       # the folder as it was given, for each
for d in "$@"; do
  [ -d "$d" ] && continue
  child=${d%/}
  parent=$(dirname -- "$child")
  while [ ! -d "$parent" ] && [ "$parent" != / ] && [ "$parent" != . ]; do
    child=$parent
    parent=$(dirname -- "$child")
  done
  [ -d "$parent" ] || continue
  parents+=("$parent")
  targets+=("$child")
  given+=("$d")
done
[ ${#parents[@]} -gt 0 ] || exit 0

coproc INW { exec inotifywait -m -q -e create,moved_to --format '%w%f' -- "${parents[@]}"; }
trap 'kill "$INW_PID" 2>/dev/null; exit 0' TERM INT
trap 'kill "$INW_PID" 2>/dev/null' EXIT
while IFS= read -r path <&"${INW[0]}"; do
  path=${path//\/\//\/}
  for i in "${!targets[@]}"; do
    if [ "$path" = "${targets[$i]}" ]; then echo "${given[$i]}"; break; fi
  done
done
exit 1         # inotifywait ended: the dock starts it again
