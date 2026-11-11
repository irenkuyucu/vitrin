// Logic of AppGrid.qml and StackPopup.qml.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./qml.cjs");

describe("app grid", () => {
  const grid = (entries = []) => load("AppGrid.qml", {
    rootId: "grid",
    globals: { DesktopEntries: { applications: { values: entries } } },
  });

  it("finds apps by the start of the name, then anywhere in it, then by description", () => {
    const { root } = grid();
    const list = [{ lower: "other", extra: "term" }, { lower: "xterminal", extra: "" }, { lower: "terminal", extra: "" }, { lower: "none", extra: "" }];
    assert.deepEqual(root.filterApps(list, "term").map(a => a.lower), ["terminal", "xterminal", "other"]);
    assert.deepEqual(root.filterApps(list, "  TERM ").map(a => a.lower), ["terminal", "xterminal", "other"]);
  });

  it("shows everything for an empty search", () => {
    const { root } = grid();
    const list = [{ lower: "a", extra: "" }, { lower: "b", extra: "" }];
    assert.equal(root.filterApps(list, ""), list);
    assert.equal(root.filterApps(list, undefined), list);
  });

  it("lists visible apps by name, with what the search needs", () => {
    const entries = [
      { id: "b.desktop", name: "Beta", genericName: "Editor", comment: "Edits", keywords: ["text"] },
      { id: "hidden", name: "Hidden", noDisplay: true },
      { id: "nameless", name: "" },
      { id: "a.desktop", name: "alpha" },
    ];
    const { root } = grid(entries);
    const apps = root.listApps();
    assert.deepEqual(apps.map(a => a.name), ["alpha", "Beta"]);
    assert.equal(apps[1].extra, "editor edits text");
  });

  it("doesn't fix an app's icon when it lists it (icons follow the lookup while the grid is open)", () => {
    const { root } = grid([{ id: "a", name: "A" }]);
    assert.equal(root.listApps()[0].icons, undefined);
  });
});
