// Logic of Dock.qml: window grouping, pins, config, folders, menus, icons, spacing.
// Run with: node --test tests/logic/   (or tests/run.sh)
const { describe, it, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./qml.cjs");

// The real functions with the state of a freshly started dock. Anything with an effect
// (saving, timers, the compositor) is replaced by a recorder.
function dock(overrides = {}) {
  const calls = [];
  const globals = {
    Quickshell: { env: () => "/home/u", iconPath: name => (name ? "image://icon/" + name : ""), execDetached: c => calls.push(["exec", c]) },
    configRetryTimer: { stop: () => calls.push(["retry stop"]), restart: () => calls.push(["retry restart"]) },
    iconLookup: { running: false, write: () => {} },
    Util: { fileUrl: p => "file://" + p },
    configFile: { setText: t => calls.push(["write", t]) },
    ToplevelManager: { toplevels: { values: [] } },
    DesktopEntries: { byId: id => (overrides.entries || {})[id] || null },
    menuColumn: { windowRows: [] },
    windowList: { contentY: 0, height: 320 },
    console: { warn: m => calls.push(["warn", m]), log: () => {}, error: () => {} },
    ...overrides.globals,
  };
  const env = load("Dock.qml", { globals });
  const r = env.root;
  const real = Object.assign({}, r);          // (functions a test wants to run for real, see overrides.keep)
  Object.assign(r, {
    pluginId: "vitrin", home: "/home/u", configPath: "/home/u/.config/omarchy/vitrin.json",
    fixedApp: "files", knownFileManagers: ["org.gnome.Nautilus", "thunar"], appsKey: "vitrin:apps", showApps: true,
    terminalApp: "", effectiveAliases: {}, aliases: {}, hiddenAppIds: ["org.omarchy.screensaver"],
    sharedAppIds: ["TUI.tile", "TUI.float"], vendorWords: ["org", "com", "net", "io", "dev", "app", "desktop", "github", "gitlab"],
    pins: ["files"], folders: [], middle: [], recentQuitAt: {}, trashName: "Trash",
    configLoaded: true, configBroken: false, configFinalCheck: false,
    iconSize: 52, spacingBaseSize: 52, baseGap: 15, baseEnds: 15, dividerGapRatio: 1.375,
    windowHints: {}, firstSeen: {}, hintWaitMax: 2000, certainEntryFor: () => ({}), windowsSettled: true,
    noDisplayApps: ["imv", "imv-dir", "gcr-viewer"], recentMax: 3, showRecent: true, layout: [],
    iconExtents: {}, themeIcons: {}, iconsWanted: {}, letterIcon: "vitrin:letter", appsIcon: "vitrin:apps", launcherOf: {},
    // effects
    syncLayout: () => calls.push(["syncLayout"]),
    folderBounce: p => calls.push(["bounce", p]),
    currentSettings: () => ({}),
    ...overrides.root,
  });
  for (const name of overrides.keep || []) r[name] = real[name];
  env.calls = calls;
  return env;
}

const names = env => env.calls.filter(c => c[0] === "write").map(c => JSON.parse(c[1]));

// ------------------------------------------------------------------ window grouping

describe("computeGroups", () => {
  let env;
  beforeEach(() => { env = dock({ root: { keyFor: id => id } }); });

  it("groups windows by app, in order of first appearance", () => {
    const [a1, b1, a2] = [{ appId: "a" }, { appId: "b" }, { appId: "a" }];
    const g = env.root.computeGroups([a1, b1, a2]);
    assert.deepEqual(g.order, ["a", "b"]);
    assert.deepEqual(g.byKey.a, [a1, a2]);
    assert.equal(g.pending, false);
  });

  it("skips hidden apps and windows without an id", () => {
    const g = env.root.computeGroups([{ appId: "org.omarchy.screensaver" }, { appId: "" }, null, { appId: "a" }]);
    assert.deepEqual(g.order, ["a"]);
  });

  it("puts a dialog under its top-most parent's app", () => {
    const parent = { appId: "editor" };
    const dialog = { appId: "generic", parent: { appId: "mid", parent } };
    const g = env.root.computeGroups([dialog]);
    assert.deepEqual(g.order, ["editor"]);
  });

  it("copes with app ids that are names on every object", () => {
    for (const id of ["constructor", "toString", "__proto__", "hasOwnProperty"]) {
      const w = { appId: id };
      const g = env.root.computeGroups([w, { appId: id }]);
      assert.equal(g.byKey[id].length, 2, id);
      assert.deepEqual(g.order, [id]);
    }
  });

  it("waits for a window no app matches for certain until its process has been asked", () => {
    env.root.certainEntryFor = id => (id === "known" ? {} : null);
    const g = env.root.computeGroups([{ appId: "org.omarchy.agent" }, { appId: "known" }]);
    assert.equal(g.pending, true);
    assert.deepEqual(g.order, ["known"]);                   // (not shown under its own id meanwhile)
    env.root.windowHints = { "org.omarchy.agent": { exe: "/usr/bin/ghostty" } };
    env.root.keyFor = id => (id === "org.omarchy.agent" ? "com.mitchellh.ghostty" : id);
    const after = env.root.computeGroups([{ appId: "org.omarchy.agent" }, { appId: "known" }]);
    assert.equal(after.pending, false);
    assert.deepEqual(after.order, ["com.mitchellh.ghostty", "known"]);
  });

  it("stops waiting after the limit, whatever happened to the question", () => {
    env.root.certainEntryFor = () => null;
    env.root.hintWaitMax = 2000;
    env.root.firstSeen = { stuck: Date.now() - 500 };
    assert.equal(env.root.computeGroups([{ appId: "stuck" }]).pending, true);
    env.root.firstSeen = { stuck: Date.now() - 2500 };
    const g = env.root.computeGroups([{ appId: "stuck" }]);
    assert.deepEqual(g.order, ["stuck"]);
    assert.equal(g.pending, false);
  });

  it("waits for a window that hasn't been noticed yet", () => {
    env.root.certainEntryFor = () => null;
    env.root.hintWaitMax = 2000;
    env.root.firstSeen = {};
    assert.equal(env.root.computeGroups([{ appId: "new" }]).pending, true);
  });

  it("shows a window nothing matches under its own id once its process was asked", () => {
    env.root.certainEntryFor = () => null;
    env.root.windowHints = { mystery: { launched: "", exe: "", cmd: "" } };
    const g = env.root.computeGroups([{ appId: "mystery" }]);
    assert.deepEqual(g.order, ["mystery"]);
    assert.equal(g.pending, false);
  });

  it("looks up an alias's target, not the window id, when deciding whether to wait", () => {
    env.root.effectiveAliases = { odd: "foot" };
    env.root.certainEntryFor = id => (id === "foot" ? {} : null);
    assert.equal(env.root.computeGroups([{ appId: "odd" }]).pending, false);
  });

  describe("helper windows", () => {
    const entries = { portal: { id: "xdg-desktop-portal-gtk", noDisplay: true }, imv: { id: "imv", noDisplay: true },
      gedit: { id: "gedit", noDisplay: false } };
    const setup = (extra = {}) => {
      const e = dock({ root: { keyFor: id => id, certainEntryFor: id => entries[id] || null, ...extra } });
      return e;
    };

    it("leaves out a window whose entry says NoDisplay", () => {
      const g = setup().root.computeGroups([{ appId: "portal" }, { appId: "gedit" }]);
      assert.deepEqual(g.order, ["gedit"]);
    });

    it("keeps one that is pinned, a file viewer, or given an alias by the user", () => {
      assert.deepEqual(setup({ pins: ["files", "xdg-desktop-portal-gtk"] }).root.computeGroups([{ appId: "portal" }]).order, ["portal"]);
      assert.deepEqual(setup().root.computeGroups([{ appId: "imv" }]).order, ["imv"]);
      assert.deepEqual(setup({ aliases: { portal: "x" } }).root.computeGroups([{ appId: "portal" }]).order, ["portal"]);
    });

    it("doesn't leave out a window only guessed to belong to such an entry", () => {
      const e = setup({ certainEntryFor: () => null, windowHints: { guess: { exe: "/usr/bin/x" } }, keyFor: () => "xdg-desktop-portal-gtk" });
      assert.deepEqual(e.root.computeGroups([{ appId: "guess" }]).order, ["xdg-desktop-portal-gtk"]);
    });

    it("leaves out the webcam overlay and the screensaver by their ids (the shipped list)", () => {
      const e = setup({ hiddenAppIds: undefined });
      delete e.root.hiddenAppIds;
      const ids = ["WebcamOverlay-small", "WebcamOverlay-medium", "WebcamOverlay-large", "org.omarchy.screensaver"];
      for (const id of ids) assert.ok(e.constants.hiddenAppIds.includes(id), id);
      e.root.hiddenAppIds = e.constants.hiddenAppIds;
      assert.deepEqual(e.root.computeGroups(ids.map(appId => ({ appId }))).order, []);
    });

    it("keeps the file viewers in the shipped exception list", () => {
      assert.deepEqual(setup().constants.noDisplayApps, ["imv", "imv-dir", "gcr-viewer"]);
    });

    it("waits while the list of apps hasn't loaded yet, but not for ever", () => {
      const e = setup({ windowsSettled: false });
      const early = e.root.computeGroups([{ appId: "gedit" }], []);
      assert.equal(early.pending, true);
      assert.deepEqual(early.order, []);
      e.root.windowsSettled = true;
      assert.deepEqual(e.root.computeGroups([{ appId: "gedit" }], []).order, ["gedit"]);
    });
  });

  it("waits for windows under a shared id until their entry is known", () => {
    env.root.sharedKeyFor = () => null;
    const g = env.root.computeGroups([{ appId: "TUI.tile" }, { appId: "a" }]);
    assert.equal(g.pending, true);
    assert.deepEqual(g.order, ["a"]);
    env.root.sharedKeyFor = () => "lazydocker";
    assert.deepEqual(env.root.computeGroups([{ appId: "TUI.tile" }]).order, ["lazydocker"]);
  });
});

// ------------------------------------------------------------------ the middle section

describe("syncLayout", () => {
  const setup = (extra = {}, entries = {}) => {
    const env = dock({ entries, keep: ["syncLayout"], root: {
      groups: { byKey: Object.create(null), order: [], pending: false },
      middle: [], recentQuitAt: {}, effectiveAliases: {}, ...extra } });
    env.root.saveConfig = () => {};
    return env;
  };

  it("forgets a helper's icon and an id an alias sends elsewhere", () => {
    const env = setup({ middle: ["xdg-desktop-portal-gtk", "org.omarchy.agent", "WhatsApp"],
      effectiveAliases: { "org.omarchy.agent": "com.mitchellh.ghostty" } },
      { "xdg-desktop-portal-gtk": { id: "xdg-desktop-portal-gtk", noDisplay: true } });
    env.root.syncLayout();
    assert.deepEqual(env.root.middle, ["WhatsApp"]);
  });

  it("keeps a running app even if its key looks stale", () => {
    const byKey = Object.create(null);
    byKey["org.omarchy.agent"] = [{}];
    const env = setup({ middle: ["org.omarchy.agent"], groups: { byKey, order: ["org.omarchy.agent"], pending: false },
      effectiveAliases: { "org.omarchy.agent": "x" } });
    env.root.syncLayout();
    assert.deepEqual(env.root.middle, ["org.omarchy.agent"]);
  });

  it("keeps up to three quit apps and drops the one that quit longest ago", () => {
    const env = setup({ middle: ["a", "b", "c", "d"], recentQuitAt: { a: 1, b: 2, c: 3, d: 4 } });
    env.root.syncLayout();
    assert.deepEqual(env.root.middle, ["b", "c", "d"]);
  });

  it("adds newly opened apps at the right end", () => {
    const byKey = Object.create(null);
    byKey.n = [{}];
    const env = setup({ middle: ["a"], recentQuitAt: { a: 5 }, groups: { byKey, order: ["n"], pending: false } });
    env.root.syncLayout();
    assert.deepEqual(env.root.middle, ["a", "n"]);
  });
});

// ------------------------------------------------------------------ pins

describe("normalizePins", () => {
  it("keeps the file manager first, once, and adds the Apps icon", () => {
    const env = dock();
    assert.deepEqual(env.root.normalizePins(["x", "files", "x"]), ["files", "vitrin:apps", "x"]);
  });

  it("leaves out the Apps icon when it's turned off", () => {
    const env = dock({ root: { showApps: false } });
    assert.deepEqual(env.root.normalizePins(["files", "x"]), ["files", "x"]);
  });

  it("moves pins saved under an alias to the app they're grouped under", () => {
    const env = dock({ root: { effectiveAliases: { "org.omarchy.terminal": "foot" } } });
    assert.deepEqual(env.root.normalizePins(["files", "org.omarchy.terminal", "foot"]), ["files", "vitrin:apps", "foot"]);
  });

  it("drops another file manager in first place (it was the fixed one before)", () => {
    const env = dock();
    assert.deepEqual(env.root.normalizePins(["thunar", "x"]), ["files", "vitrin:apps", "x"]);
  });

  it("ignores things that aren't ids", () => {
    const env = dock();
    assert.deepEqual(env.root.normalizePins(["files", 5, "", null, "x"]), ["files", "vitrin:apps", "x"]);
  });
});

// ------------------------------------------------------------------ config file

describe("applyConfig", () => {
  const config = extra => JSON.stringify({ settings: {}, pins: ["files"], folders: [], aliases: {}, recent: [], ...extra });
  let env;
  beforeEach(() => { env = dock({ root: { applySettings: () => true } }); });

  it("loads pins, folders and aliases", () => {
    env.root.applyConfig(config({
      pins: ["files", "a"], aliases: { x: "y" },
      folders: [{ path: "~/Downloads", name: "Downloads" }, { path: "trash:///", name: "Trash" }],
    }));
    assert.deepEqual(env.root.pins, ["files", "vitrin:apps", "a"]);
    assert.deepEqual(env.root.aliases, { x: "y" });
    assert.equal(env.root.folders.length, 2);
    assert.equal(env.root.configLoaded, true);
  });

  it("clears the aliases when the key is removed from the file", () => {
    env.root.aliases = { old: "target" };
    env.root.applyConfig(JSON.stringify({ pins: ["files"], folders: [] }));
    assert.deepEqual(env.root.aliases, {});
  });

  it("keeps the Trash last, wherever the file puts it", () => {
    env.root.applyConfig(config({ folders: [{ path: "trash:///", name: "Trash" }, { path: "/tmp", name: "Tmp" }] }));
    assert.deepEqual(env.root.folders.map(f => f.path), ["/tmp", "trash:///"]);
    assert.ok(env.calls.some(c => c[0] === "write"), "the corrected order is saved");
  });

  it("names a folder after itself when the file gives no name", () => {
    env.root.applyConfig(config({ folders: [{ path: "~/Pictures/Holiday/" }, { path: "trash:///" }] }));
    assert.deepEqual(env.root.folders.map(f => f.name), ["Holiday", "Trash"]);
  });

  it("skips folders without a path", () => {
    env.root.applyConfig(config({ folders: [{ name: "x" }, { path: "" }, null, { path: "/tmp", name: "Tmp" }] }));
    assert.deepEqual(env.root.folders.map(f => f.path), ["/tmp"]);
  });

  it("reads the middle section, once per app and without hidden ones", () => {
    env.root.applyConfig(config({ recent: [
      { key: "a", quitAt: 5 }, { key: "a" }, { key: "org.omarchy.screensaver" }, { key: "b", quitAt: null }, { nope: 1 } ] }));
    assert.deepEqual(env.root.middle, ["a", "b"]);
    assert.deepEqual(env.root.recentQuitAt, { a: 5 });
  });

  it("waits and retries when the file can't be read, keeping what it has", () => {
    env.root.pins = ["keep"];
    env.root.applyConfig("{");
    assert.deepEqual(env.root.pins, ["keep"]);
    assert.deepEqual(env.calls.at(-1), ["retry restart"]);
    assert.equal(env.root.configBroken, false);
  });

  it("calls the file broken only after the wait, and backs it up", () => {
    env.root.configFinalCheck = true;
    env.root.applyConfig("{");
    assert.equal(env.root.configBroken, true);
    assert.deepEqual(env.calls.find(c => c[0] === "exec")[1].slice(0, 3), ["cp", "-f", "--"]);
  });

  it("does not take a JSON list, string, number or null for a config", () => {
    for (const text of ["[]", '"x"', "null", "5"]) {
      env.calls.length = 0;
      env.root.pins = ["keep"];
      env.root.applyConfig(text);
      assert.deepEqual(env.root.pins, ["keep"], text);
      assert.deepEqual(env.calls.at(-1), ["retry restart"], text);
    }
  });
});

describe("saveConfig", () => {
  it("writes nothing before the file has been read", () => {
    const env = dock({ root: { configLoaded: false } });
    env.root.saveConfig();
    assert.deepEqual(names(env), []);
  });

  it("writes nothing while the file is broken", () => {
    const env = dock({ root: { configBroken: true } });
    env.root.saveConfig();
    assert.deepEqual(names(env), []);
  });

  it("writes everything it keeps", () => {
    const env = dock({ root: { pins: ["files", "a"], aliases: { x: "y" }, middle: ["m"], recentQuitAt: { m: 7 },
      folders: [{ path: "trash:///", name: "Trash" }], currentSettings: () => ({ iconSize: 52 }) } });
    env.root.saveConfig();
    assert.deepEqual(names(env)[0], {
      settings: { iconSize: 52 }, pins: ["files", "a"], folders: [{ path: "trash:///", name: "Trash" }],
      recent: [{ key: "m", quitAt: 7 }], aliases: { x: "y" },
    });
  });
});

// ------------------------------------------------------------------ folders

describe("folder shortcuts", () => {
  const downloads = { name: "Downloads", icon: "folder-download", path: "~/Downloads" };
  const trash = { name: "Trash", icon: "user-trash", path: "trash:///" };
  let env;
  beforeEach(() => {
    env = dock({ root: { folders: [downloads, trash], themeIcons: { folder: "file:///f.png", "folder-music": "file:///m.png" } } });
  });
  const paths = () => env.root.folders.map(f => f.path);

  it("adds a folder before the Trash, with ~ for the home folder, and saves", () => {
    env.root.addFolders([{ path: "/home/u/Music", name: "Music", icons: ["inode-directory", "folder-music"] }], -1);
    assert.deepEqual(paths(), ["~/Downloads", "~/Music", "trash:///"]);
    assert.equal(env.root.folders[1].icon, "folder-music");
    assert.equal(env.root.folders[1].displayAs, "stack");
    assert.equal(names(env).length, 1);
  });

  it("never adds past the Trash, even when asked to", () => {
    env.root.addFolders([{ path: "/srv/x", name: "x", icons: [] }], 99);
    assert.deepEqual(paths(), ["~/Downloads", "/srv/x", "trash:///"]);
  });

  it("adds several at the chosen place, in order", () => {
    env.root.addFolders([{ path: "/a", name: "a", icons: [] }, { path: "/b", name: "b", icons: [] }], 0);
    assert.deepEqual(paths(), ["/a", "/b", "~/Downloads", "trash:///"]);
  });

  it("bounces a folder that's already there instead of adding it again", () => {
    env.root.addFolders([{ path: "/home/u/Downloads", name: "Downloads", icons: [] }], -1);
    assert.deepEqual(paths(), ["~/Downloads", "trash:///"]);
    assert.deepEqual(env.calls.find(c => c[0] === "bounce"), ["bounce", "/home/u/Downloads"]);
    assert.equal(names(env).length, 0);
  });

  it("can't remove the Trash", () => {
    env.root.removeFolder("trash:///");
    assert.deepEqual(paths(), ["~/Downloads", "trash:///"]);
    env.root.removeFolder("~/Downloads");
    assert.deepEqual(paths(), ["trash:///"]);
  });

  it("moves folders around but keeps the Trash last", () => {
    env.root.folders = [downloads, { name: "a", path: "/a" }, { name: "b", path: "/b" }, trash];
    env.root.moveFolder(0, 99);
    assert.deepEqual(paths(), ["/a", "/b", "~/Downloads", "trash:///"]);
    env.root.moveFolder(3, 0);                        // the Trash itself doesn't move
    assert.deepEqual(paths(), ["/a", "/b", "~/Downloads", "trash:///"]);
    env.root.moveFolder(2, 0);
    assert.deepEqual(paths(), ["~/Downloads", "/a", "/b", "trash:///"]);
  });

  it("changes one option of one folder", () => {
    env.root.setFolderOption("~/Downloads", "displayAs", "folder");
    assert.equal(env.root.folders[0].displayAs, "folder");
    assert.equal(env.root.folders[1].displayAs, undefined);
  });
});

// ------------------------------------------------------------------ paths and listings

describe("paths", () => {
  const env = dock();
  it("expands ~ only at the start", () => {
    assert.equal(env.root.expandPath("~"), "/home/u");
    assert.equal(env.root.expandPath("~/x"), "/home/u/x");
    assert.equal(env.root.expandPath("/a/~/b"), "/a/~/b");
  });

  it("turns file URLs into paths", () => {
    assert.equal(env.root.localPath("file:///tmp/a%20b%C3%B6"), "/tmp/a bö");
    assert.equal(env.root.localPath("trash:///"), "trash:///");
  });

  it("builds file URIs the way GIO does, so thumbnails are shared", () => {
    assert.equal(env.root.fileUri("/tmp/ö #%.png"), "file:///tmp/%C3%B6%20%23%25.png");
    assert.equal(env.root.fileUri("/tmp/a;b:c@d&e=f+$x,?.png"), "file:///tmp/a%3Bb:c@d&e=f+$x,%3F.png");
  });
});

describe("parseFolderListing", () => {
  const env = dock({ root: { mimeIcon: (mime, isDir, icons) => icons.split(",")[0] } });
  const record = (...f) => f.join("\t") + "\0";

  it("reads files, totals and kinds", () => {
    const text = record(0, "#total", 3) + record(0, "image/png", "image-x-generic", "/d/a.png") + record(0, "inode/directory", "folder", "/d/sub");
    const { files, totals } = env.root.parseFolderListing(["/d"], text);
    assert.equal(totals["/d"], 3);
    assert.deepEqual(files["/d"].map(f => [f.name, f.isDir, f.image]), [["a.png", false, true], ["sub", true, false]]);
  });

  it("keeps tabs and newlines inside file names", () => {
    const path = "/d/a\tb\nc.txt";
    const { files } = env.root.parseFolderListing(["/d"], record(0, "text/plain", "text-x-generic", path));
    assert.equal(files["/d"][0].path, path);
    assert.equal(files["/d"][0].name, "a\tb\nc.txt");
  });

  it("sorts records into the right folder and ignores unknown ones", () => {
    const text = record(1, "text/plain", "x", "/two/f") + record(7, "text/plain", "x", "/nowhere/f") + "junk";
    const { files } = env.root.parseFolderListing(["/one", "/two"], text);
    assert.deepEqual(files["/one"], []);
    assert.equal(files["/two"].length, 1);
  });

  it("has no total for a folder that wasn't listed (it's missing)", () => {
    const { totals } = env.root.parseFolderListing(["/d"], "");
    assert.equal(totals["/d"], undefined);
  });
});

// ------------------------------------------------------------------ names and labels

describe("names", () => {
  const env = dock();
  it("windowLabel shortens long titles and falls back to the app id", () => {
    assert.equal(env.root.windowLabel({ title: "short" }), "short");
    assert.equal(env.root.windowLabel({ title: "x".repeat(48) }).length, 48);
    assert.equal(env.root.windowLabel({ title: "x".repeat(49) }), "x".repeat(47) + "…");
    assert.equal(env.root.windowLabel({ appId: "foot" }), "foot");
    assert.equal(env.root.windowLabel({}), "Window");
  });

  it("prettyName makes a readable name from an app id", () => {
    assert.equal(env.root.prettyName("org.localsend.localsend_app", []), "Localsend");
    assert.equal(env.root.prettyName("com.mitchellh.ghostty", []), "Ghostty");
    assert.equal(env.root.prettyName("some-tool-gui", []), "Some Tool");
    assert.equal(env.root.prettyName("MyEditor", []), "My Editor");
  });

  it("prettyName prefers the window title's own capitalization when it matches", () => {
    assert.equal(env.root.prettyName("org.localsend.localsend_app", [{ title: "LocalSend" }]), "LocalSend");
    assert.equal(env.root.prettyName("org.localsend.localsend_app", [{ title: "Something else entirely" }]), "Localsend");
  });
});

// ------------------------------------------------------------------ keyboard menus

describe("menus by keyboard", () => {
  const rows = () => {
    const a = { kind: "window", label: "Untitled", toplevel: { id: 1 } };
    const b = { kind: "window", label: "Untitled", toplevel: { id: 2 } };
    const quit = { kind: "action", label: "Quit", act: "quit" };
    const sep = { kind: "separator" };
    return { a, b, quit, sep, list: [a, b, sep, quit] };
  };
  const menu = () => {
    const env = dock({ root: { hyprAddressFor: t => "0x" + t.id } });
    return env;
  };

  it("lists windows first, then actions, skipping separators and disabled rows", () => {
    const env = menu(), { a, b, quit, sep } = rows();
    const dead = { kind: "action", label: "Nope", disabled: true };
    env.win.menuList = [quit, sep, dead, a, b];
    assert.deepEqual(env.win.keyMenuRows(), [a, b, quit]);
  });

  it("Down moves past windows with the same title", () => {
    const env = menu(), { a, b, quit, list } = rows();
    env.win.menuList = list;
    env.win.keyMenuSelect(a);
    env.win.keyMenuMove(1);
    assert.equal(env.win.menuKeyRow, b);
    env.win.keyMenuMove(1);
    assert.equal(env.win.menuKeyRow, quit);
    env.win.keyMenuMove(1);                            // wraps around
    assert.equal(env.win.menuKeyRow, a);
    env.win.keyMenuMove(-1);
    assert.equal(env.win.menuKeyRow, quit);
  });

  it("tells rows apart by what they are, not only by their label", () => {
    const env = menu(), { a, b } = rows();
    env.win.menuList = [a, b];
    assert.notEqual(env.win.rowKey(a), env.win.rowKey(b));
    const x = { kind: "action", label: "Open", act: "open" }, y = { kind: "action", label: "Open", act: "open-with" };
    assert.notEqual(env.win.rowKey(x), env.win.rowKey(y));
  });
});

// ------------------------------------------------------------------ choosing a window row

describe("runRow", () => {
  it("brings a window forward, unless it's gone", () => {
    const alive = { id: 1 }, gone = { id: 2 };
    const env = dock({ globals: { ToplevelManager: { toplevels: { values: [alive] } } } });
    const forward = [];
    env.root.bringForward = t => forward.push(t);
    env.root.runRow({ kind: "window", toplevel: alive }, {}, null);
    env.root.runRow({ kind: "window", toplevel: gone }, {}, null);
    assert.deepEqual(forward, [alive]);
  });
});

// ------------------------------------------------------------------ icons

describe("icons", () => {
  it("pickIcon skips candidates known to be broken and ends in the letter tile", () => {
    const env = dock({ root: { iconExtents: { bad: false, good: { l: 0 } } } });
    assert.equal(env.root.pickIcon(["bad", "good", "vitrin:letter"]), "good");
    assert.equal(env.root.pickIcon(["bad", "vitrin:letter"]), "vitrin:letter");
    assert.equal(env.root.pickIcon(["bad"]), "vitrin:letter");
    assert.equal(env.root.pickIcon(["unmeasured"]), "unmeasured");
  });

  it("themeIcon asks the lookup once for a name it doesn't know, and answers from Qt meanwhile", () => {
    const asked = [];
    const env = dock({ root: { askForIcons: () => asked.push("ask") } });
    assert.equal(env.root.themeIcon("ghost"), "image://icon/ghost");
    env.root.themeIcon("ghost");
    assert.deepEqual(Object.keys(env.root.iconsWanted), ["ghost"]);
    assert.equal(asked.length, 1);
  });

  it("themeIcon returns the lookup's answer, including 'none' (empty)", () => {
    const env = dock({ root: { themeIcons: { have: "file:///a.png", none: "" } } });
    assert.equal(env.root.themeIcon("have"), "file:///a.png");
    assert.equal(env.root.themeIcon("none"), "");
  });

  it("candidates go from the entry's own icon to the letter tile, without repeats", () => {
    const env = dock({ root: { themeIcons: { "my-icon": "file:///my.png", "my-app": "file:///app.png" } } });
    const list = env.root.iconCandidatesFor({ icon: "my-icon", id: "my-app" }, "my-app");
    assert.equal(list[0], "file:///my.png");
    assert.ok(list.includes("file:///app.png"));
    assert.equal(list.at(-1), "vitrin:letter");
    assert.equal(new Set(list).size, list.length);
  });

  it("a path icon becomes a file URL candidate", () => {
    const env = dock();
    const list = env.root.iconCandidatesFor({ icon: "/opt/app/icon.png", id: "x" }, "x");
    assert.equal(list[0], "file:///opt/app/icon.png");
  });

  it("keeps working after the lookup process dies (restarts it, gives up after 5 quick stops)", () => {
    const env = dock();
    const restarts = [];
    env.globals.iconToolsRestart = { restart: () => restarts.push(1) };
    const tool = { startedAt: Date.now(), quickDeaths: 0, command: ["python3"] };
    for (let i = 0; i < 4; i++) env.root.iconToolDied(tool);
    assert.equal(restarts.length, 4);
    assert.equal(tool.restarted, true);
    env.root.iconToolDied(tool);
    assert.equal(restarts.length, 4, "no restart after the 5th quick stop");
    assert.match(env.calls.find(c => c[0] === "warn")[1], /python3 keeps stopping/);
    tool.startedAt = Date.now() - 60000;               // it ran for a minute: the count starts over
    env.root.iconToolDied(tool);
    assert.equal(tool.quickDeaths, 0);
    assert.equal(restarts.length, 5);
  });
});

// ------------------------------------------------------------------ spacing

describe("spacing", () => {
  const at = size => dock({ root: { iconSize: size } }).root;    // (the Size setting)

  it("gaps are 15 px at the default size and scale with the icon size, in whole pixels", () => {
    assert.equal(at(52).gapFor(52), 15);
    assert.equal(at(48).gapFor(48), 14);
    assert.equal(at(72).gapFor(72), 21);
    assert.equal(at(32).gapFor(32), 9);
    assert.equal(at(52).endsFor(52), 15);
  });

  it("only a dock shrunk below its size uses fractions", () => {
    const r = at(52);
    assert.equal(r.fractional(52), false);
    assert.equal(r.fractional(40.5), true);
    assert.ok(Math.abs(r.gapFor(40.5) - 15 * 40.5 / 52) < 1e-9);
    assert.equal(Number.isInteger(r.gapFor(51.9)), false);
  });

  it("the divider's sides are 1.375 gaps", () => {
    const r = at(52);
    assert.equal(r.dividerSideFor(52), Math.round(15 * 1.375));
  });
});

// ------------------------------------------------------------------ keyboard

describe("keyboard search", () => {
  it("folds accents and the Turkish dotless i", () => {
    const env = dock();
    assert.equal(env.win.keyFold("Öğrenci Işık"), "ogrenci isik");
    assert.equal(env.win.keyFold("İstanbul"), "istanbul");
    assert.equal(env.win.keyFold("Crème Brûlée"), "creme brulee");
  });
});

// ------------------------------------------------------------------ web apps

describe("web apps", () => {
  it("matches a web app window to its entry by the address it opens", () => {
    const env = dock();
    const entry = { execString: "omarchy-launch-webapp https://web.whatsapp.com/" };
    env.root.webApps = env.root.buildWebApps([entry, { execString: "firefox" }]);
    assert.equal(env.root.webAppEntryFor("chrome-web.whatsapp.com__-Default"), entry);
    assert.equal(env.root.webAppEntryFor("chrome-other.example__-Default"), null);
  });
});

// ------------------------------------------------------------------ the file itself

describe("Dock.qml", () => {
  it("has its functions picked up whole (a sign the extraction still understands the file)", () => {
    const env = dock();
    assert.ok(env.functions.length > 200, "only " + env.functions.length + " functions found");
    for (const name of ["computeGroups", "applyConfig", "saveConfig", "normalizePins", "parseFolderListing"])
      assert.equal(typeof env.root[name], "function", name);
    for (const name of ["rowKey", "keyMenuMove", "keyFold"]) assert.equal(typeof env.win[name], "function", name);
  });
});
