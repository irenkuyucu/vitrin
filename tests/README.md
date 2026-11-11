# Tests

`tests/run.sh` runs every check that doesn't need a desktop session. It takes about ten
seconds and prints `ALL CHECKS PASSED` when everything is fine.

| Part | What it checks |
|---|---|
| `run.sh` | syntax of the shell scripts, Python files, `manifest.json` and QML files |
| `lint_baseline.py` | `qmllint` reports nothing new (known warnings are in `lint-baseline.txt`) |
| `test_scripts.py` | the helper scripts in `scripts/`, run against temporary folders with the desktop commands stubbed |
| `logic/` | the JavaScript logic inside the QML files (window grouping, config, folders, menus, icons), run in Node |
| `live/` | checks that need a running desktop, done by hand: see `live/README.md` |

## Requirements

`bash`, `python3` and `node`, plus Qt 6's `qmlformat` and `qmllint`. Tests that need an
optional tool (`magick`, `gio`, `inotifywait`) skip themselves when it's missing.

## Writing tests

- A fix comes with a test that fails without it. The existing tests were checked this way
  against the code before the fixes.
- Script tests are in `test_scripts.py`. Each one gets a private `HOME`, XDG folders and a
  `PATH` with stub commands in front, so nothing touches your real config or cache.
- Logic tests load the functions of a QML file with `logic/qml.cjs` and run them as the shell
  would, with state set by the test and effects (saving, timers, the compositor) replaced by
  recorders. It can't see property bindings, signal handlers or anything drawn; those are
  checked live.
- `lint_baseline.py --update` records the current `qmllint` warnings as the new baseline.
