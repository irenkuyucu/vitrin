#!/usr/bin/env bash
# Makes the previews Files would make, for files that don't have an up-to-date one yet, in
# the shared thumbnail cache (so Files finds them ready-made too). Follows the freedesktop
# thumbnail rules: the previewer for a file's type comes from the installed .thumbnailer
# files; a preview is stamped with its file's URI and modification time, and is out of date
# when that time no longer matches; a failure is recorded under fail/<app>/ so it isn't
# retried until the file changes.
#
# Usage: thumbnail.sh <mime type> <path> <uri> <md5 of uri> [<mime> <path> <uri> <md5> ...]
# Prints "<md5> <result> [<preview path>]" per file: new (made just now) or ok (already up
# to date), with the preview's path; failed; or none (no previewer for its type). Works on
# two files at a time.
set -u

cache="${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails"
mkdir -p "$cache/large" "$cache/fail/vitrin" 2>/dev/null
chmod 700 "$cache" "$cache/large" "$cache/fail" "$cache/fail/vitrin" 2>/dev/null

# Where .thumbnailer files live: the user's data dir first, then the system's.
thumbnailer_dirs=("${XDG_DATA_HOME:-$HOME/.local/share}/thumbnailers")
IFS=: read -ra data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${data_dirs[@]}"; do thumbnailer_dirs+=("$d/thumbnailers"); done

# The Exec line of the first thumbnailer that lists this type.
exec_for() {
  local mime=$1 dir file
  for dir in "${thumbnailer_dirs[@]}"; do
    for file in "$dir"/*.thumbnailer; do
      [ -f "$file" ] || continue
      if awk -v mime="$mime" -F= '$1 == "MimeType" {
            n = split($2, types, ";"); for (k = 1; k <= n; k++) if (types[k] == mime) found = 1 }
          END { exit !found }' "$file"; then
        sed -n 's/^Exec=//p' "$file" | head -n 1
        return
      fi
    done
  done
}

# Splits a desktop-file Exec line into the words array, honouring double quotes (with \ for
# a literal quote, backslash, $ or backtick inside them).
split_exec() {
  local s=$1 w="" quoted=0 started=0 c i
  words=()
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if ((quoted)); then
      case $c in
        '"') quoted=0 ;;
        '\') i=$((i + 1)); w+=${s:i:1} ;;
        *) w+=$c ;;
      esac
    else
      case $c in
        '"') quoted=1; started=1 ;;
        ' '|$'\t') if ((started)); then words+=("$w"); w=""; started=0; fi ;;
        *) w+=$c; started=1 ;;
      esac
    fi
  done
  ((started)) && words+=("$w")
  return 0
}

# The Thumb::MTime a preview was stamped with (empty if none).
stamped_mtime() {
  grep -a -o -m 1 'Thumb::MTime.[0-9]*' "$1" 2>/dev/null | tr -dc '0-9'
}

shopt -u patsub_replacement 2>/dev/null   # (bash 5.2+: a "&" in a path would mean the matched text)

# Fills a word's codes in one pass (%i file, %u its URI, %o the output file, %s the size, %% a
# percent sign) into $filled. One pass, so a code-looking part of a file name ("50%sale.png")
# is never taken for a code itself.
fill_codes() {
  local s=$1 path=$2 uri=$3 out=$4 i c
  filled=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if [ "$c" = % ]; then
      case ${s:i+1:1} in
        i) filled+=$path; i=$((i + 1)); continue ;;
        u) filled+=$uri; i=$((i + 1)); continue ;;
        o) filled+=$out; i=$((i + 1)); continue ;;
        s) filled+=256; i=$((i + 1)); continue ;;
        %) filled+=%; i=$((i + 1)); continue ;;
      esac
    fi
    filled+=$c
  done
}

one() {
  local mime=$1 path=$2 uri=$3 hash=$4 mtime f exec tmp args=() word
  mtime=$(stat -c %Y -- "$path" 2>/dev/null) || return
  for f in "$cache/large/$hash.png" "$cache/normal/$hash.png"; do
    if [ -f "$f" ] && [ "$(stamped_mtime "$f")" = "$mtime" ]; then echo "$hash ok $f"; return; fi
  done
  f="$cache/fail/vitrin/$hash.png"
  if [ -f "$f" ] && [ "$(stamped_mtime "$f")" = "$mtime" ]; then echo "$hash failed"; return; fi

  # Making a preview needs ImageMagick (to stamp it); without it, no preview can be made, and
  # nothing is recorded as failed either: that would only be wrong once it is installed.
  command -v magick >/dev/null || { echo "$hash none"; return; }
  exec=$(exec_for "$mime")
  if [ -z "$exec" ]; then echo "$hash none"; return; fi
  tmp=$(mktemp --suffix=.png "$cache/large/.vitrin-XXXXXX") || return
  split_exec "$exec"
  for word in "${words[@]}"; do
    fill_codes "$word" "$path" "$uri" "$tmp"
    args+=("$filled")
  done
  if timeout 5 nice -n 10 "${args[@]}" >/dev/null 2>&1 && [ -s "$tmp" ] \
     && magick "$tmp" -set Thumb::URI "$uri" -set Thumb::MTime "$mtime" "PNG:$tmp.stamped" 2>/dev/null; then
    mv -f "$tmp.stamped" "$cache/large/$hash.png"
    echo "$hash new $cache/large/$hash.png"
  else
    magick -size 1x1 xc:none -set Thumb::URI "$uri" -set Thumb::MTime "$mtime" "PNG:$cache/fail/vitrin/$hash.png" 2>/dev/null
    echo "$hash failed"
  fi
  rm -f "$tmp" "$tmp.stamped"
}

running=0
while [ $# -ge 4 ]; do
  one "$1" "$2" "$3" "$4" &
  shift 4
  running=$((running + 1))
  if [ $running -ge 2 ]; then wait -n; running=$((running - 1)); fi
done
wait
