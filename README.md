# Vitrin

A macOS-style dock for [Omarchy](https://omarchy.org), built as an Omarchy shell plugin.

Vitrin sits at the bottom of the screen, slides up when the pointer touches the bottom
edge, and follows your Omarchy theme. It's written in QML and runs inside the Omarchy
shell, so it adds no extra background process.

## Features

- **Apps**: pinned apps and running apps in one row. Windows of the same app share one
  icon; a dot marks running apps. Click to open, focus, or cycle through an app's windows;
  middle-click for a new window.
- **Files first**: Files (Nautilus) always sits in the first spot, like Finder.
- **Right-click menus**: switch to any of an app's windows, New Window, Keep in Dock /
  Remove from Dock, Move Left / Right, Quit.
- **Drag and drop**: drag icons to reorder them; drag a pinned app out of the dock to remove
  it. Drop files onto an app to open them with it, onto a folder to move them in, or onto
  Trash to trash them.
- **Folders as stacks**: Downloads shows its newest files as a pile, and clicking it shows
  them in a grid. Each folder can open as a stack or a folder, and display as a stack or a
  folder icon (right-click it).
- **Trash**: open it, drop files on it, or empty it (with confirmation).
- **Auto-hide**: hides until the pointer reaches the bottom edge, including over full-screen
  apps. With hiding off, windows make room for it.
- **Launch feedback**: an icon bounces while its app starts.
- **Web apps and terminals**: Omarchy web apps (WhatsApp, YouTube, ...) and terminal windows
  get their proper icons and are grouped correctly, whichever terminal you use.
- **Even spacing**: icon themes pad their artwork unevenly, so Vitrin measures each icon
  and spaces them by what you actually see: every gap between icons looks the same.
- **Resize from the divider**: drag the divider up or down to resize the dock, as on macOS
  (can be turned off in the settings).
- **Settings**: right-click the divider for Turn Hiding On/Off and a settings dialog (size,
  divider resizing, auto-hide, hide delay, launch animation).

## Requirements

- Omarchy 4 (developed on 4.0.6, with Quickshell 0.3.2) running Hyprland.
- Nautilus (Omarchy's file manager), plus `gio`, `file`, and standard GNU tools, which come
  with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/irenkuyucu/vitrin.git --enable
```

Omarchy plugins run as normal code inside the Omarchy shell, so read the code before you
enable a plugin you don't know. To remove Vitrin:

```bash
omarchy plugin remove vitrin
```

## Settings

A new dock starts with Files, your default terminal and your default browser, then
Downloads and Trash. Vitrin keeps its settings in `~/.config/omarchy/vitrin.json`. Most of them can be changed
from the dock itself, but the file is plain JSON and can be edited by hand; the dock picks up
changes when the file is saved.

```jsonc
{
  "settings": {
    "iconSize": 52,         // 32-72
    "autoHide": true,
    "hideDelay": 500,       // milliseconds, 0-2000
    "animateLaunch": true,
    "dividerResize": true   // drag the divider to resize
  },
  // Desktop entry IDs, in dock order (Files always comes first).
  "pins": ["org.gnome.Nautilus", "Alacritty", "chromium"],
  // Folder shortcuts on the right. "icon" is an icon name or an image path. The Trash
  // shows a full trash can while it has items: the theme's "-full" variant of its icon
  // (user-trash-full), or "iconFull" when its icon is an image path.
  // openAs / displayAs: "stack" or "folder" (Trash is always a folder).
  "folders": [
    { "name": "Downloads", "icon": "folder-download", "path": "~/Downloads" },
    { "name": "Trash", "icon": "user-trash", "path": "trash:///" }
  ],
  // Put one app's windows under another app's icon:
  // { "<window app id>": "<desktop entry id>" }. Rarely needed; Vitrin also adds
  // entries here itself when it works out which app an unrecognized window belongs to.
  "aliases": {}
}
```

(The file itself can't contain comments; they're only here to explain the fields.)

If the file can't be read, for example after a typo, Vitrin keeps its current settings,
doesn't save over your file, and leaves a copy next to it as `vitrin.json.broken`.

## Blur (optional)

For a frosted-glass look behind the dock, add this to `~/.config/hypr/looknfeel.lua`.
Hyprland only blurs layers when blur is on, and Omarchy makes every window very slightly
transparent, so this turns blur on but keeps it off for windows:

```lua
hl.config({ decoration = { blur = { enabled = true, size = 8, passes = 2 } } })
o.window(".*", { no_blur = true })
hl.layer_rule({ match = { namespace = "^vitrin$" }, blur = true, ignore_alpha = 0.3 })
```

Blur costs GPU time; on older machines, check that the dock still slides up smoothly.

## If an app shows the wrong icon or name

Some apps' windows don't identify themselves the way their desktop entry says (for
example LocalSend's windows are `org.localsend.localsend_app`, its entry `localsend`).
Vitrin then tries, in order: clues from the window's process (the entry it was launched
from, its program), the parts of its id, and what it learned from launching it from the
dock. An app it still can't place shows under a tile with its initial and a name made from
its id, and the shell log says which id to add to `aliases`, for example:

```json
"aliases": { "org.localsend.localsend_app": "localsend" }
```

The shell log is at `/run/user/$UID/quickshell/by-id/*/log.qslog` (read it with `qs log`).

## Known limitations

- With hiding off, Omarchy's volume/brightness pop-up overlaps the top of the dock.
- In full-screen games, pushing the pointer to the bottom edge brings up the dock (as on
  macOS). Games that capture the pointer aren't affected.

## Development

Vitrin is a regular Omarchy plugin: `manifest.json`, the QML files, and helper scripts in
`scripts/`. After changing the code, restart the shell to load it:

```bash
omarchy restart shell
```

Shell output (warnings and errors) can be read with:

```bash
quickshell log -p "$OMARCHY_PATH/shell"
```

## License

[MIT](LICENSE) © 2026 Iren Kuyucu
