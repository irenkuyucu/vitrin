#!/usr/bin/env bash
# Keeps the pointer working normally while the dock is driven with the keyboard:
#   cursor:hide_on_key_press  true hides the pointer on every key press, and over the dock it
#                             flickers back with each change of highlight: turned off
#   input:follow_mouse        1 focuses whatever window the pointer touches, which would end
#                             keyboard mode on any stray pointer movement: set to 2, where
#                             hovering only moves the pointer (scrolling, hover effects work)
#                             and a click still moves the keyboard to the clicked window
#
# Usage: keep-cursor.sh off       saves the current values, then changes them
#        keep-cursor.sh restore   puts the saved values back (also safe when nothing was
#                                 saved: the dock runs it at startup, in case the shell
#                                 stopped in between)
#
# Like no-warp.sh: the user's own values live in a small file until restored, and an option
# is only touched when it's set to the value that causes trouble.
set -u
state="${XDG_CACHE_HOME:-$HOME/.cache}/vitrin/cursor-hide"

value() {   # "bool: true" / "int: 1" -> true / 1
  hyprctl getoption "$1" 2>/dev/null | head -n 1 | sed 's/^[a-z]*: *//'
}

set_option() {   # name value, with a Lua config (eval) or a classic one (keyword); fails if neither took
  local section=${1%%:*} key=${1#*:}
  hyprctl eval "hl.config({ $section = { $key = $2 } })" 2>/dev/null | grep -q '^ok' && return 0
  hyprctl keyword "$1" "$2" 2>/dev/null | grep -q '^ok'
}

case "${1:-}" in
  off)
    [ -f "$state" ] && exit 0                 # already changed (and saved)
    saved=""
    [ "$(value cursor:hide_on_key_press)" = true ] && saved+="cursor:hide_on_key_press true"$'\n'
    [ "$(value input:follow_mouse)" = 1 ] && saved+="input:follow_mouse 1"$'\n'
    [ -n "$saved" ] || exit 0
    mkdir -p "$(dirname "$state")"
    printf '%s' "$saved" > "$state.tmp" && mv -f "$state.tmp" "$state"
    while read -r o v; do
      case "$o" in
        cursor:hide_on_key_press) set_option "$o" false ;;
        input:follow_mouse) set_option "$o" 2 ;;
      esac
    done < "$state"
    ;;
  restore)
    [ -f "$state" ] || exit 0
    failed=0
    while read -r o v; do
      case "$o:$v" in
        cursor:hide_on_key_press:true|input:follow_mouse:1) set_option "$o" "$v" || failed=1 ;;
      esac
    done < "$state"
    # Kept if any value didn't go back, so the next start can try again.
    [ "$failed" = 0 ] && rm -f "$state"
    ;;
esac
