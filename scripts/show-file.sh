#!/usr/bin/env bash
# Shows a file in the file manager, selected. Usage: show-file.sh <file manager entry id> <path>
# Managers that take the file on their command line are started that way (each in its own
# window); the others answer the standard org.freedesktop.FileManager1 D-Bus call; without
# either, the file's folder opens.
set -u
fm="$1"; path="$2"
dir=$(dirname -- "$path")

# The command that opens a folder with a file selected, for the managers known to have one.
select_command() {
  case "${fm,,}" in
    org.gnome.nautilus) cmd=(nautilus --select "$path") ;;
    org.kde.dolphin)    cmd=(dolphin --select "$path") ;;
    folio)              cmd=(folio "$path") ;;
    *flea*)             cmd=(flea --select "$path") ;;
    *) return 1 ;;
  esac
  command -v "${cmd[0]}" >/dev/null
}

if select_command; then
  if command -v uwsm-app >/dev/null; then exec uwsm-app -- "${cmd[@]}"; fi
  exec setsid -f "${cmd[@]}"
fi

uri=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$path" 2>/dev/null)
if [ -n "$uri" ] && gdbus call --session --dest org.freedesktop.FileManager1 \
     --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems \
     "['$uri']" "" >/dev/null 2>&1; then
  exit 0
fi
exec bash "$(dirname -- "$0")/launch.sh" "$fm" "$dir"
