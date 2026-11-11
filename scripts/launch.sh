#!/bin/bash
# Usage: launch.sh DESKTOP-ID[:ACTION] [FILE...]
# Starts the app DESKTOP-ID the way Omarchy does (through uwsm-app), or opens FILEs with
# it like "Open With" in a file manager. With :ACTION, runs that action from the app's
# desktop entry (like "new-private-window") instead.
#
# Apps that run in a terminal (Terminal=true, like btop or Neovim) go through
# omarchy-launch-tui, as Omarchy's own shortcuts start them, with their window tagged
# "org.omarchy.<desktop id>": that tells it apart from a plain terminal window whatever the
# command looks like, and matches the tag Omarchy's shortcuts use (the program's name),
# which is usually the same.
#
# uwsm only accepts desktop entry IDs made of letters, digits, "_", "." and "-". Some
# entries, such as Omarchy web apps like "Google Photos", have spaces in their ID, so those
# (and file opening) go through `gio launch` with the entry's file instead.
id="$1"; shift
action=""
if [[ $id == *:* ]]; then action="${id##*:}"; id="${id%:*}"; fi

file=""
dirs=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
IFS=: read -ra data_dirs <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${data_dirs[@]}"; do [ -n "$d" ] && dirs+=("$d/applications"); done
dirs+=(/usr/local/share/applications /usr/share/applications \
       "$HOME/.local/share/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications)
for d in "${dirs[@]}"; do
  if [ -f "$d/$id.desktop" ]; then file="$d/$id.desktop"; break; fi
done

# A key from the entry's main section (Exec from the action's section with :ACTION).
key() {
  local section="Desktop Entry"
  [ -n "$action" ] && [ "$1" = Exec ] && section="Desktop Action $action"
  awk -v s="[$section]" -v k="$1" '
    /^\[/ { inside = ($0 == s); next }
    inside && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file"
}

if [ -n "$file" ] && [[ $id != *[[:space:]]* ]] && [[ $(key Terminal) == true ]] && command -v omarchy-launch-tui >/dev/null; then
  exec_line=$(key Exec)
  # Plain commands only; anything with quotes or escapes takes the usual way below.
  if [[ -n $exec_line && $exec_line != *[\"\'\\\`\$]* ]]; then
    read -ra words <<<"$exec_line"
    argv=()
    for w in "${words[@]}"; do
      case "$w" in
        %[fFuU]) argv+=("$@") ;;          # the files to open, if any
        %[a-zA-Z]) ;;                     # other field codes: nothing to pass
        *) argv+=("$w") ;;
      esac
    done
    [ ${#argv[@]} -gt 0 ] && exec omarchy-launch-tui --app-id="org.omarchy.$id" "${argv[@]}"
  fi
fi

if [ $# -eq 0 ] && [[ $id =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]]; then
  exec uwsm-app -- "$id.desktop${action:+:$action}"
fi
if [ -z "$file" ]; then
  echo "launch.sh: no desktop entry \"$id\"" >&2
  exit 1
fi
# uwsm-app takes an entry's file path with an action too (gio launch can't run actions).
[ -n "$action" ] && exec uwsm-app -- "$file:$action"
exec uwsm-app -- gio launch "$file" "$@"
