#!/bin/bash
# Prints the desktop entry id of the default terminal (e.g. "foot"), using the same
# preference lists xdg-terminal-exec reads: the user's choice (`omarchy install terminal`
# writes ~/.config/xdg-terminals.list), then system lists, then Omarchy's default.
config="${XDG_CONFIG_HOME:-$HOME/.config}"
for list in "$config/hyprland-xdg-terminals.list" "$config/xdg-terminals.list" \
            /etc/xdg/hyprland-xdg-terminals.list /etc/xdg/xdg-terminals.list \
            /usr/share/omarchy/default/xdg-terminal-exec/hyprland-xdg-terminals.list; do
  [ -f "$list" ] || continue
  id=$(grep -v '^[[:space:]]*#' "$list" | grep -m1 -o '^[^[:space:]]*\.desktop' | sed 's/\.desktop$//')
  [ -n "$id" ] && { echo "$id"; exit 0; }
done
