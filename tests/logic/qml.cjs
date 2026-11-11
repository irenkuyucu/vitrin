// Loads the JavaScript functions of a QML file into Node, so their logic can be
// tested without Quickshell or a desktop.
//
// QML resolves a bare name against the function's own scope, then the component's
// properties and functions, then the ids around it. The same is done here: the functions
// of the root item are compiled inside `with (root)`, the functions of the dock window
// inside `with (win) with (root)`, with `root` and `win` plain objects the test fills with
// whatever state it needs (properties) and replaces functions on (mocks).
//
//   const env = load("Dock.qml");
//   env.root.pins = ["a"];                     // state
//   env.root.saveConfig = () => saved++;       // a mock replaces the real function
//   env.root.normalizePins(["a", "b"]);        // the real function, run as in the shell
//
// What this can't see: property bindings (a `readonly property var x: ...` is just a value the
// test sets), signal handlers (`onXChanged: ...`) and anything drawn. Logic that lives only
// in those is checked live (tests/live/README.md).
//
// Functions are found by their `function name(` line and the indent it has: 2 spaces is the
// root item, 6 the dock window (`win`). Others (inside handlers, nested helpers) come
// along inside their parent. A name can be in both places: `env.fn(name, "win")` picks.

const fs = require("fs");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..");

// The index just past the brace that closes the one at `open`, skipping strings, comments
// and regular expressions (which can hold braces and quotes).
function matchBrace(src, open) {
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (c === "/" && src[i + 1] === "/") { i = src.indexOf("\n", i); if (i < 0) break; continue; }
    if (c === "/" && src[i + 1] === "*") { i = src.indexOf("*/", i) + 1; continue; }
    if (c === '"' || c === "'" || c === "`") {
      for (i++; i < src.length && src[i] !== c; i++) if (src[i] === "\\") i++;
      continue;
    }
    if (c === "/") {
      let j = i - 1;
      while (j >= 0 && /\s/.test(src[j])) j--;
      const before = j < 0 ? "" : src[j];
      const word = /(?:return|typeof|in|of)$/.test(src.slice(Math.max(0, j - 6), j + 1));
      if (before === "" || "(,=:[!&|?{};".includes(before) || word) {
        let inClass = false;
        for (i++; i < src.length; i++) {
          if (src[i] === "\\") i++;
          else if (src[i] === "[") inClass = true;
          else if (src[i] === "]") inClass = false;
          else if (src[i] === "/" && !inClass) break;
          else if (src[i] === "\n") break;
        }
        continue;
      }
    }
    if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return i + 1;
  }
  throw new Error("unbalanced braces from offset " + open);
}

// Every `function name(...) { ... }` that starts a line: { name, indent, params, text, line }.
function scanFunctions(src) {
  const found = [];
  const start = /^( *)function\s+(\w+)\s*\(([^)]*)\)\s*(?::\s*[\w.<>]+\s*)?\{/gm;
  let m;
  while ((m = start.exec(src))) {
    const open = m.index + m[0].length - 1;
    const end = matchBrace(src, open);
    found.push({
      name: m[2],
      indent: m[1].length,
      params: m[3],
      text: src.slice(m.index + m[1].length, end),
      line: src.slice(0, m.index).split("\n").length,
      typed: m[3].includes(":") || /\)\s*:/.test(m[0]),
    });
    start.lastIndex = end;      // (helpers nested inside it belong to it)
  }
  return found;
}

const SCOPES = { 2: "root", 6: "win" };

// The constants of the root item: `readonly property var hiddenAppIds: ["a", "b"]`, numbers,
// strings and booleans written as literals. A test then runs with the shipped values.
function scanConstants(src) {
  const found = {};
  const start = /^  (?:readonly )?property (?:var|int|real|string|bool) (\w+): (?=[\[\d"'tf-])/gm;
  let m;
  while ((m = start.exec(src))) {
    const at = m.index + m[0].length;
    let end;
    if (src[at] === "[") {
      let depth = 0;
      end = at;
      do { if (src[end] === "[") depth++; else if (src[end] === "]") depth--; end++; } while (depth > 0 && end < src.length);
    } else {
      end = src.indexOf("\n", at);
    }
    const text = src.slice(at, end).replace(/\/\/.*$/gm, "").trim();
    try { found[m[1]] = new Function("return (" + text + ")")(); } catch (e) { /* not a plain literal */ }
  }
  return found;
}

const scanned = new Map();      // (a file is read and scanned once per run)

function load(file, { winId = "win", rootId = "root", globals = {} } = {}) {
  if (!scanned.has(file)) {
    const text = fs.readFileSync(path.join(REPO, file), "utf8");
    scanned.set(file, { text, constants: scanConstants(text), fns: scanFunctions(text).filter(f => !f.typed && !/^on[A-Z]/.test(f.name)) });
  }
  const { text: src, fns, constants } = scanned.get(file);
  const root = JSON.parse(JSON.stringify(constants));      // (a fresh copy for every test)
  const win = {};
  // What a function can see besides the item's own properties: the ids around it and the
  // QML/Quickshell globals. A test adds or replaces these on env.globals.
  const g = {
    Qt: { callLater: (f, ...a) => f(...a), resolvedUrl: u => "file:///repo/" + u },
    [rootId]: root,
    [winId]: win,
    ...globals,
  };
  const env = { root, win, globals: g, functions: fns, constants, src };
  for (const f of fns) {
    const scope = SCOPES[f.indent];
    if (!scope) continue;
    const body = scope === "win"
      ? `with (g) with (${rootId}) with (${winId}) { return (${f.text}); }`
      : `with (g) with (${rootId}) { return (${f.text}); }`;
    let fn;
    try { fn = new Function("g", rootId, winId, body)(g, root, win); }
    catch (e) { throw new Error(`${file}:${f.line} function ${f.name} does not compile: ${e.message}`); }
    (scope === "win" ? win : root)[f.name] = fn;
  }
  env.fn = (name, scope = "root") => (scope === "win" ? win : root)[name];
  return env;
}

module.exports = { load, scanFunctions, REPO };
