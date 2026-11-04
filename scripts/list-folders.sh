#!/bin/bash
# Usage: list-folders.sh MAX DIR...  For each folder, its newest MAX entries (by date added: creation
# time where recorded, else modification time), newest first, as NUL-terminated records
# "<folder index>\t<mime type>\t<path>", after a "<folder index>\t#total\t<count>" record
# with how many entries the folder has in all. One `file` call per folder identifies all types.
max="$1"; shift; i=0
for dir in "$@"; do
  if [ -d "$dir" ]; then
    sorted=()
    mapfile -d '' sorted < <(
      find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name '*.part' ! -name '*.crdownload' ! -name '*.download' \
        -printf '%B@ %T@ %p\0' 2>/dev/null \
      | while IFS= read -r -d '' rec; do
          born=${rec%% *}; rest=${rec#* }; modified=${rest%% *}; path=${rest#* }
          case $born in ''|0|0.*|-*) born=$modified ;; esac
          printf '%s\t%s\0' "$born" "$path"
        done \
      | sort -z -t $'\t' -k1,1 -rn)
    # How many there are in all (for "Newest 1,000 of 4,577"), as a record of its own.
    printf '%s\t#total\t%s\0' "$i" "${#sorted[@]}"
    paths=()
    for rec in "${sorted[@]:0:$max}"; do paths+=("${rec#*$'\t'}"); done
    if [ ${#paths[@]} -gt 0 ]; then
      mapfile -t mimes < <(file -b --mime-type -- "${paths[@]}" 2>/dev/null)
      for k in "${!paths[@]}"; do printf '%s\t%s\t%s\0' "$i" "${mimes[$k]:-application/octet-stream}" "${paths[$k]}"; done
    fi
  fi
  i=$((i+1))
done
