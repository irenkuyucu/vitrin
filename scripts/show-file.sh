#!/usr/bin/env bash
# Shows a file in the file manager, selected. Usage: show-file.sh <file manager entry id> <path>
# Nautilus has its own option for it; most other file managers answer the standard
# org.freedesktop.FileManager1 D-Bus call; without either, the file's folder opens.
set -u
fm="$1"; path="$2"
dir=$(dirname -- "$path")
if [ "$fm" = org.gnome.Nautilus ] && command -v nautilus >/dev/null; then
  exec uwsm-app -- nautilus --select "$path"
fi
uri=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$path" 2>/dev/null)
if [ -n "$uri" ] && gdbus call --session --dest org.freedesktop.FileManager1 \
     --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems \
     "['$uri']" "" >/dev/null 2>&1; then
  exit 0
fi
exec bash "$(dirname -- "$0")/launch.sh" "$fm" "$dir"
