#!/usr/bin/env bash
# Switches Hyprland's pointer warping off for a moment, so focusing a window from the dock
# doesn't move the pointer to it (Hyprland has no per-focus option for that).
#
# Usage: no-warp.sh off       saves the current values, then turns warping off
#        no-warp.sh restore   puts the saved values back (also safe to run when nothing
#                             was saved: the dock runs it at startup, in case the shell
#                             stopped while warping was off)
#
# The saved values live in a small file until restored, so warping can't stay off by
# accident. Only the user's own values are ever restored; if warping is already off, "off"
# changes nothing.
set -u
state="${XDG_CACHE_HOME:-$HOME/.cache}/vitrin/warps-off"
options=(cursor:no_warps cursor:warp_on_change_workspace)

value() {   # "bool: false" / "int: 1" -> false / 1
  hyprctl getoption "$1" 2>/dev/null | head -n 1 | sed 's/^[a-z]*: *//'
}

set_option() {   # name value, with a Lua config (eval) or a classic one (keyword)
  local section=${1%%:*} key=${1#*:}
  if ! hyprctl eval "hl.config({ $section = { $key = $2 } })" 2>/dev/null | grep -q '^ok'; then
    hyprctl keyword "$1" "$2" >/dev/null 2>&1
  fi
}

case "${1:-}" in
  off)
    [ -f "$state" ] && exit 0                       # already off (and saved)
    [ "$(value cursor:no_warps)" = true ] && exit 0  # the user has warping off anyway
    # Read both first; if Hyprland can't be asked (or answers oddly), change nothing.
    saved=""
    for o in "${options[@]}"; do
      v=$(value "$o")
      [[ $v =~ ^(true|false|-?[0-9]+)$ ]] || exit 1
      saved+="$o $v"$'\n'
    done
    mkdir -p "$(dirname "$state")"
    printf '%s' "$saved" > "$state.tmp" && mv -f "$state.tmp" "$state"
    set_option cursor:no_warps true
    set_option cursor:warp_on_change_workspace 0
    ;;
  restore)
    [ -f "$state" ] || exit 0
    while read -r o v; do [[ $v =~ ^(true|false|-?[0-9]+)$ ]] && set_option "$o" "$v"; done < "$state"
    rm -f "$state"
    ;;
esac
