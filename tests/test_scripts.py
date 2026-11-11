"""Tests for the helper scripts in scripts/.

Each test runs the real script against temporary folders, with the desktop commands it
calls (hyprctl, gio, xdg-mime, ...) replaced by small stubs in a private PATH, so nothing
touches the live desktop, the real config or the real cache. Tests that need a tool the
machine lacks (magick, gio, inotifywait) are skipped.
"""
import hashlib
import importlib.util
import json
import os
import select
import shutil
import signal
import subprocess
import tempfile
import time
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True      # (nothing gets written into the repo)

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"

spec = importlib.util.spec_from_file_location("icon_lookup", SCRIPTS / "icon-lookup.py")
icon_lookup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icon_lookup)


def needs(tool):
    return unittest.skipUnless(shutil.which(tool), f"{tool} is not installed")


class Fixture(unittest.TestCase):
    """A private HOME, XDG folders and a PATH with stubs in front."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vitrin-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.log = self.base / "argv.json"
        self.env = dict(
            os.environ,
            HOME=str(self.base),
            XDG_CACHE_HOME=str(self.base / "cache"),
            XDG_DATA_HOME=str(self.base / "data"),
            XDG_DATA_DIRS=str(self.base / "system-data"),
            XDG_CONFIG_HOME=str(self.base / "config"),
            PATH=f"{self.bin}:{os.environ['PATH']}",
            TEST_LOG=str(self.log),
        )

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)
        return path

    def recorder(self, name):
        """A command that writes its arguments to the log, as JSON."""
        return self.stub(name, '#!/usr/bin/python3\nimport json, os, sys\n'
                               'open(os.environ["TEST_LOG"], "w").write(json.dumps(sys.argv[1:]))\n')

    def logged(self):
        return json.loads(self.log.read_text())

    def run_script(self, name, *args, timeout=10):
        return subprocess.run(["bash", str(SCRIPTS / name), *map(str, args)], env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

    def start_script(self, name, *args):
        return subprocess.Popen(["bash", str(SCRIPTS / name), *map(str, args)], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def read_line(proc, timeout=3.0):
    """The next line the process prints, or None if nothing comes within the timeout."""
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    return proc.stdout.readline().decode() if ready else None


def stop(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
    proc.stdout.close()


# ---------------------------------------------------------------- icon lookup

class IconTests(Fixture):
    def theme(self):
        root = self.base / "icons" / "test"
        folder = root / "128x128/apps"
        folder.mkdir(parents=True)
        (root / "index.theme").write_text(
            "[Icon Theme]\nName=Test\nDirectories=128x128/apps\n[128x128/apps]\nSize=128\nType=Fixed\n")
        return icon_lookup.Theme("test", [str(root.parent)]), folder

    def test_finds_an_icon(self):
        theme, folder = self.theme()
        (folder / "ghost.png").touch()
        self.assertEqual(theme.find("ghost"), str(folder / "ghost.png"))

    def test_missing_icon(self):
        theme, _ = self.theme()
        self.assertIsNone(theme.find("missing"))

    def test_icon_installed_after_first_scan_is_found(self):
        theme, folder = self.theme()
        theme.find("other")
        time.sleep(0.02)                       # (folder times have a finite resolution)
        (folder / "ghost.png").touch()
        self.assertEqual(theme.find("ghost"), str(folder / "ghost.png"))

    def test_icon_removed_after_first_scan_is_gone(self):
        theme, folder = self.theme()
        path = folder / "ghost.png"
        path.touch()
        theme.find("ghost")
        time.sleep(0.02)
        path.unlink()
        self.assertIsNone(theme.find("ghost"))

    def test_inheritance_cycle_ends(self):
        theme, folder = self.theme()
        index = folder.parents[1] / "index.theme"
        index.write_text(index.read_text().replace("Name=Test", "Name=Test\nInherits=test"))
        lookup = icon_lookup.Lookup()
        lookup.bases = [str(folder.parents[2])]
        lookup.themes = {}
        lookup.use("test")
        self.assertEqual(len([t for t in lookup.chain if t.name == "test"]), 1)

    def test_protocol(self):
        hicolor = Path(self.env["XDG_DATA_HOME"]) / "icons/hicolor"
        (hicolor / "48x48/apps").mkdir(parents=True)
        (hicolor / "index.theme").write_text(
            "[Icon Theme]\nName=hicolor\nDirectories=48x48/apps\n[48x48/apps]\nSize=48\nType=Fixed\n")
        (hicolor / "48x48/apps/demo.png").touch()
        self.stub("gsettings", "#!/bin/bash\necho \"'hicolor'\"\n")
        result = subprocess.run(["python3", "-I", str(SCRIPTS / "icon-lookup.py")], env=self.env,
                                input=b"demo\nnothing-here\n@flush\n", capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        lines = result.stdout.decode().splitlines()
        self.assertIn(f"demo\t{hicolor}/48x48/apps/demo.png", lines)
        self.assertIn("nothing-here\t", lines)
        self.assertEqual(lines[-1], "@done")


# ---------------------------------------------------------------- dropping files onto folders

class MoveTests(Fixture):
    def setUp(self):
        super().setUp()
        self.src = self.base / "src"
        self.dst = self.base / "dst"
        self.src.mkdir()
        self.dst.mkdir()

    def test_moves_a_file(self):
        path = self.src / "a.txt"
        path.write_text("a")
        self.assertEqual(self.run_script("move-into-folder.sh", self.dst, path).returncode, 0)
        self.assertFalse(path.exists())
        self.assertEqual((self.dst / "a.txt").read_text(), "a")

    def test_taken_name_gets_a_number(self):
        path = self.src / "a.txt"
        path.write_text("new")
        (self.dst / "a.txt").write_text("old")
        self.run_script("move-into-folder.sh", self.dst, path)
        self.assertEqual((self.dst / "a.txt").read_text(), "old")
        self.assertEqual((self.dst / "a 2.txt").read_text(), "new")

    def test_unusual_names(self):
        path = self.src / "ö & file\tline\n.txt"
        path.write_text("x")
        self.run_script("move-into-folder.sh", self.dst, path)
        self.assertEqual((self.dst / path.name).read_text(), "x")

    def test_a_file_already_inside_stays(self):
        path = self.dst / "a"
        path.touch()
        self.run_script("move-into-folder.sh", self.dst, path)
        self.assertEqual(list(self.dst.iterdir()), [path])

    def test_a_folder_does_not_go_into_itself(self):
        child = self.src / "child"
        child.mkdir()
        self.run_script("move-into-folder.sh", child, self.src)
        self.assertTrue(self.src.exists())
        self.assertEqual(list(child.iterdir()), [])

    def test_dangling_symlink_is_moved(self):
        path = self.src / "link"
        path.symlink_to("missing")
        self.run_script("move-into-folder.sh", self.dst, path)
        self.assertTrue((self.dst / "link").is_symlink())

    def test_dangling_symlink_in_the_way_gets_a_number(self):
        path = self.src / "a"
        path.write_text("new")
        (self.dst / "a").symlink_to("missing")
        self.run_script("move-into-folder.sh", self.dst, path)
        self.assertTrue((self.dst / "a").is_symlink())
        self.assertTrue((self.dst / "a 2").exists())


# ---------------------------------------------------------------- folder listings and info

class ListingTests(Fixture):
    def listing(self, folder, limit=12):
        result = self.run_script("list-folders.sh", limit, folder)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return [r.split(b"\t", 3) for r in result.stdout.split(b"\0") if r]

    def test_empty_folder(self):
        folder = self.base / "folder"
        folder.mkdir()
        self.assertEqual(self.listing(folder), [[b"0", b"#total", b"0"]])

    def test_missing_folder_has_no_records(self):
        self.assertEqual(self.listing(self.base / "absent"), [])

    def test_hidden_and_unfinished_files_are_skipped_and_the_limit_applies(self):
        folder = self.base / "folder"
        folder.mkdir()
        for name in ["a", "b", ".hidden", "a.part", "a.crdownload", "a.download", "a~"]:
            (folder / name).touch()
        rows = self.listing(folder, 1)
        self.assertEqual(rows[0], [b"0", b"#total", b"2"])
        self.assertEqual(len(rows), 2)

    def test_unusual_file_names(self):
        folder = self.base / "folder"
        folder.mkdir()
        names = ["ö & x.txt", "tab\there.txt", "new\nline.txt", "-option.txt"]
        for name in names:
            (folder / name).write_text("hello")
        rows = self.listing(folder)
        self.assertEqual({r[3].decode() for r in rows[1:]}, {str(folder / n) for n in names})

    def test_folders_are_directories(self):
        folder = self.base / "folder"
        (folder / "sub").mkdir(parents=True)
        self.assertEqual(self.listing(folder)[1][1], b"inode/directory")

    def test_date_added_cache_is_whole_after_parallel_runs(self):
        folder = self.base / "folder"
        folder.mkdir()
        for i in range(300):
            (folder / f"file-{i}.txt").touch()
        runs = [self.start_script("list-folders.sh", 12, folder) for _ in range(4)]
        for run in runs:
            run.communicate(timeout=30)
        cache = next((self.base / "cache/vitrin").glob("added-*.tsv"))
        lines = cache.read_text().splitlines()
        self.assertEqual(len(lines), 300)
        self.assertEqual(list((self.base / "cache/vitrin").glob("*.tmp*")), [])

    @needs("gio")
    def test_folder_info_keeps_tabs_and_newlines_in_paths(self):
        folder = self.base / "tab\tline\nfolder"
        folder.mkdir()
        fields = self.run_script("folder-info.sh", folder).stdout.split(b"\0")
        self.assertEqual(fields[0].decode(), str(folder))
        self.assertTrue(fields[2])             # icon names
        self.assertEqual(fields[3:], [b""])    # nothing else

    def test_folder_info_skips_files(self):
        path = self.base / "file"
        path.touch()
        self.assertEqual(self.run_script("folder-info.sh", path).stdout, b"")


# ---------------------------------------------------------------- watching folders

@needs("inotifywait")
class WatcherTests(Fixture):
    def test_folder_watcher_reports_changes(self):
        folder = self.base / "watched"
        folder.mkdir()
        proc = self.start_script("watch-folders.sh", folder)
        self.addCleanup(stop, proc)
        time.sleep(0.5)
        (folder / "new").touch()
        self.assertEqual(read_line(proc), f"CREATE|{folder}/\n")

    def test_folder_watcher_reports_the_folder_going_away(self):
        folder = self.base / "watched"
        folder.mkdir()
        proc = self.start_script("watch-folders.sh", folder)
        self.addCleanup(stop, proc)
        time.sleep(0.5)
        folder.rmdir()
        seen = [read_line(proc), read_line(proc)]
        self.assertTrue(any(l and "DELETE_SELF" in l.split("|")[0] for l in seen), seen)

    def test_folder_watcher_has_nothing_to_do_without_folders(self):
        result = self.run_script("watch-folders.sh", self.base / "absent")
        self.assertEqual(result.returncode, 0)

    def test_missing_watcher_reports_the_folder_when_it_appears(self):
        wanted = self.base / "Docs"
        proc = self.start_script("watch-missing.sh", wanted)
        self.addCleanup(stop, proc)
        time.sleep(0.5)
        wanted.mkdir()
        self.assertEqual(read_line(proc), f"{wanted}\n")

    def test_missing_watcher_ignores_other_names(self):
        wanted = self.base / "Docs"
        proc = self.start_script("watch-missing.sh", wanted)
        self.addCleanup(stop, proc)
        time.sleep(0.5)
        (self.base / "noise").touch()
        (self.base / "Docs2").mkdir()
        self.assertIsNone(read_line(proc, 1.0))

    def test_missing_watcher_follows_a_path_missing_several_levels_down(self):
        wanted = self.base / "a" / "b" / "c"
        proc = self.start_script("watch-missing.sh", wanted)
        self.addCleanup(stop, proc)
        time.sleep(0.5)
        (self.base / "a").mkdir()
        self.assertEqual(read_line(proc), f"{wanted}\n")   # (the dock then starts it again, closer)

    def test_missing_watcher_handles_names_with_pattern_characters(self):
        wanted = self.base / "we(ird).d+"
        proc = self.start_script("watch-missing.sh", wanted)
        self.addCleanup(stop, proc)
        time.sleep(0.5)
        (self.base / "weirdXd+").mkdir()
        self.assertIsNone(read_line(proc, 0.8))
        wanted.mkdir()
        self.assertEqual(read_line(proc), f"{wanted}\n")

    def test_missing_watcher_has_nothing_to_do_when_everything_exists(self):
        self.assertEqual(self.run_script("watch-missing.sh", self.base).returncode, 0)

    def test_missing_watcher_leaves_nothing_running_when_stopped(self):
        marker = self.base / "marker dir"
        proc = self.start_script("watch-missing.sh", marker / "x")
        time.sleep(0.5)
        stop(proc)
        time.sleep(0.3)
        left = subprocess.run(["pgrep", "-f", f"inotifywait .*{self.base}"], capture_output=True)
        self.assertNotEqual(left.returncode, 0, left.stdout.decode())


# ---------------------------------------------------------------- launching

class LaunchTests(Fixture):
    def setUp(self):
        super().setUp()
        self.recorder("uwsm-app")
        self.recorder("omarchy-launch-tui")

    def entry(self, data_root, exec_line="demo %F", terminal=False):
        path = data_root / "applications" / "demo.desktop"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("[Desktop Entry]\nType=Application\nName=Demo\n"
                        f"Exec={exec_line}\nTerminal={str(terminal).lower()}\n")
        return path

    def test_launches_by_id(self):
        self.entry(Path(self.env["XDG_DATA_HOME"]))
        self.run_script("launch.sh", "demo")
        self.assertEqual(self.logged(), ["--", "demo.desktop"])

    def test_file_arguments_arrive_whole(self):
        path = self.entry(Path(self.env["XDG_DATA_HOME"]))
        names = ["/tmp/a & b", "/tmp/x\ny"]
        self.run_script("launch.sh", "demo", *names)
        self.assertEqual(self.logged(), ["--", "gio", "launch", str(path), *names])

    def test_terminal_apps_run_in_the_terminal(self):
        self.entry(Path(self.env["XDG_DATA_HOME"]), terminal=True)
        self.run_script("launch.sh", "demo", "/tmp/a b")
        self.assertEqual(self.logged(), ["--app-id=org.omarchy.demo", "demo", "/tmp/a b"])

    def test_entries_in_xdg_data_dirs_are_found_for_file_drops(self):
        self.entry(Path(self.env["XDG_DATA_DIRS"]))
        result = self.run_script("launch.sh", "demo", "/tmp/a")
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_show_file_escapes_apostrophes(self):
        self.recorder("gdbus")
        path = self.base / "it's.txt"
        path.touch()
        self.run_script("show-file.sh", "thunar", path)
        uri_argument = self.logged()[-2]
        check = subprocess.run(["python3", "-c", "import ast, sys; ast.literal_eval(sys.argv[1])", uri_argument],
                               capture_output=True)
        self.assertEqual(check.returncode, 0, uri_argument)

    def test_default_terminal_follows_the_users_list(self):
        path = Path(self.env["XDG_CONFIG_HOME"]) / "xdg-terminals.list"
        path.parent.mkdir()
        path.write_text("# comment\ncom.mitchellh.ghostty.desktop\nfoot.desktop\n")
        self.assertEqual(self.run_script("default-terminal.sh").stdout, b"com.mitchellh.ghostty\n")

    def test_window_hints_for_an_unknown_window_are_empty(self):
        self.stub("hyprctl", '#!/bin/bash\necho "[]"\n')
        self.assertEqual(self.run_script("window-hints.sh", "nonexistent").stdout, b"\n\n\n")

    def test_window_hints_for_a_running_process(self):
        self.stub("hyprctl", "#!/bin/bash\nprintf '[{\"class\":\"t\",\"initialClass\":\"t\","
                             f"\"address\":\"0x123\",\"pid\":{os.getpid()}}}]\\n'\n")
        result = self.run_script("window-hints.sh", "--address", "123")
        lines = result.stdout.splitlines()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(lines), 3)
        self.assertIn(b"python", lines[1])

    def test_default_places(self):
        downloads = self.base / "Downloads"
        downloads.mkdir()
        self.stub("xdg-mime", "#!/bin/bash\necho thunar.desktop\n")
        self.stub("xdg-user-dir", '#!/bin/bash\nprintf "%s/Downloads\\n" "$HOME"\n')
        self.stub("gio", '#!/bin/bash\nif [ "${@: -1}" = trash:/// ]; then echo "  standard::display-name: Trash"; '
                         'else echo "  standard::display-name: Downloads"; fi\n')
        self.assertEqual(self.run_script("default-places.sh").stdout.decode().splitlines(),
                         ["thunar", str(downloads), "Downloads", "Trash"])


# ---------------------------------------------------------------- previews

@needs("magick")
class ThumbnailTests(Fixture):
    MIME = "application/x-vitrin-test"

    def setUp(self):
        super().setUp()
        self.stub("preview", '#!/usr/bin/python3\nimport json, os, subprocess, sys\n'
                             'open(os.environ["TEST_LOG"], "w").write(json.dumps(sys.argv[1:]))\n'
                             'subprocess.run(["magick", "-size", "2x2", "xc:red", sys.argv[-1]], check=True)\n')
        self.dir = Path(self.env["XDG_DATA_HOME"]) / "thumbnailers"
        self.dir.mkdir(parents=True)

    def thumbnail(self, path):
        uri = path.as_uri()
        md5 = hashlib.md5(uri.encode()).hexdigest()
        return self.run_script("thumbnail.sh", self.MIME, path, uri, md5)

    def make(self, filename="file.png", command="preview %i %o"):
        path = self.base / filename
        path.write_text("fixture")
        (self.dir / "test.thumbnailer").write_text(
            f"[Thumbnailer Entry]\nExec={command}\nMimeType={self.MIME};\n")
        return path, self.thumbnail(path)

    def test_makes_a_preview_then_reuses_it(self):
        path, result = self.make()
        self.assertIn(b" new ", result.stdout)
        self.assertIn(b" ok ", self.thumbnail(path).stdout)

    def test_ampersand_in_a_path_reaches_the_previewer_whole(self):
        path, _ = self.make("a & b.png")
        self.assertEqual(self.logged()[0], str(path))

    def test_quoted_arguments_in_the_command(self):
        _, result = self.make(command='preview "%i" "%o"')
        self.assertIn(b" new ", result.stdout)

    def test_quoted_program_path_with_a_space(self):
        spaced = self.bin / "my tools"
        spaced.mkdir()
        shutil.copy(self.bin / "preview", spaced / "preview")
        _, result = self.make(command=f'"{spaced}/preview" %i %o')
        self.assertIn(b" new ", result.stdout)

    def test_no_previewer_for_the_type(self):
        path = self.base / "file"
        path.touch()
        result = self.run_script("thumbnail.sh", "x/no-preview", path, path.as_uri(), "hash")
        self.assertEqual(result.stdout, b"hash none\n")

    def test_a_failure_is_remembered(self):
        path, result = self.make(command="false %i %o")
        self.assertIn(b" failed", result.stdout)
        self.stub("false", '#!/bin/bash\necho retried > "$TEST_LOG"\nexit 1\n')
        self.assertIn(b" failed", self.thumbnail(path).stdout)
        self.assertFalse(self.log.exists())


# ---------------------------------------------------------------- pointer settings

class CursorTests(Fixture):
    def setUp(self):
        super().setUp()
        self.stub("hyprctl", '''#!/bin/bash
if [ "$1" = getoption ]; then
  case "$2" in
    cursor:no_warps) echo "bool: false";;
    cursor:warp_on_change_workspace) echo "int: 1";;
    cursor:hide_on_key_press) echo "bool: true";;
    input:follow_mouse) echo "int: 1";;
  esac
else
  [ "${TEST_HYPR_FAIL:-0}" = 1 ] && exit 1
  printf "%s\\n" "$*" >> "$TEST_LOG"
  echo ok
fi
''')
        self.state = self.base / "cache/vitrin"

    def test_warping_goes_off_and_comes_back(self):
        self.run_script("no-warp.sh", "off")
        self.assertTrue((self.state / "warps-off").exists())
        self.run_script("no-warp.sh", "restore")
        self.assertFalse((self.state / "warps-off").exists())
        self.assertIn("no_warps = false", self.log.read_text())

    def test_pointer_settings_go_and_come_back(self):
        self.run_script("keep-cursor.sh", "off")
        self.assertTrue((self.state / "cursor-hide").exists())
        self.run_script("keep-cursor.sh", "restore")
        self.assertFalse((self.state / "cursor-hide").exists())
        self.assertIn("follow_mouse = 1", self.log.read_text())

    def test_failed_warp_restore_keeps_the_saved_values(self):
        self.run_script("no-warp.sh", "off")
        self.env["TEST_HYPR_FAIL"] = "1"
        self.run_script("no-warp.sh", "restore")
        self.assertTrue((self.state / "warps-off").exists())

    def test_failed_pointer_restore_keeps_the_saved_values(self):
        self.run_script("keep-cursor.sh", "off")
        self.env["TEST_HYPR_FAIL"] = "1"
        self.run_script("keep-cursor.sh", "restore")
        self.assertTrue((self.state / "cursor-hide").exists())

    def test_restore_with_nothing_saved_does_nothing(self):
        self.assertEqual(self.run_script("no-warp.sh", "restore").returncode, 0)
        self.assertEqual(self.run_script("keep-cursor.sh", "restore").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
