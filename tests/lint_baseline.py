"""Checks that qmllint reports nothing new.

qmllint finds a few hundred warnings in this plugin, mostly because it can't see the shell's
own types (unqualified access to ids and Quickshell objects). They're recorded in
lint-baseline.txt as a count per file and kind of warning, so a change that adds one is
noticed while line numbers can move freely.

  python3 tests/lint_baseline.py            compare with the baseline (fails on anything new)
  python3 tests/lint_baseline.py --update   record the current state as the baseline
"""
import collections
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASELINE = Path(__file__).resolve().parent / "lint-baseline.txt"
QMLLINT = "/usr/lib/qt6/bin/qmllint"
IMPORTS = "/usr/share/omarchy/shell"


def current():
    out = subprocess.run([QMLLINT, "--ignore-settings", "-I", IMPORTS, *sorted(p.name for p in REPO.glob("*.qml"))],
                         cwd=REPO, capture_output=True, text=True).stderr
    counts = collections.Counter()
    for line in out.splitlines():
        m = re.match(r"Warning: (\S+?\.qml):\d+:\d+: .*\[([\w-]+)\]$", line)
        if m:
            counts[(m.group(1), m.group(2))] += 1
    return counts


def read_baseline():
    counts = collections.Counter()
    for line in BASELINE.read_text().splitlines():
        file, kind, n = line.split()
        counts[(file, kind)] = int(n)
    return counts


def main():
    if not Path(QMLLINT).exists() or not Path(IMPORTS).exists():
        print("qmllint or the shell's types are missing: skipped")
        return 0
    now = current()
    if "--update" in sys.argv:
        BASELINE.write_text("".join(f"{f} {k} {n}\n" for (f, k), n in sorted(now.items())))
        print(f"recorded {sum(now.values())} warnings in {BASELINE.name}")
        return 0
    before = read_baseline()
    worse = [(key, before[key], n) for key, n in sorted(now.items()) if n > before[key]]
    better = sum(before[key] - now[key] for key in before if now[key] < before[key])
    for (file, kind), was, n in worse:
        print(f"new qmllint warning: {file} [{kind}] {was} -> {n}")
    if worse:
        print("(see them with: qmllint --ignore-settings -I /usr/share/omarchy/shell <file>)")
        return 1
    print(f"no new warnings ({sum(now.values())} known)" + (f"; {better} fewer than the baseline: run with --update" if better else ""))
    return 0


sys.exit(main())
