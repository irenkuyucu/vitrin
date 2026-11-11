# Live checks

What can't run unattended: drags, menus, hover timing and a reloaded shell. These are checked
on the real desktop after a change, with a screenshot (`grim`) as the evidence.

## Tools

- `vptr.py`: a pointer made of nothing but the Wayland wire protocol (Hyprland offers
  `zwlr_virtual_pointer` to any client). Move, click and drag with real button presses:

      python3 -I tests/live/vptr.py 1440 900 click 923 857
      python3 -I tests/live/vptr.py 1440 900 drag 775 705 783 857 2800 780 575

  `drag X1 Y1 X2 Y2 [hold_ms [X3 Y3]]` presses at the first point, moves to the second, holds
  (the dock's spring-loading needs a second), then slides to the optional third point before
  letting go, so nothing is dropped on the target. The first two numbers are the output size.
- `grim -g "X,Y WxH" shot.png` for a screenshot of a region (not with `-o`).
- `hyprctl clients -j`, `hyprctl layers`, `hyprctl monitors -j` to check state.
- `wtype -k KEY` for keys. Never `Escape` unless the dock's keyboard mode is on: it goes
  to the focused terminal. Leave the mode with `omarchy-shell vitrin focus`.

## After a change

1. `omarchy restart shell`, then `hyprctl layers | grep vitrin` shows the dock's layer.
2. The shell log has no `load failed`, `TypeError` or `ReferenceError`.
3. Exercise what changed, in the real dock. Use scratch windows and folders, remove them
   after, and put the config back (the file is `~/.config/omarchy/vitrin.json`; back it up
   first when a test edits it).

## Per feature

- Spring-loading: minimize a window (move it to `special:minimized`), open a stack, drag a
  tile onto the app's icon and hold: the window comes back to the current workspace.
- Missing folder: add a shortcut to a path that doesn't exist (badge shown), create it (badge
  gone), delete it (badge back); try a path several levels down.
- Icons of apps installed meanwhile: install or remove a desktop entry and its icon, wait a
  few seconds, look at the dock and the app grid.
- Helper processes: kill `icon-lookup.py` and `gsettings monitor` by their exact PIDs; both
  come back within a couple of seconds.

## Careful with

- `pkill -f` and `pgrep -f` with a pattern that also appears in your own command line match
  your own shell. Use exact PIDs or an anchored pattern (`^/usr/bin/gsettings monitor`).
