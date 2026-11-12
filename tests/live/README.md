# Live checks

Some behavior can only be checked on a running desktop: drags, menus, hover timing, a reloaded
shell. After a change that touches it, check it on a real session and keep a screenshot as the
evidence. The automated suite is described in `../README.md`.

## Tools

- `vptr.py` moves, clicks and drags a virtual pointer with real button presses. It speaks the
  Wayland `zwlr_virtual_pointer` protocol directly, which Hyprland offers to any client, so
  nothing needs installing. The first two arguments are the output's size in pixels:

      python3 tests/live/vptr.py 1440 900 click 923 857
      python3 tests/live/vptr.py 1440 900 drag 775 705 783 857 2800 780 575

  `drag X1 Y1 X2 Y2 [hold_ms [X3 Y3]]` presses at the first point, moves to the second, holds
  there (spring-loading needs a second), then slides to the optional third point before letting
  go, so nothing is dropped on the target. Coordinates depend on your screen and dock layout.
- `grim -g "X,Y WxH" shot.png` takes a screenshot of a region (it can't be combined with `-o`).
- `hyprctl clients -j`, `hyprctl layers` and `hyprctl monitors -j` show window and layer state.
- `wtype -k KEY` sends a key to whichever window has focus. Be careful with `Escape` unless
  the dock's keyboard mode is on: it goes to your terminal. `omarchy-shell vitrin focus` leaves
  the mode.

## Before testing

Back up `~/.config/omarchy/vitrin.json`. Any app that runs under the dock is added to its
recent-apps section, which keeps three and drops the oldest, so a test window pushes out your
own apps and that can't be undone afterwards. When you're done, close the test windows (by
address, `hyprctl dispatch "hl.dsp.window.close({ window = \"address:0x...\" })"`), remove
the test entries from the config, and look at the dock.

## After a change

1. `omarchy restart shell`, then `hyprctl layers | grep vitrin` shows the dock's layer.
2. The shell log has no `load failed`, `TypeError` or `ReferenceError`.
3. Exercise what changed, with scratch windows and folders.

## Checks per feature

- **Spring-loading:** minimize a window (move it to `special:minimized`), open a stack, drag a
  tile onto the app's icon and hold: the window comes back to the current workspace.
- **App grid highlight:** open the grid (nothing is highlighted), move the pointer over an app
  (it highlights) and then onto empty space (it clears); the arrow keys and typing still select.
  Close it by clicking the empty margin, never a spot that could be an app.
- **App grid icons:** right after a shell restart, the first opening shows real icons, not letter tiles, and none swaps or blinks once the grid is open (log each icon's `source` and `status` in AppGrid.qml for a moment to see it).
- **App grid panel:** it opens centered on a dimmed screen, whole columns wide; clicking the dim closes it. Look at it on a light theme too (`omarchy theme set "Catppuccin Latte"`, then set your own back).
- **Touchpad scrolling (app grid, stacks):** `tests/live/vptr.py W H scroll -8 10` glides on after the last event (compare two screenshots a moment apart), `notch 3` still scrolls, and hovering an app afterwards highlights it. With a row half in view at the edge, hovering an app in it highlights it without moving the row. Feel is checked by hand on a real touchpad.
- **Keyboard mode and the mouse:** `omarchy-shell vitrin focus` turns the mode on; it is on while
  `hyprctl getoption input:follow_mouse` reads 2 (1 when off, with the default config).
  Check each of these ends with the option back at its normal value and the screen as described:
  - Click a running app's icon (with the app not focused, then focused): the mode ends, and the
    app has the keyboard (`hyprctl activewindow`).
  - Click a folder's icon: the mode ends and its stack opens, with no highlight left on the dock.
  - Open the app grid, then `omarchy-shell vitrin focus`: nothing changes, and no highlight
    flashes (take several screenshots in a row right after, and compare the Files icon).
  - Highlight a recent app's icon, then remove that app from `recent` in the config: the highlight
    moves to the icon now at its place, and the mode goes on.
  - Drag an icon sideways: the mode goes on. Type a letter: the highlight jumps to the matching
    icon. `Ctrl + H` turns hiding on and ends the mode.
  Not yet checked: a second monitor (Super+D must pick the focused screen's dock) and a
  fullscreen app (the dock slides up over it).
- **Another file manager** (Omarchy 4.6 replaces Nautilus with Files, `folio`; checked against its
  upstream source before it shipped, so check again with the package): make it the default
  (`xdg-mime default folio.desktop inode/directory`, and put `~/.config/mimeapps.list` back after),
  then restart the shell. The first slot shows its icon, and the first pin in the config is
  rewritten to its id. Then check a click on that slot, a middle-click on Downloads, a stack's
  "Open in Files" and a file's "Show in Files" (it opens the folder with the file selected). Drag a
  file from a stack into one of its windows, and from one of its windows onto Downloads and the
  Trash. Put the old default back: its icon returns to the first slot. Windows of several
  processes group under one icon; its preview window (`folio preview FILE`) is listed there too.
  To try one that isn't installed, build it in a scratch folder and give it a desktop entry in
  `~/.local/share/applications` whose `Exec` is the program's full path (Omarchy's launcher
  doesn't see `~/.local/bin`). An icon added to a folder the running dock doesn't watch only shows
  after a shell restart.
- **Missing folder:** add a shortcut to a path that doesn't exist (a question-mark badge shows),
  create it (the badge goes), delete it (the badge returns); try a path several levels down.
- **Windows opened by the system:** open `omarchy-launch-tui --app-id=org.omarchy.agent sleep 600`
  (the window a crash notification opens). It joins your terminal's icon, and no extra icon
  appears, not even briefly.
- **omasnap:** `omasnap --pin some.png` leaves no icon (nor a running dot); `omasnap --file some.png
  --editor window` shows one. With `"alwaysShow": ["omasnap"]` the pin shows too.
- **Icons of apps installed meanwhile:** install or remove a desktop entry and its icon, wait a
  few seconds, then look at the dock and the app grid.
- **Helper processes:** kill `icon-lookup.py` and `gsettings monitor` by their exact PIDs; both
  come back within a couple of seconds.
- **Icon lookup only while needed:** a minute after the shell starts, `icon-lookup.py` is gone
  from `ps`. Add a desktop entry (it starts again, then stops again after a minute), and
  switch the icon theme with `gsettings set org.gnome.desktop.interface icon-theme <name>` while
  it is stopped: the dock's icons change at once, and change back when you restore the theme.
- **Folder watcher keeps dying:** kill the dock's `inotifywait` (`ps -eo pid,args`, the one with
  `create,delete,moved_to`) by its PID several times in a row, right after it comes back: it
  restarts after 2 s, then 4, then 8 (up to a minute), and a watcher that ran for 10 s or more
  starts the count over.
- **Config file unreadable:** `chmod 000 ~/.config/omarchy/vitrin.json`, then `touch` it. The log
  says it exists but can't be read, nothing is written; after `chmod 644` and another `touch`
  the file is read again and is unchanged.

## Pitfalls

- `pkill -f` and `pgrep -f` match the whole command line, including your own shell's if it
  contains the pattern. Use exact PIDs or an anchored pattern.
