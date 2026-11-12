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

name=""
[ -n "$file" ] && name=$(key Name)
[ -n "$name" ] || name=$id

# Tells the user, with a desktop notification, that the app didn't start. (Through uwsm-app,
# which does that itself, it isn't needed: this is for an app that doesn't exist, and for the
# way without uwsm.)
notify_failure() {
  local reason=${1:-The program did not start.} title="Couldn't open $name"
  if command -v omarchy-notification-send >/dev/null; then
    omarchy-notification-send --app-name Vitrin -u normal "$title" "$reason"
  elif command -v notify-send >/dev/null; then
    notify-send -a Vitrin -u normal "$title" "$reason"
  fi
}

# Runs a command; if it fails, says why (its first line of output) in a notification. Its output
# goes to a file rather than a pipe: an app started from here keeps its output open for as long
# as it runs, which would hold up the end of a pipe.
try() {
  local out status
  out=$(mktemp "${TMPDIR:-/tmp}/vitrin-launch.XXXXXX") || out=/dev/null
  "$@" >"$out" 2>&1 </dev/null
  status=$?
  [ $status -eq 0 ] || notify_failure "$(head -n 1 "$out")"
  rm -f "$out"
  return $status
}

# The program of an entry's Exec line (an action's, with :ACTION) and the files to open, as words.
exec_words() {
  local exec_line w
  exec_line=$(key Exec)
  words=()
  # Plain commands only; anything with quotes or escapes can't be split safely here.
  [[ -n $exec_line && $exec_line != *[\"\'\\\`\$]* ]] || return 1
  read -ra parts <<<"$exec_line"
  for w in "${parts[@]}"; do
    case "$w" in
      %[fFuU]) words+=("$@") ;;          # the files to open, if any
      %[a-zA-Z]) ;;                      # other field codes: nothing to pass
      *) words+=("$w") ;;
    esac
  done
  [ ${#words[@]} -gt 0 ]
}

if [ -n "$file" ] && [[ $id != *[[:space:]]* ]] && [[ $(key Terminal) == true ]] && command -v omarchy-launch-tui >/dev/null \
   && exec_words "$@"; then
  exec omarchy-launch-tui --app-id="org.omarchy.$id" "${words[@]}"
fi

if [ -z "$file" ] && { [ $# -gt 0 ] || ! [[ $id =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || ! command -v uwsm-app >/dev/null; }; then
  echo "launch.sh: no desktop entry \"$id\"" >&2
  notify_failure "There is no app by that name installed."
  exit 1
fi

# (uwsm-app tells the user itself when something won't start, so it isn't announced a second time.)
if command -v uwsm-app >/dev/null; then
  if [ $# -eq 0 ] && [[ $id =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]]; then
    exec uwsm-app -- "$id.desktop${action:+:$action}"
  fi
  # uwsm-app takes an entry's file path with an action too (gio launch can't run actions).
  [ -n "$action" ] && exec uwsm-app -- "$file:$action"
  exec uwsm-app -- gio launch "$file" "$@"
fi
if [ -n "$action" ]; then
  # Without uwsm: an action's command runs on its own (detached from here).
  if exec_words "$@"; then try setsid -f "${words[@]}"
  else notify_failure "Its command can't be run without uwsm."; false; fi
else
  try gio launch "$file" "$@"
fi
exit $?
