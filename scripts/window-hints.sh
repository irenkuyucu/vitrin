#!/usr/bin/env bash
# Clues about which app a window belongs to, for windows whose app id doesn't match any
# desktop entry. Usage: window-hints.sh <app id>, or window-hints.sh --address <address>
# for one window (Hyprland's address, with or without "0x").
#
# Prints three lines for the first window with that app id, or that window (empty when unknown):
#   1. the desktop entry it was launched from: $GIO_LAUNCHED_DESKTOP_FILE (gio, gtk-launch)
#      or the systemd unit uwsm-app puts apps in ("app-Hyprland-<entry id>@<random>.service"
#      or "app-Hyprland-<entry id>-<random>.scope"; a unit named after a launcher rather
#      than an entry, like gtk-launch, matches no entry and is ignored by the dock)
#   2. the path of its executable
#   3. its command line's first word (the script or binary that was run)
set -u
if [ "$1" = --address ]; then
  address="0x${2#0x}"
  pid=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$address" \
    'first(.[] | select(.address == $a) | .pid) // empty')
else
  app_id="$1"
  pid=$(hyprctl clients -j 2>/dev/null | jq -r --arg id "$app_id" \
    'first(.[] | select(.class == $id or .initialClass == $id) | .pid) // empty')
fi
if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
  printf '\n\n\n'
  exit 0
fi

launched=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
  | sed -n 's/^GIO_LAUNCHED_DESKTOP_FILE=//p' | head -n 1)
launched=${launched##*/}
launched=${launched%.desktop}
if [ -z "$launched" ]; then
  # systemd escapes "-" as "\x2d" in unit names.
  unit=$(sed -n 's|.*/||p' "/proc/$pid/cgroup" 2>/dev/null | head -n 1 | sed 's/\\x2d/-/g')
  if [[ $unit =~ ^app-[^-]+-(.+)@[^@]*\.service$ ]] || [[ $unit =~ ^app-[^-]+-(.+)-[0-9a-f]+\.scope$ ]]; then
    launched=${BASH_REMATCH[1]}
    launched=${launched%.desktop}
  fi
fi

exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
cmd=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n 1)

printf '%s\n%s\n%s\n' "$launched" "$exe" "$cmd"
