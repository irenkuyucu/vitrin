#!/usr/bin/env bash
# Prints how many items are in the Trash. GIO knows the Trash of the home folder and those on
# other drives; without it, the home folder's Trash is counted.
set -u
count=$(gio info -a trash::item-count trash:/// 2>/dev/null | sed -n 's/^ *trash::item-count: *//p' | head -n 1)
if [[ $count =~ ^[0-9]+$ ]]; then echo "$count"; exit 0; fi
ls -A "${XDG_DATA_HOME:-$HOME/.local/share}/Trash/files" 2>/dev/null | wc -l
