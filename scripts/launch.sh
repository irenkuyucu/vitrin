#!/bin/bash
# Usage: launch.sh DESKTOP-ID[:ACTION] [FILE...]
# Starts the app DESKTOP-ID the way Omarchy does (through uwsm-app), or opens FILEs with
# it like "Open With" in a file manager. With :ACTION, runs that action from the app's
# desktop entry (like "new-private-window") instead.
#
# uwsm only accepts desktop entry IDs made of letters, digits, "_", "." and "-". Some
# entries, such as Omarchy web apps like "Google Photos", have spaces in their ID, so those
# (and file opening) go through `gio launch` with the entry's file instead.
id="$1"; shift
action=""
if [[ $id == *:* ]]; then action="${id##*:}"; id="${id%:*}"; fi
if [ $# -eq 0 ] && [[ $id =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]]; then
  exec uwsm-app -- "$id.desktop${action:+:$action}"
fi
for d in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" /usr/local/share/applications /usr/share/applications \
         "$HOME/.local/share/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications; do
  if [ -f "$d/$id.desktop" ]; then
    # uwsm-app takes an entry's file path with an action too (gio launch can't run actions).
    [ -n "$action" ] && exec uwsm-app -- "$d/$id.desktop:$action"
    exec uwsm-app -- gio launch "$d/$id.desktop" "$@"
  fi
done
echo "launch.sh: no desktop entry \"$id\"" >&2
exit 1
