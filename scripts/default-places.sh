#!/usr/bin/env bash
# The system's defaults for the dock's file manager and default folders. Prints four lines
# (empty when unknown):
#   1. the default file manager's desktop entry id (the app that opens folders)
#   2. the Downloads folder (XDG user directory; localized on many systems)
#   3. its display name
#   4. the Trash's display name (as file managers show it)
set -u
bash "$(dirname -- "$0")/default-file-manager.sh"

downloads=$(xdg-user-dir DOWNLOAD 2>/dev/null)
# xdg-user-dir answers with the home folder when no Downloads folder is set.
if [ -z "$downloads" ] || [ "$downloads" = "$HOME" ] || [ ! -d "$downloads" ]; then downloads=""; fi
echo "$downloads"

name() { gio info -a standard::display-name -- "$1" 2>/dev/null | sed -n 's/^ *standard::display-name: //p' | head -n 1; }
[ -n "$downloads" ] && name "$downloads" || echo
name trash:///
