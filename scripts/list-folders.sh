#!/bin/bash
# Usage: list-folders.sh MAX DIR...  For each folder, its newest MAX entries by date added (see
# below), newest first, as NUL-terminated records "<folder index>\t<mime type>\t<icon names,
# comma-separated, best first>\t<path>", after
# a "<folder index>\t#total\t<count>" record with how many entries the folder has in all. One
# `file` call per folder identifies all types.
#
# Date added (Linux doesn't record one, unlike macOS): the first time a file is seen, from
# its times. A new download or copy is created now; a file moved in keeps its old creation
# and modification times, but its "status changed" time is now, clearly later than its last
# modification; an edit leaves "status changed" equal to the modification. So: status
# changed if that's more than a second after the last modification, else creation time
# (modification time where creation isn't recorded). After that the file is remembered by
# its inode and creation time in a small cache per folder, so renaming it, changing its
# permissions or editing it later doesn't move it.
max="$1"; shift; i=0
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/vitrin"
mkdir -p "$cache_dir" 2>/dev/null
for dir in "$@"; do
  if [ -d "$dir" ]; then
    cache="$cache_dir/added-$(printf '%s' "$dir" | md5sum | cut -c1-16).tsv"
    sorted=()
    mapfile -d '' sorted < <(
      # find picks the entries; stat reports their times (GNU find can't read creation
      # times on some systems and prints -1, stat can).
      # (Hidden files and backup files ending in ~ are skipped, as Files hides them;
      # unfinished downloads too.)
      find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name '*~' ! -name '*.part' ! -name '*.crdownload' ! -name '*.download' \
        -print0 2>/dev/null \
      | xargs -0 -r stat --printf '%i %.9W %.9Y %.9Z %n\0' -- 2>/dev/null \
      | awk -v cache="$cache" '
          BEGIN {
            RS = "\n"      # the cache: one "<inode>:<created>\t<added>" line per file
            while ((getline line < cache) > 0) { split(line, f, "\t"); known[f[1]] = f[2] }
            close(cache)
            RS = "\0"      # the listing: NUL-terminated records
          }
          {
            inode = $1; born = $2; modified = $3; changed = $4
            path = substr($0, length($1) + length($2) + length($3) + length($4) + 5)
            created = int(born) > 0 ? born : ""
            key = inode ":" int(created)
            if (key in known) added = known[key]
            else if (changed - modified > 1) added = changed
            else added = created != "" ? created : modified
            seen[key] = added
            printf "%s\t%s\0", added, path
          }
          END {
            tmp = cache ".tmp"
            for (k in seen) printf "%s\t%s\n", k, seen[k] > tmp
            close(tmp)
          }' \
      | sort -z -t $'\t' -k1,1 -rn)
    [ -f "$cache.tmp" ] && mv -f "$cache.tmp" "$cache"
    # How many there are in all (for "Newest 1,000 of 4,577"), as a record of its own.
    printf '%s\t#total\t%s\0' "$i" "${#sorted[@]}"
    paths=()
    for rec in "${sorted[@]:0:$max}"; do paths+=("${rec#*$'\t'}"); done
    if [ ${#paths[@]} -gt 0 ]; then
      # Types and icon names the way Files sees them (GIO: by name and contents, so a .md
      # file is text/markdown, not just text/plain), one "<type>\t<icons>" line per file in
      # order. If gio doesn't answer for every file, `file` (contents only) does instead.
      mapfile -t types < <(gio info -a standard::content-type,standard::icon -- "${paths[@]}" 2>/dev/null \
        | awk '/^uri: / { if (n++) print type "\t" icons; type = ""; icons = "" }
               /^  standard::content-type: / { sub(/^  standard::content-type: /, ""); type = $0 }
               /^  standard::icon: / { sub(/^  standard::icon: /, ""); gsub(/, /, ","); icons = $0 }
               END { if (n) print type "\t" icons }')
      if [ ${#types[@]} -ne ${#paths[@]} ]; then
        mapfile -t types < <(file -b --mime-type -- "${paths[@]}" 2>/dev/null | sed 's/$/\t/')
      fi
      for k in "${!paths[@]}"; do
        type=${types[$k]:-application/octet-stream$'\t'}
        printf '%s\t%s\t%s\t%s\0' "$i" "${type%%$'\t'*}" "${type#*$'\t'}" "${paths[$k]}"
      done
    fi
  fi
  i=$((i+1))
done
