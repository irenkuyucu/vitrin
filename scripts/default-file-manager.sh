#!/usr/bin/env bash
# The desktop entry id of the default file manager (the app that opens folders), without its
# ".desktop"; nothing when there is none.
fm=$(xdg-mime query default inode/directory 2>/dev/null | head -n 1)
echo "${fm%.desktop}"
