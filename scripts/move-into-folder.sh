#!/bin/bash
# Usage: move-into-folder.sh DEST FILE...
# Like dropping files onto a folder in the macOS dock: files on the same drive are moved
# into DEST, files from another drive are copied. Nothing is overwritten: a name that's
# taken gets " 2", " 3", ... before its extension. Files already in DEST are left alone.
dest="$1"; shift
[ -d "$dest" ] || exit 0
dev=$(stat -c %d -- "$dest")
real_dest=$(cd -- "$dest" && pwd -P)
for src in "$@"; do
  [ -e "$src" ] || continue
  [ "$(cd -- "$(dirname -- "$src")" && pwd -P)" = "$real_dest" ] && continue
  # A folder can't go into itself or one of its own subfolders.
  if [ -d "$src" ]; then
    real_src=$(cd -- "$src" && pwd -P)
    case "$real_dest/" in "$real_src/"*) continue ;; esac
  fi
  name=$(basename -- "$src"); base="$name"; ext=""
  if [ ! -d "$src" ] && [ "${name#?*.}" != "$name" ]; then base="${name%.*}"; ext=".${name##*.}"; fi
  target="$dest/$name"; n=2
  while [ -e "$target" ]; do target="$dest/$base $n$ext"; n=$((n+1)); done
  if [ "$(stat -c %d -- "$src")" = "$dev" ]; then mv -n -- "$src" "$target"
  else cp -a -n -- "$src" "$target"; fi
done
