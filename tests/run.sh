#!/usr/bin/env bash
# Runs every check that doesn't need the desktop: syntax of all files, qmllint against its
# baseline, the script tests and the QML logic tests. Usage: tests/run.sh   (from anywhere)
# Live checks (drags, menus, a reloaded shell) are listed in tests/live/README.md.
set -u
cd "$(dirname "$0")/.." || exit 1
failed=0
step() { printf '\n== %s\n' "$1"; }
fail() { echo "FAIL: $1"; failed=1; }

step "shell scripts parse"
for f in scripts/*.sh tests/run.sh; do bash -n "$f" || fail "$f"; done

step "python files parse"
for f in scripts/*.py tests/*.py; do
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f" || fail "$f"
done

step "manifest is valid JSON"
python3 -I -c 'import json; json.load(open("manifest.json"))' || fail manifest.json

step "QML files parse"
if [ -x /usr/lib/qt6/bin/qmlformat ]; then
  for f in *.qml; do /usr/lib/qt6/bin/qmlformat "$f" >/dev/null 2>&1 || fail "$f"; done
else
  echo "qmlformat is missing: skipped"
fi

step "qmllint: nothing new"
python3 -I tests/lint_baseline.py || fail qmllint

step "script tests"
python3 -B -I -m unittest discover -s tests -p 'test_*.py' 2>&1 | tail -n 40
[ "${PIPESTATUS[0]}" = 0 ] || fail "script tests"

step "QML logic tests"
if command -v node >/dev/null; then
  node --test tests/logic/ 2>&1 | grep -E '^\s*(✖|not ok)|^ℹ (tests|pass|fail)|Error' | head -n 40
  [ "${PIPESTATUS[0]}" = 0 ] || fail "QML logic tests"
else
  echo "node is missing: skipped"
fi

echo
if [ "$failed" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$failed"
