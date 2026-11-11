#!/usr/bin/env python3
"""Finds icons in the current icon theme, following the freedesktop icon theme spec.

Qt (and so Quickshell) reads the icon theme once, when the shell starts. Omarchy changes the
icon theme with each theme switch, so the dock looks icons up itself, through this.

Runs until stdin closes. Reads one request per line:
  @theme <name>     use this icon theme from now on (the current one is read at start)
  <icon name>       look an icon up
and answers every icon request with one line: "<icon name>\t<file path>", the path empty
when no theme has the icon. Each answered batch ends with a line "@done".
"""
import configparser
import os
import subprocess
import sys

SIZE = 128            # the dock draws icons up to 72 px at 2x; anything >= this is plenty
EXTENSIONS = (".png", ".svg", ".xpm")


def base_dirs():
    home = os.path.expanduser("~")
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local/share")
    data_dirs = (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
    dirs = [os.path.join(home, ".icons"), os.path.join(data_home, "icons")]
    dirs += [os.path.join(d, "icons") for d in data_dirs if d]
    seen, out = set(), []
    for d in dirs:
        if d not in seen and os.path.isdir(d):
            seen.add(d)
            out.append(d)
    return out


class Theme:
    def __init__(self, name, bases):
        self.name = name
        self.roots = [os.path.join(b, name) for b in bases if os.path.isdir(os.path.join(b, name))]
        self.inherits = []
        self.subdirs = []     # (subdir, size, scale, type, min, max, threshold)
        self.files = {}       # (root, subdir) -> (folder's mtime, set of file names), read on first use
        index = None
        for r in self.roots:
            if os.path.isfile(os.path.join(r, "index.theme")):
                index = os.path.join(r, "index.theme")
                break
        if not index:
            return
        cp = configparser.RawConfigParser(strict=False, interpolation=None)
        try:
            cp.read(index, encoding="utf-8")
        except (configparser.Error, UnicodeDecodeError):
            return
        if not cp.has_section("Icon Theme"):
            return
        main = cp["Icon Theme"]
        self.inherits = [t.strip() for t in main.get("Inherits", "").split(",") if t.strip()]
        names = [d.strip() for d in (main.get("Directories", "") + "," + main.get("ScaledDirectories", "")).split(",")]
        for d in names:
            if not d or not cp.has_section(d):
                continue
            s = cp[d]
            try:
                size = int(s.get("Size", "0"))
                scale = int(s.get("Scale", "1"))
                kind = s.get("Type", "Threshold")
                lo = int(s.get("MinSize", str(size)))
                hi = int(s.get("MaxSize", str(size)))
                threshold = int(s.get("Threshold", "2"))
            except ValueError:
                continue
            self.subdirs.append((d, size, scale, kind, lo, hi, threshold))

    def listing(self, root, subdir):
        # Read again when the folder changed (an app installed or removed since), so icons
        # that arrive while the dock runs are found.
        key = (root, subdir)
        path = os.path.join(root, subdir)
        try:
            stamp = os.stat(path).st_mtime_ns
        except OSError:
            stamp = None
        cached = self.files.get(key)
        if cached is None or cached[0] != stamp:
            try:
                names = set(os.listdir(path))
            except OSError:
                names = set()
            cached = self.files[key] = (stamp, names)
        return cached[1]

    @staticmethod
    def distance(entry):
        _, size, scale, kind, lo, hi, threshold = entry
        want = SIZE
        if kind == "Fixed":
            return abs(size * scale - want)
        if kind == "Scalable":
            if want < lo * scale:
                return lo * scale - want
            if want > hi * scale:
                return want - hi * scale
            return 0
        if want < (size - threshold) * scale:
            return (size - threshold) * scale - want
        if want > (size + threshold) * scale:
            return want - (size + threshold) * scale
        return 0

    def find(self, icon):
        """The best-sized file for icon in this theme alone, or None."""
        best, best_distance = None, None
        for entry in self.subdirs:
            d = self.distance(entry)
            # Among equally good folders: the smallest that's still big enough (sharp, and
            # quicker to load than a huge one), else the biggest.
            pixels = entry[1] * entry[2]
            key = (d, pixels < SIZE, abs(pixels - SIZE))
            if best_distance is not None and key >= best_distance:
                continue
            for root in self.roots:
                files = self.listing(root, entry[0])
                for ext in EXTENSIONS:
                    if icon + ext in files:
                        best, best_distance = os.path.join(root, entry[0], icon + ext), key
                        break
                if best_distance == key:
                    break
        return best


class Lookup:
    def __init__(self):
        self.bases = base_dirs()
        self.themes = {}
        self.chain = []

    def theme(self, name):
        if name not in self.themes:
            self.themes[name] = Theme(name, self.bases)
        return self.themes[name]

    def use(self, name):
        # The theme, everything it inherits (depth first, each once), then hicolor.
        order, todo = [], [name or "hicolor"]
        while todo:
            t = todo.pop(0)
            if t in order:
                continue
            order.append(t)
            todo = self.theme(t).inherits + todo
        # Like GTK apps: Adwaita before hicolor, so a theme that isn't installed (or lacks
        # an icon) still gets the usual folder, file and Trash icons.
        for fallback in ("Adwaita", "hicolor"):
            if fallback not in order:
                order.append(fallback)
        self.chain = [self.theme(t) for t in order]

    def find(self, icon):
        for t in self.chain:
            path = t.find(icon)
            if path:
                return path
        # Not in any theme: loose files in the base folders, then /usr/share/pixmaps.
        for d in self.bases + ["/usr/share/pixmaps"]:
            for ext in EXTENSIONS:
                p = os.path.join(d, icon + ext)
                if os.path.isfile(p):
                    return p
        return ""


def current_theme():
    try:
        out = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return out.strip("'\"") or "hicolor"
    except (OSError, subprocess.SubprocessError):
        return "hicolor"


def main():
    lookup = Lookup()
    lookup.use(current_theme())
    answered = False
    for line in sys.stdin:
        name = line.rstrip("\n")
        if name.startswith("@theme "):
            lookup.use(name[len("@theme "):].strip())
            continue
        if name == "@flush":
            if answered:
                print("@done", flush=True)
                answered = False
            continue
        if not name or "/" in name:
            continue
        print(f"{name}\t{lookup.find(name)}")
        answered = True
    sys.stdout.flush()


if __name__ == "__main__":
    main()
