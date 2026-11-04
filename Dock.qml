import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// Vitrin: a macOS-style dock for the Omarchy shell.
//
// Layout, left to right: apps (pinned ones plus whatever else is running, in one ordered
// row), a divider, then folder shortcuts (Downloads, Trash). Windows of the same app share
// one icon; right-click lists them. The dock hides off-screen and slides up when the
// pointer touches the bottom edge. Settings live in the config file (configPath).
Item {
  id: root

  // Plugin identity, in one place: used for the config file, Hyprland layer names (which
  // blur rules match) and log messages.
  readonly property string pluginId: "vitrin"
  readonly property string slug: "vitrin"

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/" + slug + ".json"

  // Helper scripts shipped in the plugin's scripts/ folder.
  function script(name) {
    return decodeURIComponent(String(Qt.resolvedUrl("scripts/" + name)).replace(/^file:\/\//, ""))
  }

  // User settings, changed from the Dock Settings panel (right-click the divider) and
  // saved under "settings" in the config file. Ranges are enforced in applySettings().
  readonly property var settingDefaults: ({
    iconSize: 52,          // pixels, 32-72
    autoHide: true,        // hide off-screen until the pointer hits the bottom edge
    hideDelay: 500,        // ms after the pointer leaves before hiding, 0-2000
    animateLaunch: true,   // bounce icons while their app opens
    dividerResize: true    // drag the divider up/down to resize the dock (like macOS)
  })
  property int iconSize: settingDefaults.iconSize
  property bool autoHide: settingDefaults.autoHide
  property int hideDelay: settingDefaults.hideDelay
  property bool animateLaunch: settingDefaults.animateLaunch
  property bool dividerResize: settingDefaults.dividerResize

  // Look and feel. Shapes follow the GNOME/Adwaita conventions the Files app uses
  // (rounded surfaces, hairline borders, soft shadows); colors follow the Omarchy theme.
  // Spacing and corner rounding scale with the icon size (48 px -> 6 px padding, 16 px corners).
  // Every icon is loaded once at the resolution the largest dock needs (2x for sharpness),
  // so changing the size only scales already-loaded images instead of reloading them.
  readonly property int iconSourceSize: 144
  // Height proportions match the macOS dock (measured from a MacBook Air: at 60 px icons
  // the dock is 86 px tall, like macOS's 85 pt).
  readonly property int itemPad: padFor(iconSize)      // above and below each icon
  readonly property int dockPad: padFor(iconSize)      // inside the dock's edge
  readonly property int edgeMargin: 4                  // between the dock and the screen edge
  readonly property int dockRadius: Math.round(iconSize / 3)
  function padFor(size) { return Math.round(size * 0.1) }
  function slotHeightFor(size) { return size + padFor(size) * 2 }
  readonly property int menuRadius: 12
  readonly property int rowRadius: 6
  readonly property int tipRadius: 6
  readonly property int shadowPad: 12      // room around popups for their shadow
  readonly property int hoverSlack: 12     // extra hover area around the dock, in pixels
  readonly property int popupGap: 8
  readonly property string uiFont: "Adwaita Sans"
  readonly property int uiFontSize: 14
  readonly property color foreground: Commons.Color.foreground
  readonly property color background: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color surface: Qt.lighter(background, 1.22)   // menus sit slightly above the dock
  readonly property color hairline: Util.alpha(foreground, 0.12)
  readonly property color rowHover: Util.alpha(foreground, 0.10)

  // Windows the dock never appears over, not even from the bottom edge, while they have
  // focus: Omarchy's screensaver is a full-screen terminal window, and nudging the mouse
  // while it runs shouldn't bring the dock up.
  readonly property var neverShowOver: ["org.omarchy.screensaver"]

  // Files is the dock's Finder: always first, always pinned, can't be removed or moved.
  readonly property string fixedApp: "org.gnome.Nautilus"

  function isFixed(key) {
    return key === root.fixedApp
  }

  // Saved state (see config file)
  property var pins: [fixedApp]
  property var folders: defaultFolders()
  // Extra grouping rules from the config file: { "<window app id>": "<desktop entry id>" }
  // puts that app's windows under another app's icon. Empty by default; terminals are
  // handled automatically (see "terminal" below).
  property var aliases: ({})

  // Session state: the order apps appear in. Pinned apps keep their saved order; apps that
  // aren't pinned are added at the end when they open and removed when they close.
  property var layout: []

  function defaultFolders() {
    return [
      { name: "Downloads", icon: "folder-download", path: "~/Downloads" },
      { name: "Trash", icon: "user-trash", path: "trash:///" }
    ]
  }

  // ------------------------------------------------------------ terminal
  // Omarchy opens some terminal windows under its own app id ("org.omarchy.terminal")
  // and others under the terminal's (e.g. "foot"). Both are grouped under the default
  // terminal's icon, shown as "Terminal", and new ones are opened the Omarchy way.
  // The default terminal is whatever Omarchy is set to use (foot, Alacritty, Ghostty,
  // Kitty, ...); see scripts/default-terminal.sh.
  property string terminalApp: ""
  readonly property var knownTerminals: ["foot", "Alacritty", "com.mitchellh.ghostty", "kitty"]

  Process {
    id: terminalFinder
    running: true
    command: ["bash", root.script("default-terminal.sh")]
    stdout: StdioCollector {
      onStreamFinished: {
        var id = String(text).trim()
        if (!id || !DesktopEntries.byId(id)) {
          // No preference recorded: fall back to the first known terminal that's installed.
          id = ""
          for (var i = 0; i < root.knownTerminals.length; i++) {
            if (DesktopEntries.byId(root.knownTerminals[i])) { id = root.knownTerminals[i]; break }
          }
        }
        if (id !== root.terminalApp) root.terminalApp = id
      }
    }
  }

  // Re-checked when the dock appears (at most once a minute), so switching terminals with
  // `omarchy install terminal` is picked up without restarting the shell.
  property real terminalCheckedAt: 0
  function refreshTerminal() {
    if (terminalFinder.running || Date.now() - root.terminalCheckedAt < 60000) return
    root.terminalCheckedAt = Date.now()
    terminalFinder.running = true
  }

  // Grouping rules: built-in ones for terminals, then the user's from the config file.
  readonly property var effectiveAliases: {
    var map = {}
    if (root.terminalApp) map["org.omarchy.terminal"] = root.terminalApp
    map["footclient"] = "foot"
    map["org.codeberg.dnkl.foot"] = "foot"
    for (var k in root.aliases) map[k] = root.aliases[k]
    return map
  }

  function isTerminal(key) {
    return !!root.terminalApp && key === root.terminalApp
  }

  // Pins saved under another id (an old "org.omarchy.terminal" pin, or an aliased app id)
  // belong to the icon they're grouped under. Files always comes first.
  function normalizePins(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (typeof p !== "string" || p.length === 0) continue
      var key = root.effectiveAliases[p] || p
      if (out.indexOf(key) === -1) out.push(key)
    }
    return [root.fixedApp].concat(out.filter(function(k) { return k !== root.fixedApp }))
  }

  onTerminalAppChanged: {
    var normalized = normalizePins(root.pins)
    if (JSON.stringify(normalized) !== JSON.stringify(root.pins)) {
      // The renamed icon may already be on screen (as a running app); save the order as
      // shown so the saved pin order and the visible order don't drift apart.
      root.pins = normalized
      savePinsFromLayout(root.pins)
    }
  }

  // ------------------------------------------------------------ config file
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: function(error) {
      // First run: no config yet, so write the defaults.
      root.saveConfig()
    }
  }

  // Set when the config file can't be parsed: saving is paused (so a hand edit with a
  // typo isn't overwritten) until the file is fixed, after a backup copy is made.
  property bool configBroken: false

  // A file caught mid-save (many tools empty it, then write it, sometimes more than once)
  // looks broken for a moment. So an unreadable read only starts (or restarts) a short
  // wait; the file counts as broken only if it's still unreadable once it has been quiet
  // for the whole wait.
  property bool configFinalCheck: false
  Timer {
    id: configRetryTimer
    interval: 500
    onTriggered: {
      root.configFinalCheck = true
      configFile.reload()
    }
  }

  // Assigns only when the value actually changed, so saving (which reloads the file)
  // doesn't make the dock rebuild or recheck folders for nothing.
  function assignIfChanged(name, value) {
    if (JSON.stringify(root[name]) !== JSON.stringify(value)) root[name] = value
  }

  function applyConfig(raw) {
    var cfg
    try {
      cfg = JSON.parse(raw)
      if (!cfg || typeof cfg !== "object" || Array.isArray(cfg)) throw new Error("not a JSON object")
    } catch (e) {
      if (!root.configFinalCheck && !root.configBroken) {
        configRetryTimer.restart()
        return
      }
      root.configFinalCheck = false
      if (!root.configBroken) {
        root.configBroken = true
        Quickshell.execDetached(["cp", "-f", "--", root.configPath, root.configPath + ".broken"])
        console.warn(root.pluginId + ": " + root.configPath + " can't be read (" + e + "). "
          + "Keeping the current settings and not saving until it's fixed; a copy is in "
          + root.configPath + ".broken")
      }
      return
    }
    configRetryTimer.stop()
    root.configFinalCheck = false
    root.configBroken = false
    var needsSave = false

    if (cfg.aliases && typeof cfg.aliases === "object" && !Array.isArray(cfg.aliases)) {
      assignIfChanged("aliases", cfg.aliases)
    } else {
      needsSave = true
    }

    if (Array.isArray(cfg.folders)) {
      var folders = []
      for (var f = 0; f < cfg.folders.length; f++) {
        var folder = cfg.folders[f]
        if (!folder || typeof folder.path !== "string" || folder.path.length === 0) continue
        if (typeof folder.name !== "string" || folder.name.length === 0) {
          // No name given: use the folder's own name.
          folder = Object.assign({}, folder, { name: isTrash(folder) ? "Trash"
            : expandPath(folder.path).replace(/\/+$/, "").split("/").pop() || folder.path })
        }
        folders.push(folder)
      }
      assignIfChanged("folders", folders)
    } else {
      needsSave = true
    }

    if (Array.isArray(cfg.pins)) {
      var normalized = normalizePins(cfg.pins)
      if (JSON.stringify(normalized) !== JSON.stringify(cfg.pins)) needsSave = true
      assignIfChanged("pins", normalized)
    }

    if (!applySettings(cfg.settings)) needsSave = true
    // Write back normalized pins and any settings added in newer versions.
    if (needsSave) saveConfig()
  }

  // Applies saved settings, falling back to defaults for anything missing or out of range.
  // Returns false when the file needs rewriting (missing keys, bad values).
  function applySettings(s) {
    var ok = !!s && typeof s === "object"
    s = ok ? s : {}
    function num(key, min, max, step) {
      var v = Number(s[key])
      if (s[key] === undefined || !isFinite(v)) { ok = false; return root.settingDefaults[key] }
      var c = Math.max(min, Math.min(max, Math.round(v / step) * step))
      if (c !== v) ok = false
      return c
    }
    function bool(key) {
      if (typeof s[key] !== "boolean") { ok = false; return root.settingDefaults[key] }
      return s[key]
    }
    root.iconSize = num("iconSize", 32, 72, 4)
    root.hideDelay = num("hideDelay", 0, 2000, 100)
    root.autoHide = bool("autoHide")
    root.animateLaunch = bool("animateLaunch")
    root.dividerResize = bool("dividerResize")
    // Settings this version doesn't know (left from older versions) are dropped on save.
    for (var key in s) if (root.settingDefaults[key] === undefined) ok = false
    return ok
  }

  function currentSettings() {
    return {
      iconSize: root.iconSize,
      autoHide: root.autoHide,
      hideDelay: root.hideDelay,
      animateLaunch: root.animateLaunch,
      dividerResize: root.dividerResize
    }
  }

  // Called by the settings panel: apply right away; `persist` writes the file (sliders
  // only persist when released, so dragging doesn't rewrite the file on every step).
  function setSetting(key, value, persist) {
    root[key] = value
    if (persist) saveConfig()
  }

  function resetSettings() {
    applySettings(root.settingDefaults)
    saveConfig()
  }

  function saveConfig() {
    if (root.configBroken) return
    configFile.setText(JSON.stringify({
      settings: currentSettings(),
      pins: root.pins,
      folders: root.folders,
      aliases: root.aliases
    }, null, 2) + "\n")
  }

  // ------------------------------------------------------------ apps & windows
  function entryFor(appId) {
    if (!appId) return null
    return DesktopEntries.byId(appId) || webAppEntryFor(appId) || DesktopEntries.heuristicLookup(appId) || null
  }

  // Omarchy web apps (WhatsApp, HEY, YouTube, ...) are entries that run
  // `omarchy-launch-webapp <url>`, which opens a Chromium-based browser with --app=<url>.
  // Chromium names such windows "chrome-<host>_<path with / as _>-<profile>", e.g.
  // https://web.whatsapp.com/ -> "chrome-web.whatsapp.com__-Default". This maps those
  // names back to their entries: { "web.whatsapp.com__": entry, ... }.
  readonly property var webApps: buildWebApps(DesktopEntries.applications.values)

  function buildWebApps(entries) {
    var map = {}
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var exec = String(entry.execString || "")
      var m = exec.match(/omarchy-launch-webapp\s+["']?([^\s"']+)/) || exec.match(/--app=["']?([^\s"']+)/)
      if (!m) continue
      var url = m[1].replace(/^[a-z]+:\/\//i, "")
      var slash = url.indexOf("/")
      var host = slash === -1 ? url : url.slice(0, slash)
      var path = slash === -1 ? "/" : url.slice(slash).split(/[?#]/)[0]
      map[host + "_" + path.replace(/\//g, "_")] = entry
    }
    return map
  }

  function webAppEntryFor(appId) {
    var m = String(appId).match(/^[a-z]+-(.+)-[^-]+$/)   // strip "chrome-" and "-Default"
    return m && root.webApps[m[1]] ? root.webApps[m[1]] : null
  }

  // A window's group key: its desktop entry id when we can find one, else its app id.
  function keyFor(appId) {
    var target = root.effectiveAliases[appId] || appId
    var entry = entryFor(target)
    return entry ? String(entry.id) : String(target)
  }

  function iconSource(name) {
    var fallback = Quickshell.iconPath("application-x-executable", true)
    if (!name) return fallback
    if (String(name).charAt(0) === "/") return Util.fileUrl(name)
    return Quickshell.iconPath(name, true) || fallback
  }

  // ------------------------------------------------------------ spacing
  // Icon themes pad their artwork unevenly (a document icon is narrower than a folder, some
  // fill the whole square), so equal slots leave uneven visible gaps. Instead, each icon's
  // slot is as wide as its visible artwork plus one gap, with the artwork centered in it:
  // every visible gap is the same, and slots still meet edge to edge (no dead click space).
  // Each icon's visible extent is measured once from its pixels (see iconMeasurer below);
  // until then it gets the classic equal slot.

  // source url -> { l, r } (visible left/right edge as fractions of the icon's width),
  // or false when it couldn't be measured.
  property var iconExtents: ({})
  property var measureQueue: []

  // The gaps and end spaces are set for 52 px icons (the default size) and scale in
  // proportion with the icon size, rounded to whole pixels (15 px at 52 -> 14 at 48, 21 at 72).
  readonly property int spacingBaseSize: 52
  readonly property int baseGap: 15        // between two icons' artwork
  readonly property int baseEnds: 15       // from the dock's edge to the first/last artwork

  function gapFor(size) { return Math.round(root.baseGap * size / root.spacingBaseSize) }
  function endsFor(size) { return Math.round(root.baseEnds * size / root.spacingBaseSize) }

  // Padding inside the dock's left and right edges (including its 1 px border). The end
  // slots already bring half a gap of the end space.
  function sidePadFor(size) {
    return Math.max(1, endsFor(size) - Math.round(gapFor(size) / 2))
  }
  // Slot width for an icon that hasn't been measured yet (or can't be).
  function classicSlotFor(size) { return size + Math.round(size / 8) * 2 }

  // Slot width for an icon source at a given icon size. Used for both the real layout and
  // the resize preview, so the two always agree.
  function slotWidthFor(src, size) {
    var e = root.iconExtents[src]
    if (!e) return classicSlotFor(size)
    return Math.round((e.r - e.l) * size) + gapFor(size)
  }

  // How far to move the artwork sideways so its visible middle sits mid-slot.
  function artOffsetFor(src, size) {
    var e = root.iconExtents[src]
    return e ? Math.round((0.5 - (e.l + e.r) / 2) * size) : 0
  }

  // Space on each side of the divider line, as a multiple of the gap between two icons,
  // rounded to whole pixels: 21 px beside 15 px gaps (macOS measures about 1.47).
  readonly property real dividerGapRatio: 1.375

  function dividerSideFor(size) { return Math.round(gapFor(size) * root.dividerGapRatio) }

  function dividerWidthFor(size) {
    // The icons beside the divider already bring half a gap each; the divider adds the rest
    // plus its 1 px line.
    return 2 * dividerSideFor(size) - gapFor(size) + 1
  }

  // The icon a slot is sized by. A folder shown as a stack is sized by a generic document
  // icon (the shape most piles show) rather than by its current files, so its slot keeps
  // one width as files come and go.
  function slotSourceFor(item, isFolder) {
    if (isFolder && root.displayAsFor(item) === "stack") return root.iconSource("text-x-generic")
    return root.iconSource(item.icon)
  }

  // Every slot's sizing icon, apps then folders.
  readonly property var dockSources: root.items.map(function(i) { return root.slotSourceFor(i, false) })
    .concat(root.folders.map(function(f) { return root.slotSourceFor(f, true) }))
  onDockSourcesChanged: queueMeasurements()

  function queueMeasurements() {
    var q = root.measureQueue.slice()
    for (var i = 0; i < root.dockSources.length; i++) {
      var s = root.dockSources[i]
      if (s && root.iconExtents[s] === undefined && q.indexOf(s) === -1) q.push(s)
    }
    if (q.length !== root.measureQueue.length) root.measureQueue = q
  }

  // Measure an icon that isn't a slot of its own (file icons in a stack pile).
  function requestMeasurement(src) {
    if (!src || root.iconExtents[src] !== undefined || root.measureQueue.indexOf(src) !== -1) return
    root.measureQueue = root.measureQueue.concat([src])
  }

  function finishMeasurement(src, extent) {
    var m = Object.assign({}, root.iconExtents)
    m[src] = extent
    root.iconExtents = m
    root.measureQueue = root.measureQueue.filter(function(s) { return s !== src })
  }

  function expandPath(path) {
    return String(path).indexOf("~/") === 0 ? root.home + String(path).slice(1) : String(path)
  }

  // Open windows grouped by app: { byKey: { key: [toplevel, ...] }, order: [key, ...] }.
  readonly property var groups: computeGroups(ToplevelManager.toplevels.values, DesktopEntries.applications.values, root.effectiveAliases)

  function computeGroups(toplevels, _apps, _aliases) {
    var byKey = {}
    var order = []
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t || !t.appId) continue
      var key = keyFor(t.appId)
      if (!byKey[key]) {
        byKey[key] = []
        order.push(key)
      }
      byKey[key].push(t)
    }
    return { byKey: byKey, order: order }
  }

  onGroupsChanged: {
    syncLayout()
    settleLaunching()
  }
  onPinsChanged: syncLayout()

  function syncLayout() {
    var running = root.groups.byKey
    var next = []
    // Keep existing entries that are still pinned or running, in their current order.
    for (var i = 0; i < root.layout.length; i++) {
      var key = root.layout[i]
      if (next.indexOf(key) === -1 && (root.pins.indexOf(key) !== -1 || running[key])) next.push(key)
    }
    // Pins not shown yet (startup, or the file was edited): place after the previous pin.
    for (var p = 0; p < root.pins.length; p++) {
      var pin = root.pins[p]
      if (next.indexOf(pin) !== -1) continue
      var at = 0
      for (var q = p - 1; q >= 0; q--) {
        var prev = next.indexOf(root.pins[q])
        if (prev !== -1) {
          at = prev + 1
          break
        }
      }
      next.splice(at, 0, pin)
    }
    // Newly opened apps go at the end.
    for (var r = 0; r < root.groups.order.length; r++) {
      if (next.indexOf(root.groups.order[r]) === -1) next.push(root.groups.order[r])
    }
    // Files is always first.
    next = [root.fixedApp].concat(next.filter(function(k) { return k !== root.fixedApp }))
    if (JSON.stringify(next) !== JSON.stringify(root.layout)) root.layout = next
  }

  readonly property var items: root.layout.map(function(key) {
    var entry = DesktopEntries.byId(key) || entryFor(key)
    return {
      key: key,
      entry: entry,
      name: isTerminal(key) ? "Terminal" : (entry ? entry.name : key),
      icon: entry ? entry.icon : key,
      pinned: root.pins.indexOf(key) !== -1,
      windows: root.groups.byKey[key] || []
    }
  })

  // ------------------------------------------------------------ actions
  function launch(item) {
    if (!item.entry) return
    markLaunching(item)
    if (isTerminal(item.key)) {
      // The Omarchy way (opens in the current terminal's folder), when available.
      Util.execArgv(["bash", "-c", 'command -v omarchy-launch-terminal >/dev/null && exec omarchy-launch-terminal; '
        + 'exec bash "$0" "$1"', root.script("launch.sh"), item.entry.id])
      return
    }
    // See scripts/launch.sh (handles entry IDs with spaces, which uwsm-app rejects).
    Util.execArgv(["bash", root.script("launch.sh"), item.entry.id])
  }

  // Click: launch if closed; focus if in the background; cycle if already focused.
  function activate(item) {
    var windows = item.windows
    if (windows.length === 0) {
      launch(item)
      return
    }
    var focused = -1
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].activated) focused = i
    }
    windows[focused === -1 ? 0 : (focused + 1) % windows.length].activate()
  }

  function openFolder(folder) {
    Util.execArgv(["uwsm-app", "--", "nautilus", "--new-window", expandPath(folder.path)])
  }

  function quit(item) {
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].close()
  }

  // ------------------------------------------------------------ launch feedback
  // key -> { count: windows open when launched, at: timestamp }. An icon bounces while its
  // key is here; it stops when a new window for that app appears, or after launchTimeout.
  property var launching: ({})
  readonly property int launchTimeout: 12000

  // Like macOS, only a cold start bounces: opening another window of an app that's
  // already running (New Window, middle-click, dropped files) doesn't.
  function markLaunching(item) {
    if (item.windows.length > 0) return
    var next = Object.assign({}, root.launching)
    next[item.key] = { count: item.windows.length, at: Date.now() }
    root.launching = next
  }

  function isLaunching(key) {
    return root.launching[key] !== undefined
  }

  function settleLaunching() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launching) {
      var state = root.launching[key]
      var open = (root.groups.byKey[key] || []).length
      if (open > state.count || now - state.at > root.launchTimeout) changed = true
      else next[key] = state
    }
    if (changed) root.launching = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launching).length > 0
    onTriggered: root.settleLaunching()
  }

  // ------------------------------------------------------------ trash
  property int trashCount: 0

  function isTrash(folder) {
    return !!folder && folder.path === "trash:///"
  }

  Process {
    id: trashCounter
    command: ["bash", "-c", "ls -A \"$HOME/.local/share/Trash/files\" 2>/dev/null | wc -l"]
    stdout: StdioCollector {
      onStreamFinished: root.trashCount = parseInt(text) || 0
    }
  }

  function refreshTrash() {
    if (!trashCounter.running) trashCounter.running = true
  }

  Timer {
    id: trashRefreshSoon
    interval: 700
    onTriggered: root.refreshTrash()
  }

  function emptyTrash() {
    Util.execArgv(["gio", "trash", "--empty"])
    root.trashCount = 0
    trashRefreshSoon.restart()
  }

  // ------------------------------------------------------------ folder stacks
  // Each folder (except Trash) has two options, saved per folder in the config file:
  //   openAs:    "stack"  -> clicking shows its newest files in a grid above the icon
  //              "folder" -> clicking opens it in Files
  //   displayAs: "stack"  -> the dock icon shows its newest files piled up
  //              "folder" -> the dock icon is the folder icon
  // Both default to "stack", like Downloads on macOS.
  readonly property int stackMax: 12

  function openAsFor(folder) {
    return isTrash(folder) || folder.openAs === "folder" ? "folder" : "stack"
  }

  function displayAsFor(folder) {
    return isTrash(folder) || folder.displayAs === "folder" ? "folder" : "stack"
  }

  function setFolderOption(path, key, value) {
    root.folders = root.folders.map(function(f) {
      if (f.path !== path) return f
      var copy = Object.assign({}, f)
      copy[key] = value
      return copy
    })
    saveConfig()
  }

  // Newest entries of each folder, by date added: { "/home/me/Downloads": [file, ...] }
  // with file = { path, name, isDir, mime, icon, image }.
  property var folderFiles: ({})
  property bool folderRefreshPending: false

  function filesFor(folder) {
    return root.folderFiles[expandPath(folder.path)] || []
  }

  Process {
    id: folderLister
    property var dirs: []
    stdout: StdioCollector {
      onStreamFinished: root.applyFolderListing(folderLister.dirs, text)
    }
    onRunningChanged: {
      if (!running && root.folderRefreshPending) {
        root.folderRefreshPending = false
        root.refreshFolders()
      }
    }
  }

  function refreshFolders() {
    if (folderLister.running) {
      root.folderRefreshPending = true
      return
    }
    var dirs = root.folders.filter(function(f) { return !isTrash(f) }).map(function(f) { return expandPath(f.path) })
    if (dirs.length === 0) return
    folderLister.dirs = dirs
    // See scripts/list-folders.sh: newest entries by date added, hidden files and
    // unfinished downloads skipped.
    folderLister.command = ["bash", root.script("list-folders.sh"), String(root.stackMax)].concat(dirs)
    folderLister.running = true
  }

  Timer {
    id: folderRefreshSoon
    interval: 700
    onTriggered: root.refreshFolders()
  }

  // With hiding off the dock is always on screen, so keep its stack icons current.
  Timer {
    interval: 15000
    repeat: true
    running: !root.autoHide
    onTriggered: root.refreshFolders()
  }

  onFoldersChanged: folderRefreshSoon.restart()

  // Records are NUL-terminated "<folder index>\t<mime type>\t<path>" (so any file name,
  // even one with a tab or line break in it, comes through intact).
  function applyFolderListing(dirs, text) {
    var map = {}
    for (var d = 0; d < dirs.length; d++) map[dirs[d]] = []
    var records = String(text).split("\u0000")
    for (var i = 0; i < records.length; i++) {
      var parts = records[i].split("\t")
      if (parts.length < 3) continue
      var dir = dirs[parseInt(parts[0])]
      if (!map[dir]) continue
      var path = parts.slice(2).join("\t")
      var mime = parts[1] || "application/octet-stream"
      var isDir = mime === "inode/directory"
      map[dir].push({
        path: path,
        name: path.slice(path.lastIndexOf("/") + 1),
        isDir: isDir,
        mime: mime,
        icon: mimeIcon(mime, isDir),
        image: /^image\/(png|jpeg|gif|webp|bmp|svg\+xml)$/.test(mime)
      })
    }
    assignIfChanged("folderFiles", map)
  }

  // File-type icon from the current icon theme, with generic fallbacks.
  function mimeIcon(mime, isDir) {
    if (isDir) return "folder"
    var top = mime.split("/")[0]
    var generic = { text: "text-x-generic", image: "image-x-generic", audio: "audio-x-generic",
                    video: "video-x-generic", font: "font-x-generic" }[top]
    var candidates = [mime.replace("/", "-"), generic,
                      /zip|tar|compressed|archive|rar|7z/.test(mime) ? "package-x-generic" : null,
                      "text-x-generic"]
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] && Quickshell.iconPath(candidates[i], true)) return candidates[i]
    }
    return "text-x-generic"
  }

  function openFile(path) {
    Util.execArgv(["uwsm-app", "--", "gio", "open", path])
  }

  function showInFiles(path) {
    Util.execArgv(["uwsm-app", "--", "nautilus", "--select", path])
  }

  // ------------------------------------------------------------ dropping files
  function localPath(url) {
    var s = String(url)
    return s.indexOf("file://") === 0 ? decodeURIComponent(s.slice(7)) : s
  }

  // See scripts/move-into-folder.sh: moved on the same drive, copied from another,
  // never overwriting.
  function moveIntoFolder(folder, files) {
    Quickshell.execDetached(["bash", root.script("move-into-folder.sh"), folder].concat(files))
  }

  // Trash and folders take dropped files; so do apps, except Files (like Finder on macOS,
  // it isn't a place to drop documents onto).
  function acceptsDrop(item, isFolder) {
    if (isFolder) return isTrash(item) || expandPath(item.path).charAt(0) === "/"
    return !!item.entry && !isFixed(item.key)
  }

  function dropFiles(item, isFolder, urls) {
    var targets = []
    for (var i = 0; i < urls.length; i++) targets.push(localPath(urls[i]))
    if (targets.length === 0) return

    if (isFolder) {
      // Only local files can be trashed or moved.
      var files = targets.filter(function(t) { return t.charAt(0) === "/" })
      if (files.length === 0) return
      if (isTrash(item)) {
        // Moves to the Trash (recoverable).
        Util.execArgv(["gio", "trash", "--"].concat(files))
        trashRefreshSoon.restart()
      } else {
        moveIntoFolder(expandPath(item.path), files)
        folderRefreshSoon.restart()
      }
      return
    }

    if (!item.entry) return
    // Open the files with this app, like "Open With" in a file manager.
    markLaunching(item)
    Quickshell.execDetached(["bash", "-l", root.script("launch.sh"), String(item.entry.id)].concat(targets))
  }

  // Saved pin order always follows the on-screen order.
  function savePinsFromLayout(pinnedKeys) {
    root.pins = root.layout.filter(function(k) { return pinnedKeys.indexOf(k) !== -1 })
    saveConfig()
  }

  // Keep in Dock: the icon stays exactly where it is.
  function pin(key) {
    if (root.pins.indexOf(key) !== -1) return
    savePinsFromLayout(root.pins.concat([key]))
  }

  function unpin(key) {
    if (isFixed(key)) return
    root.pins = root.pins.filter(function(p) { return p !== key })
    saveConfig()
  }

  // Nothing moves Files, and nothing moves in front of it (position 0).
  function move(key, delta) {
    var list = root.layout.slice()
    var from = list.indexOf(key)
    var to = from + delta
    if (isFixed(key) || from === -1 || to < 1 || to >= list.length) return
    list.splice(from, 1)
    list.splice(to, 0, key)
    root.layout = list
    savePinsFromLayout(root.pins)
  }

  // Drag to reorder: put the app at position `to` in the app row.
  function moveTo(key, to) {
    var from = root.layout.indexOf(key)
    if (from === -1 || to === from) return
    move(key, to - from)
  }

  function windowLabel(toplevel) {
    var title = String(toplevel.title || toplevel.appId || "Window")
    return title.length > 48 ? title.slice(0, 47) + "…" : title
  }

  // Menu rows: { kind: "window" | "action" | "text" | "separator" | "submenu" | "back" |
  //              "choice", label, act, toplevel, current, disabled, danger, secondary,
  //              page, value, key, checked }
  function menuRows(item, isFolder) {
    if (isFolder) {
      var folderRows = [{ kind: "action", label: "Open in Files", act: "open" }]
      if (isTrash(item)) {
        folderRows.push({ kind: "separator" })
        folderRows.push({ kind: "action", label: "Empty Trash…", act: "empty-ask", disabled: root.trashCount === 0 })
      } else {
        folderRows.push({ kind: "separator" })
        folderRows.push({ kind: "submenu", label: "Open as", page: "openAs",
                          value: openAsFor(item) === "stack" ? "Stack" : "Folder" })
        folderRows.push({ kind: "submenu", label: "Display as", page: "displayAs",
                          value: displayAsFor(item) === "stack" ? "Stack" : "Folder" })
      }
      return folderRows
    }

    var rows = []
    for (var i = 0; i < item.windows.length; i++) {
      var w = item.windows[i]
      rows.push({ kind: "window", label: windowLabel(w), toplevel: w, current: w.activated })
    }
    if (rows.length > 0) rows.push({ kind: "separator" })

    if (item.entry) rows.push({ kind: "action", label: "New Window", act: "new" })
    if (!isFixed(item.key)) {
      if (item.pinned) rows.push({ kind: "action", label: "Remove from Dock", act: "unpin" })
      else if (item.entry) rows.push({ kind: "action", label: "Keep in Dock", act: "pin" })

      // Position 0 belongs to Files, so the app right after it can't move left.
      var index = root.layout.indexOf(item.key)
      if (index > 1) rows.push({ kind: "action", label: "Move Left", act: "left" })
      if (index !== -1 && index < root.layout.length - 1) rows.push({ kind: "action", label: "Move Right", act: "right" })
    }

    if (item.windows.length > 0) {
      rows.push({ kind: "separator" })
      rows.push({ kind: "action", label: "Quit", act: "quit" })
    }
    return rows
  }

  // Second page of a folder's menu ("Open as" / "Display as"), slid in like the submenus
  // in the Files app's menus.
  function folderSubmenuRows(folder, page) {
    var current = page === "openAs" ? openAsFor(folder) : displayAsFor(folder)
    return [
      { kind: "back", label: page === "openAs" ? "Open as" : "Display as" },
      { kind: "separator" },
      { kind: "choice", label: "Stack", key: page, value: "stack", checked: current === "stack" },
      { kind: "choice", label: "Folder", key: page, value: "folder", checked: current === "folder" }
    ]
  }

  // Right-clicking the divider, like the macOS dock.
  function dockMenuRows() {
    return [
      { kind: "action", label: root.autoHide ? "Turn Hiding Off" : "Turn Hiding On", act: "toggle-hide" },
      { kind: "separator" },
      { kind: "action", label: "Dock Settings…", act: "settings" }
    ]
  }

  // Shown in place of the Trash menu when "Empty Trash…" is chosen; nothing is deleted
  // until "Empty Trash" is clicked here.
  function emptyTrashConfirmRows() {
    var n = root.trashCount
    return [
      { kind: "text", label: "Permanently erase " + n + (n === 1 ? " item" : " items") + " in the Trash?" },
      { kind: "text", label: "You can't undo this.", secondary: true },
      { kind: "separator" },
      { kind: "action", label: "Cancel", act: "cancel" },
      { kind: "action", label: "Empty Trash", act: "empty", danger: true }
    ]
  }

  function runRow(row, item) {
    if (row.kind === "window") {
      row.toplevel.activate()
      return
    }
    switch (row.act) {
      case "toggle-hide": setSetting("autoHide", !root.autoHide, true); break
      case "empty": emptyTrash(); break
      case "open": openFolder(item); break
      case "new": launch(item); break
      case "unpin": unpin(item.key); break
      case "pin": pin(item.key); break
      case "left": move(item.key, -1); break
      case "right": move(item.key, 1); break
      case "quit": quit(item); break
    }
  }

  // ------------------------------------------------------------ one dock per screen
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win

      required property var modelData
      screen: modelData

      anchors { left: true; right: true; bottom: true }
      // The window is always as tall as the largest dock needs, whatever the current size.
      // Resizing a layer window is a round trip with the compositor, and while it's in flight
      // the bottom-anchored dock gets drawn for one height in a window of another, so it
      // visibly jumps. With a fixed height, resizing the dock (divider, slider) never resizes
      // the window. The extra space is transparent and takes no input (see mask).
      implicitHeight: dockHeightFor(72) + root.edgeMargin + root.hoverSlack
      color: "transparent"
      // With hiding off the dock is always visible, so windows make room for it
      // (like macOS); with hiding on it floats over them.
      exclusionMode: root.autoHide ? ExclusionMode.Ignore : ExclusionMode.Normal
      exclusiveZone: root.autoHide ? 0 : win.reservedHeight

      // Space reserved for the dock when hiding is off. Updated shortly after the dock's
      // height settles, so dragging the Size slider doesn't re-lay out every window on
      // each step.
      property int reservedHeight: 0
      Timer {
        id: reservedHeightTimer
        interval: 250
        onTriggered: win.reservedHeight = dockBox.height + root.edgeMargin
      }
      Connections {
        target: dockBox
        function onHeightChanged() { reservedHeightTimer.restart() }
      }
      Component.onCompleted: reservedHeightTimer.restart()
      WlrLayershell.namespace: root.slug           // the blur rule matches this name
      // Overlay, so it can slide up over full-screen apps too (like macOS).
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      property bool revealed: !root.autoHide

      // A full-screen app has focus on this screen: the dock always auto-hides then (even
      // with hiding off), so it never sits on top of a video or game, but it still slides
      // up when the pointer hits the bottom edge.
      readonly property var activeToplevel: ToplevelManager.activeToplevel
      readonly property bool fullscreenHere: {
        var t = win.activeToplevel
        if (!t || !t.fullscreen) return false
        var screens = t.screens
        if (!screens || screens.length === 0) return true
        for (var i = 0; i < screens.length; i++) if (screens[i] === win.screen) return true
        return false
      }
      readonly property bool hidingNow: root.autoHide || fullscreenHere

      // The dock is switched off entirely (no edge trigger, nothing open) while a window
      // from root.neverShowOver has focus.
      readonly property bool suppressed: !!win.activeToplevel
        && root.neverShowOver.indexOf(String(win.activeToplevel.appId)) !== -1
      onSuppressedChanged: {
        if (win.suppressed) {
          win.closeMenu()
          win.closeStack()
          win.settingsOpen = false
          win.revealed = false
          win.tipText = ""
        } else if (!win.hidingNow) {
          win.revealed = true
        }
      }
      onHidingNowChanged: {
        if (!win.hidingNow) win.revealed = true
        else hideTimer.restart()
      }
      property bool settingsOpen: false
      property bool menuOpen: false
      property Item menuTarget: null
      property var menuItem: null
      property bool menuIsFolder: false
      property bool menuConfirming: false
      property var menuList: []
      property Item tipTarget: null
      property string tipText: ""

      // Drag to reorder (indexes into root.items; -1 when not dragging)
      property int dragFrom: -1
      property int dragTo: -1
      property real dragX: 0
      property string dragIcon: ""
      property int dragWidth: 0               // slot width of the dragged icon
      // Set for the moment a pulled-out icon is removed: everything is already where it
      // belongs, so the slide-aside offsets are dropped without animating.
      property bool snapShifts: false
      readonly property Item dragRow: row

      // Drag out to remove (pinned apps other than Files): pull the icon this far above
      // the dock and "Remove" appears; letting go there removes it from the dock.
      property real dragSceneX: 0
      property real dragSceneY: 0
      property bool dragRemovable: false
      readonly property int removeDistance: 40
      readonly property bool dragRemoving: dragFrom !== -1 && dragRemovable
        && (zone.y + dockBox.y - dragSceneY) > removeDistance

      // Files dragged over the dock from another app (Files, browser, ...)
      property int dropDepth: 0

      // Divider resizing: while dragging, the dock is only scaled visually (cheap: no
      // re-layout, no window resize per step); the real size is applied once on release.
      property int resizePreview: 0          // previewed icon size; 0 = not resizing

      // The dock's exact width and height at a given icon size (same arithmetic as the real
      // layout), so the preview lands exactly where the real dock will be on release.
      function dockWidthFor(size) {
        var width = root.folders.length > 0 ? root.dividerWidthFor(size) : 0
        for (var i = 0; i < root.dockSources.length; i++) width += root.slotWidthFor(root.dockSources[i], size)
        return width + root.sidePadFor(size) * 2
      }
      function dockHeightFor(size) { return root.slotHeightFor(size) + (root.padFor(size) + 1) * 2 }
      readonly property real previewScaleX: resizePreview > 0 ? dockWidthFor(resizePreview) / dockWidthFor(root.iconSize) : 1
      readonly property real previewScaleY: resizePreview > 0 ? dockHeightFor(resizePreview) / dockHeightFor(root.iconSize) : 1

      // Set while a resize is being applied, so the width animation (meant for apps opening
      // and closing) doesn't start from the old width and make the dock jump.
      property bool applyingResize: false

      // Hidden: only a thin strip at the bottom edge takes the pointer.
      // Shown: the dock plus some slack around it, down to the screen edge.
      // Everything else clicks through to the windows below.
      mask: win.suppressed ? noInputRegion : (win.revealed ? zoneRegion : hotspotRegion)
      Region { id: noInputRegion }
      Region { id: zoneRegion; item: zone }
      Region { id: hotspotRegion; item: hotspot }

      function reveal() {
        if (win.suppressed) return
        if (!win.revealed) {
          root.refreshTrash()
          root.refreshFolders()
          root.refreshTerminal()
        }
        win.revealed = true
        hideTimer.restart()
      }

      function openMenu(button, item, isFolder) {
        win.tipText = ""
        win.menuTarget = button
        win.menuItem = item
        win.menuIsFolder = isFolder
        win.menuConfirming = false
        if (isFolder && root.isTrash(item)) root.refreshTrash()
        win.menuList = root.menuRows(item, isFolder)
        win.menuOpen = true
      }

      function openDockMenu(divider) {
        win.tipText = ""
        win.menuTarget = divider
        win.menuItem = { kind: "dock" }
        win.menuIsFolder = false
        win.menuConfirming = false
        win.menuList = root.dockMenuRows()
        win.menuOpen = true
      }

      function openSettings() {
        win.tipText = ""
        win.revealed = true
        win.settingsOpen = true
      }

      function closeSettings() {
        win.settingsOpen = false
        hideTimer.restart()
      }

      // Swap the menu's rows with a short slide: dir 1 = into a submenu, -1 = back out.
      function setMenuPage(rows, dir) {
        win.menuList = rows
        menuSlide.from = 24 * dir
        menuSlideAnimation.restart()
        // The page may be wider or narrower; keep the menu centered over its icon.
        Qt.callLater(function() { if (win.menuOpen) menu.anchor.updateAnchor() })
      }

      // ---------------------------------------------------------- folder stack
      property bool stackOpen: false
      property Item stackTarget: null
      property var stackFolder: null

      function folderClicked(button, folder) {
        // Clicking the folder again closes its open stack.
        if (win.stackOpen && win.stackFolder && win.stackFolder.path === folder.path) {
          win.closeStack()
          return
        }
        if (root.openAsFor(folder) === "stack") win.openStack(button, folder)
        else root.openFolder(folder)
      }

      function openStack(button, folder) {
        win.tipText = ""
        win.stackTarget = button
        win.stackFolder = folder
        root.refreshFolders()
        win.stackOpen = true
      }

      // byOutsideClick: closed by clicking elsewhere, so that same click is ignored by the
      // dock (see justClosedPopup); not when closed by choosing something in it.
      function closeStack(byOutsideClick) {
        if (win.stackOpen && byOutsideClick) win.popupClosedAt = Date.now()
        win.stackOpen = false
        hideTimer.restart()
      }

      // Menu rows that change the menu itself instead of running an action.
      function handleMenuRow(row) {
        if (row.disabled || row.kind === "text" || row.kind === "separator") return
        if (row.kind === "submenu") {
          win.setMenuPage(root.folderSubmenuRows(win.menuItem, row.page), 1)
          return
        }
        if (row.kind === "back") {
          win.setMenuPage(root.menuRows(win.menuItem, true), -1)
          return
        }
        if (row.kind === "choice") {
          var folder = win.menuItem
          win.closeMenu()
          root.setFolderOption(folder.path, row.key, row.value)
          return
        }
        if (row.act === "empty-ask") {
          win.menuConfirming = true
          win.menuList = root.emptyTrashConfirmRows()
          return
        }
        if (row.act === "settings") {
          win.closeMenu()
          win.openSettings()
          return
        }
        var item = win.menuItem
        win.closeMenu()
        if (row.act !== "cancel") root.runRow(row, item)
      }

      // Trash count arrives asynchronously; refresh the open Trash menu when it does.
      Connections {
        target: root
        function onTrashCountChanged() {
          if (win.menuOpen && win.menuIsFolder && !win.menuConfirming && root.isTrash(win.menuItem))
            win.menuList = root.menuRows(win.menuItem, true)
        }
        // Apps opening or closing mid-drag rebuild the icons; drop the drag rather than
        // move the wrong one.
        function onItemsChanged() {
          if (win.dragFrom !== -1) win.cancelDrag()
        }

      }

      function beginDrag(index, icon) {
        var item = root.items[index]
        win.tipText = ""
        win.dragIcon = icon
        win.dragWidth = root.slotWidthFor(root.iconSource(icon), root.iconSize)
        // Running apps (even pinned ones) only slide sideways; unpin those from their menu.
        win.dragRemovable = !!item && item.pinned && !root.isFixed(item.key) && item.windows.length === 0
        win.dragFrom = index
        win.dragTo = index
      }

      // `point` is in the app row's coordinates.
      function updateDrag(point) {
        var scene = row.mapToItem(null, point.x, point.y)
        win.dragSceneX = scene.x
        win.dragSceneY = scene.y
        win.dragX = point.x
        // Slots can differ in width, so try the dragged icon at each position among the
        // others and pick the one whose middle is closest to the pointer.
        var best = 0
        var bestDistance = Infinity
        var left = 0
        var k = 0
        for (var i = 0; i <= root.items.length; i++) {
          if (i === win.dragFrom) continue
          var distance = Math.abs(point.x - (left + win.dragWidth / 2))
          if (distance < bestDistance) { bestDistance = distance; best = k }
          if (i < root.items.length) left += root.slotWidthFor(root.iconSource(root.items[i].icon), root.iconSize)
          k++
        }
        // Slot 0 is Files' permanent spot; dragged apps can land anywhere after it.
        win.dragTo = Math.max(1, Math.min(root.items.length - 1, best))
      }

      function endDrag() {
        var from = win.dragFrom
        var to = win.dragTo
        var removing = win.dragRemoving
        if (removing) {
          poof.play(dragGhost.x, dragGhost.y, dragGhost.source)
          win.snapShifts = true
          Qt.callLater(function() { win.snapShifts = false })
        }
        win.dragFrom = -1
        win.dragTo = -1
        if (from !== -1 && from < root.items.length) {
          var key = root.items[from].key
          if (removing) root.unpin(key)
          else if (to !== from) root.moveTo(key, to)
        }
        hideTimer.restart()
      }

      function cancelDrag() {
        win.dragFrom = -1
        win.dragTo = -1
        hideTimer.restart()
      }

      function dropEnter() {
        win.dropDepth += 1
        win.reveal()
      }

      function dropLeave() {
        win.dropDepth = Math.max(0, win.dropDepth - 1)
        hideTimer.restart()
      }

      function closeMenu(byOutsideClick) {
        if (win.menuOpen && byOutsideClick) win.popupClosedAt = Date.now()
        win.menuOpen = false
        hideTimer.restart()
      }

      // When a menu is dismissed by clicking elsewhere on the dock, that same click
      // arrives right after; icons use this to ignore it.
      property real popupClosedAt: 0
      function justClosedPopup() {
        return Date.now() - win.popupClosedAt < 300
      }

      function showTip(button, text) {
        if (win.menuOpen || win.stackOpen) return
        win.tipTarget = button
        win.tipText = text
      }

      function hideTip(button) {
        if (win.tipTarget === button) win.tipText = ""
      }

      Timer {
        id: hideTimer
        // At least 150 ms even for "Immediately": with 0 the dock could hide in the instant
        // between the pointer leaving the edge strip and entering the dock.
        interval: Math.max(150, root.hideDelay)
        onTriggered: {
          if (!win.hidingNow || win.settingsOpen) return
          if (zoneHover.hovered || hotspot.containsMouse || win.menuOpen || win.stackOpen) return
          if (win.dragFrom !== -1 || win.dropDepth > 0 || dividerMouse.resizing) return
          win.revealed = false
          win.tipText = ""
        }
      }

      // Hover area: the dock plus slack on each side and the gap below it.
      Item {
        id: zone

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: dockBox.width + root.hoverSlack * 2
        height: dockBox.height + root.edgeMargin + root.hoverSlack

        HoverHandler {
          id: zoneHover
          onHoveredChanged: if (!hovered) hideTimer.restart()
        }

        // Keeps the dock up while files are dragged over its gaps and edges.
        DropArea {
          anchors.fill: parent
          keys: ["text/uri-list"]
          onEntered: win.dropEnter()
          onExited: win.dropLeave()
          onDropped: function(drop) { win.dropLeave() }
        }

        // The dock's fill and shadow, drawn separately so the icons themselves aren't
        // clipped by the shadow effect (a bouncing icon can rise above the dock).
        Rectangle {
          x: dockBox.x
          y: dockBox.y
          width: dockBox.width
          height: dockBox.height
          transform: Scale {
            origin.x: dockBox.width / 2
            origin.y: dockBox.height
            xScale: win.previewScaleX
            yScale: win.previewScaleY
          }
          color: Util.alpha(root.background, 0.65)   // translucent; Hyprland blurs what shows through
          radius: root.dockRadius

          layer.enabled: true
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.45)
            shadowBlur: 0.7
            shadowVerticalOffset: 2
          }
        }

        Rectangle {
          id: dockBox

          anchors.horizontalCenter: parent.horizontalCenter
          y: win.revealed ? root.hoverSlack : zone.height + root.shadowPad
          // Same arithmetic as the row's own layout (see dockWidthFor), so it updates in the
          // same instant as the icons. While an icon is pulled out to remove, the dock
          // already shrinks around the gap it leaves.
          width: win.dockWidthFor(root.iconSize) - (win.dragRemoving ? win.dragWidth : 0)
          height: row.implicitHeight + (root.dockPad + 1) * 2
          color: "transparent"
          border.color: root.hairline
          border.width: 1
          radius: root.dockRadius
          transform: Scale {
            origin.x: dockBox.width / 2
            origin.y: dockBox.height
            xScale: win.previewScaleX
            yScale: win.previewScaleY
          }

          Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          Behavior on width {
            enabled: !win.applyingResize && !win.snapShifts
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
          }


          Row {
            id: row
            // Pinned to the left padding rather than centered, so a dock that shrinks while
            // an icon is pulled out closes in from both ends evenly.
            x: root.sidePadFor(root.iconSize)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Repeater {
              model: root.items
              delegate: DockButton {
                required property var modelData
                required property int index
                dock: root
                window: win
                item: modelData
                slot: index
              }
            }

            // Divider between apps and folders, with breathing room like the macOS dock.
            // Right-click it for Turn Hiding On/Off and Dock Settings….
            Item {
              id: divider
              visible: root.folders.length > 0
              // Wide enough that the gap on each side of the line matches the gap between two
              // icons, like macOS (see dividerWidthFor).
              width: root.dividerWidthFor(root.iconSize)
              // Slides left with the folders while an app is being pulled out to remove.
              transform: Translate {
                x: win.dragRemoving ? -win.dragWidth : 0
                Behavior on x {
                  enabled: !win.snapShifts
                  NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
              }
              height: root.slotHeightFor(root.iconSize)
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                // On a whole pixel (centering a 1 px line in an even width would blur it).
                x: Math.floor((parent.width - 1) / 2)
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: Math.round(root.iconSize * 1.03)      // macOS: a bit taller than the icons
                radius: 0.5
                color: Util.alpha(root.foreground, dividerMouse.containsMouse ? 0.45 : 0.22)
              }

              // Right-click: the dock menu. Left-drag up/down (when "dividerResize" is on):
              // resize the dock live, in the Size slider's steps; saved on release.
              MouseArea {
                id: dividerMouse
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                acceptedButtons: root.dividerResize ? (Qt.LeftButton | Qt.RightButton) : Qt.RightButton
                cursorShape: root.dividerResize ? Qt.SizeVerCursor : Qt.ArrowCursor
                property bool suppressClick: false
                property bool resizing: false
                property real startScreenY: 0
                property int startSize: 0

                // Pointer height on screen. The dock window grows and shrinks while resizing,
                // so the pointer's position inside it isn't stable; on screen it is.
                function screenY(m) {
                  return mapToItem(null, m.x, m.y).y + (win.screen.height - win.height)
                }

                onPressed: function(m) {
                  suppressClick = win.justClosedPopup()
                  if (m.button === Qt.LeftButton && !suppressClick) {
                    resizing = true
                    startScreenY = screenY(m)
                    startSize = root.iconSize
                    win.resizePreview = root.iconSize
                  }
                }
                onPositionChanged: function(m) {
                  if (!resizing) return
                  // Up = bigger. One 4 px size step per 4 px dragged.
                  var size = startSize + Math.round((startScreenY - screenY(m)) / 4) * 4
                  win.resizePreview = Math.max(32, Math.min(72, size))
                }
                function finishResize() {
                  if (!resizing) return
                  resizing = false
                  var size = win.resizePreview
                  if (size > 0 && size !== root.iconSize) {
                    win.applyingResize = true
                    root.setSetting("iconSize", size, true)
                    win.resizePreview = 0
                    Qt.callLater(function() { win.applyingResize = false })
                  } else {
                    win.resizePreview = 0
                  }
                  hideTimer.restart()
                }
                onReleased: function(m) { finishResize() }
                onCanceled: finishResize()
                onClicked: function(m) {
                  if (m.button === Qt.RightButton && !suppressClick) win.openDockMenu(divider)
                }
              }
            }

            Repeater {
              model: root.folders
              delegate: DockButton {
                required property var modelData
                dock: root
                window: win
                item: modelData
                isFolder: true
              }
            }
          }
        }
      }

      // The dragged icon, its "Remove" label and the removal "poof" are drawn in their own
      // full-screen, see-through overlay that exists only during a drag. It ignores the
      // pointer and isn't blurred, so the dock window itself never resizes mid-drag (which
      // made dragging jittery) and the icon can be pulled anywhere on screen.
      PanelWindow {
        id: dragLayer
        screen: win.screen
        visible: win.dragFrom !== -1 || poof.visible
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: root.slug + "-drag"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        // Dock-window coordinates -> this overlay's (both are anchored to the bottom).
        readonly property real offsetY: height - win.height

        Image {
          id: dragGhost
          visible: win.dragFrom !== -1
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: root.iconSourceSize
          sourceSize.height: root.iconSourceSize
          source: root.iconSource(win.dragIcon)
          smooth: true
          readonly property real dockLeft: zone.x + dockBox.x
          readonly property real restingY: zone.y + dockBox.y + row.y + root.itemPad - 1
          // Keeps the visible artwork (not the padded square) centered under the pointer.
          readonly property real artOffset: root.artOffsetFor(root.iconSource(win.dragIcon), root.iconSize)
          x: win.dragRemoving
            ? win.dragSceneX - width / 2 + artOffset
            : Math.max(dockLeft, Math.min(dockLeft + dockBox.width - width, win.dragSceneX - width / 2 + artOffset))
          y: dragLayer.offsetY + (win.dragRemovable ? Math.min(restingY, win.dragSceneY - height / 2) : restingY)
          opacity: win.dragRemoving ? 0.7 : 1
        }

        // "Remove" label above the icon once it's far enough out.
        Rectangle {
          visible: win.dragRemoving
          width: removeLabel.implicitWidth + 20
          height: removeLabel.implicitHeight + 10
          x: dragGhost.x + dragGhost.width / 2 - width / 2
          y: dragGhost.y - height - 6
          radius: root.tipRadius
          color: root.surface
          border.color: root.hairline
          border.width: 1
          Text {
            id: removeLabel
            anchors.centerIn: parent
            text: "Remove"
            color: Commons.Color.popups.text
            font.family: root.uiFont
            font.pixelSize: root.uiFontSize - 1
          }
        }

        // Removal "poof": the icon puffs up and fades where it was let go.
        Image {
          id: poof
          visible: false
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: root.iconSourceSize
          sourceSize.height: root.iconSourceSize
          smooth: true

          function play(px, py, src) {
            poof.source = src
            poof.x = px
            poof.y = py
            poof.scale = 1
            poof.opacity = 0.7
            poof.visible = true
            poofAnimation.restart()
          }

          ParallelAnimation {
            id: poofAnimation
            NumberAnimation { target: poof; property: "scale"; to: 1.6; duration: 220; easing.type: Easing.OutQuad }
            NumberAnimation { target: poof; property: "opacity"; to: 0; duration: 220; easing.type: Easing.OutQuad }
            onFinished: poof.visible = false
          }
        }
      }

      // Thin strip along the bottom edge that summons the dock. Declared after the dock so
      // it sits on top and always sees the pointer; it also counts as "still hovering".
      MouseArea {
        id: hotspot
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 2
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: win.reveal()
        onExited: hideTimer.restart()
      }

      // Measures icons' visible extents for even spacing (see "spacing" above): draws each
      // icon off-screen and finds where its opaque pixels start and end. Only rows in the
      // middle half of the artwork count, so a speech-bubble tail or a shadow along the
      // bottom doesn't widen the slot. One measurer is enough, on the first screen.
      Canvas {
        id: iconMeasurer
        visible: false
        width: root.iconSourceSize
        height: root.iconSourceSize
        renderStrategy: Canvas.Immediate
        readonly property bool active: win.screen === Quickshell.screens[0]
        property string job: ""

        function next() {
          if (!active || job !== "" || root.measureQueue.length === 0) return
          job = root.measureQueue[0]
          measureTimeout.restart()
          loadImage(job)
          if (isImageLoaded(job)) requestPaint()
          else if (isImageError(job)) done(false)
        }

        function done(extent) {
          measureTimeout.stop()
          var src = job
          unloadImage(src)
          job = ""
          root.finishMeasurement(src, extent)
          Qt.callLater(next)
        }

        onImageLoaded: if (job !== "") {
          if (isImageLoaded(job)) requestPaint()
          else if (isImageError(job)) done(false)
        }

        onPaint: {
          if (job === "" || !isImageLoaded(job)) return
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          ctx.drawImage(job, 0, 0, width, height)
          var px = ctx.getImageData(0, 0, width, height).data
          var w = width
          var h = height
          function opaque(x, y) { return px[(y * w + x) * 4 + 3] > 64 }
          // Vertical extent first, then the horizontal extent across its middle half.
          var top = -1, bottom = -1
          for (var y = 0; y < h && top === -1; y++)
            for (var x = 0; x < w; x++) if (opaque(x, y)) { top = y; break }
          for (y = h - 1; y >= 0 && bottom === -1; y--)
            for (x = 0; x < w; x++) if (opaque(x, y)) { bottom = y; break }
          if (top === -1) { done(false); return }
          var y0 = top + Math.round((bottom - top) * 0.25)
          var y1 = top + Math.round((bottom - top) * 0.75)
          var left = w, right = -1
          for (y = y0; y <= y1; y++) {
            for (x = 0; x < left; x++) if (opaque(x, y)) { left = x; break }
            for (x = w - 1; x > right; x--) if (opaque(x, y)) { right = x; break }
          }
          done(right < left ? false : { l: left / w, r: (right + 1) / w })
        }

        Connections {
          target: root
          function onMeasureQueueChanged() { iconMeasurer.next() }
        }
        Component.onCompleted: next()

        // An image that never loads (missing file, broken theme) keeps the classic slot.
        Timer {
          id: measureTimeout
          interval: 3000
          onTriggered: if (iconMeasurer.job !== "") iconMeasurer.done(false)
        }
      }

      // Dragging files to the bottom edge also brings the dock up.
      DropArea {
        anchors.fill: hotspot
        keys: ["text/uri-list"]
        onEntered: win.dropEnter()
        onExited: win.dropLeave()
        onDropped: function(drop) { win.dropLeave() }
      }

      // Right-click menu, centered directly above the icon it belongs to.
      // The popup surface is larger than the visible card so the shadow has room;
      // anchor.rect.y compensates so the card itself sits popupGap above the icon.
      PopupWindow {
        id: menu
        visible: win.menuOpen && win.menuTarget !== null
        color: "transparent"
        anchor.item: win.menuTarget
        anchor.rect.x: 0
        anchor.rect.y: root.shadowPad - root.popupGap
        anchor.rect.width: win.menuTarget ? win.menuTarget.width : 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Top
        implicitWidth: menuCard.width + root.shadowPad * 2
        implicitHeight: menuCard.height + root.shadowPad * 2

        Rectangle {
          id: menuCard
          x: root.shadowPad
          y: root.shadowPad
          width: Math.min(320, Math.max(180, menuColumn.implicitWidth)) + 12
          height: menuColumn.implicitHeight + 12
          color: root.surface
          border.color: root.hairline
          border.width: 1
          radius: root.menuRadius

          layer.enabled: true
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.4)
            shadowBlur: 0.6
            shadowVerticalOffset: 2
          }

          Column {
            id: menuColumn
            x: 6
            y: 6
            width: menuCard.width - 12

            // Slide for submenu pages (see win.setMenuPage).
            transform: Translate { id: menuSlide; property real from: 0 }
            ParallelAnimation {
              id: menuSlideAnimation
              NumberAnimation { target: menuSlide; property: "x"; from: menuSlide.from; to: 0; duration: 160; easing.type: Easing.OutCubic }
              NumberAnimation { target: menuColumn; property: "opacity"; from: 0.2; to: 1; duration: 160; easing.type: Easing.OutCubic }
            }

            Repeater {
              model: win.menuList
              delegate: Item {
                id: menuRow
                required property var modelData
                readonly property bool isSeparator: modelData.kind === "separator"
                readonly property bool isWindow: modelData.kind === "window"
                readonly property bool isText: modelData.kind === "text"
                readonly property bool isSubmenu: modelData.kind === "submenu"
                readonly property bool isBack: modelData.kind === "back"
                readonly property bool isChoice: modelData.kind === "choice"
                // Rows with a leading column (check mark or back arrow) indent their label.
                readonly property bool indented: isWindow || isChoice || isBack
                readonly property bool interactive: !isSeparator && !isText && !modelData.disabled

                width: menuColumn.width
                implicitWidth: isSeparator ? 0
                  : label.implicitWidth + (indented ? 34 : 24) + (isSubmenu ? trailing.implicitWidth + 16 : 0)
                height: isSeparator ? 13 : isText ? label.implicitHeight + 8 : 32

                Rectangle {
                  visible: menuRow.isSeparator
                  anchors.verticalCenter: parent.verticalCenter
                  x: 6
                  width: parent.width - 12
                  height: 1
                  color: root.hairline
                }

                Rectangle {
                  visible: menuRow.interactive
                  anchors.fill: parent
                  color: rowMouse.pressed ? Util.alpha(root.foreground, 0.16)
                       : rowMouse.containsMouse ? root.rowHover
                       : "transparent"
                  radius: root.rowRadius
                }

                // Leading column: check mark (focused window, selected choice) or back arrow.
                Text {
                  visible: (menuRow.isWindow && menuRow.modelData.current)
                        || (menuRow.isChoice && menuRow.modelData.checked) || menuRow.isBack
                  anchors.verticalCenter: parent.verticalCenter
                  x: 10
                  text: menuRow.isBack ? "‹" : "✓"
                  color: Commons.Color.popups.text
                  font.family: root.uiFont
                  font.pixelSize: menuRow.isBack ? root.uiFontSize + 4 : root.uiFontSize
                }

                // Submenu rows show the current value and an arrow on the right.
                Text {
                  id: trailing
                  visible: menuRow.isSubmenu
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  text: (menuRow.modelData.value || "") + "   ›"
                  color: Commons.Color.popups.text
                  opacity: 0.6
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                }

                Text {
                  id: label
                  visible: !menuRow.isSeparator
                  anchors.verticalCenter: parent.verticalCenter
                  x: menuRow.indented ? 30 : 12
                  width: Math.min(implicitWidth, menuRow.width - x - 12 - (menuRow.isSubmenu ? trailing.implicitWidth + 16 : 0))
                  elide: menuRow.isText ? Text.ElideNone : Text.ElideRight
                  wrapMode: menuRow.isText ? Text.WordWrap : Text.NoWrap
                  text: menuRow.modelData.label || ""
                  color: menuRow.modelData.danger ? Commons.Color.urgent : Commons.Color.popups.text
                  opacity: menuRow.modelData.disabled ? 0.4 : menuRow.modelData.secondary ? 0.65 : 1
                  font.family: root.uiFont
                  font.pixelSize: menuRow.modelData.secondary ? root.uiFontSize - 1 : root.uiFontSize
                  font.weight: (menuRow.isText && !menuRow.modelData.secondary) || menuRow.isBack ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                  id: rowMouse
                  enabled: menuRow.interactive
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: win.handleMenuRow(menuRow.modelData)
                }
              }
            }
          }
        }
      }

      // A folder opened as a stack (see StackPopup.qml).
      StackPopup {
        id: stackPopup
        dock: root
        window: win
      }

      // Any click outside the stack closes it (declared here, like the menu's: a grab
      // declared inside the popup itself never activated).
      HyprlandFocusGrab {
        active: win.stackOpen
        windows: [stackPopup]
        onCleared: win.closeStack(true)
      }

      // Any click outside the menu closes it, including on the dock itself.
      HyprlandFocusGrab {
        active: win.menuOpen
        windows: [menu]
        onCleared: win.closeMenu(true)
      }

      // Dock Settings dialog: centered on the screen and modal. The rest of the screen is
      // dimmed and ignores clicks; close it with Done or Esc. Changes apply immediately
      // (the dock resizes live underneath) and are saved to the config file.
      PanelWindow {
        id: settingsDialog
        screen: win.screen
        visible: win.settingsOpen
        anchors { top: true; bottom: true; left: true; right: true }
        color: Qt.rgba(0, 0, 0, 0.25)
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: root.slug + "-settings"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        onVisibleChanged: if (visible) settingsCard.forceActiveFocus()

        // Swallow clicks and scrolling outside the dialog.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onWheel: function(w) { w.accepted = true }
        }

        Rectangle {
          id: settingsCard
          anchors.centerIn: parent
          focus: true
          Keys.onEscapePressed: win.closeSettings()
          width: 360
          height: settingsColumn.implicitHeight + 32
          color: root.surface
          border.color: root.hairline
          border.width: 1
          radius: root.menuRadius

          layer.enabled: true
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.4)
            shadowBlur: 0.6
            shadowVerticalOffset: 2
          }

          Column {
            id: settingsColumn
            x: 16
            y: 16
            width: parent.width - 32
            spacing: 14

            Text {
              text: "Dock"
              color: Commons.Color.popups.text
              font.family: root.uiFont
              font.pixelSize: root.uiFontSize + 2
              font.weight: Font.DemiBold
            }

            // Size
            Column {
              width: parent.width
              spacing: 6
              Item {
                width: parent.width
                height: sizeLabel.implicitHeight
                Text {
                  id: sizeLabel
                  text: "Size"
                  color: Commons.Color.popups.text
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                }
                Text {
                  anchors.right: parent.right
                  text: root.iconSize + " px"
                  color: Commons.Color.popups.text
                  opacity: 0.65
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize - 1
                }
              }
              DockSlider {
                dock: root
                width: parent.width
                from: 32
                to: 72
                stepSize: 4
                value: root.iconSize
                onMoved: function(v) { root.setSetting("iconSize", v, false) }
                onReleased: function(v) { root.setSetting("iconSize", v, true) }
              }
            }

            // Resize by dragging the divider
            Item {
              width: parent.width
              height: Math.max(dividerLabel.implicitHeight, dividerSwitch.implicitHeight)
              Text {
                id: dividerLabel
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - dividerSwitch.width - 12
                wrapMode: Text.WordWrap
                text: "Drag the divider to resize"
                color: Commons.Color.popups.text
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: dividerSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.dividerResize
                onToggled: function(on) { root.setSetting("dividerResize", on, true) }
              }
            }

            Rectangle { width: parent.width; height: 1; color: root.hairline }

            // Automatically hide
            Item {
              width: parent.width
              height: Math.max(hideLabel.implicitHeight, hideSwitch.implicitHeight)
              Text {
                id: hideLabel
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - hideSwitch.width - 12
                wrapMode: Text.WordWrap
                text: "Automatically hide and show the Dock"
                color: Commons.Color.popups.text
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: hideSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.autoHide
                onToggled: function(on) { root.setSetting("autoHide", on, true) }
              }
            }

            // Hide delay (only meaningful while hiding is on)
            Column {
              width: parent.width
              spacing: 6
              opacity: root.autoHide ? 1 : 0.4
              Item {
                width: parent.width
                height: delayLabel.implicitHeight
                Text {
                  id: delayLabel
                  text: "Hide delay"
                  color: Commons.Color.popups.text
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                }
                Text {
                  anchors.right: parent.right
                  text: root.hideDelay === 0 ? "Immediately" : (root.hideDelay / 1000).toFixed(1) + " s"
                  color: Commons.Color.popups.text
                  opacity: 0.65
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize - 1
                }
              }
              DockSlider {
                dock: root
                width: parent.width
                from: 0
                to: 2000
                stepSize: 100
                value: root.hideDelay
                enabledLook: root.autoHide
                onMoved: function(v) { root.setSetting("hideDelay", v, false) }
                onReleased: function(v) { root.setSetting("hideDelay", v, true) }
              }
            }

            Rectangle { width: parent.width; height: 1; color: root.hairline }

            // Bounce while opening
            Item {
              width: parent.width
              height: Math.max(animLabel.implicitHeight, animSwitch.implicitHeight)
              Text {
                id: animLabel
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - animSwitch.width - 12
                wrapMode: Text.WordWrap
                text: "Animate opening applications"
                color: Commons.Color.popups.text
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: animSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.animateLaunch
                onToggled: function(on) { root.setSetting("animateLaunch", on, true) }
              }
            }

            // Footer buttons
            Item {
              width: parent.width
              height: 32

              Rectangle {
                anchors.left: parent.left
                width: resetText.implicitWidth + 24
                height: parent.height
                radius: root.rowRadius
                color: resetMouse.pressed ? Util.alpha(root.foreground, 0.16)
                     : resetMouse.containsMouse ? root.rowHover
                     : Util.alpha(root.foreground, 0.06)
                Text {
                  id: resetText
                  anchors.centerIn: parent
                  text: "Reset to Defaults"
                  color: Commons.Color.popups.text
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                }
                MouseArea {
                  id: resetMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.resetSettings()
                }
              }

              Rectangle {
                anchors.right: parent.right
                width: doneText.implicitWidth + 32
                height: parent.height
                radius: root.rowRadius
                color: doneMouse.pressed ? Qt.darker(root.accent, 1.15)
                     : doneMouse.containsMouse ? Qt.lighter(root.accent, 1.08)
                     : root.accent
                Text {
                  id: doneText
                  anchors.centerIn: parent
                  text: "Done"
                  color: root.background
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                  font.weight: Font.DemiBold
                }
                MouseArea {
                  id: doneMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: win.closeSettings()
                }
              }
            }
          }
        }
      }

      // Hover label with the app or folder name, centered above the icon.
      PopupWindow {
        id: tip
        visible: win.revealed && !win.menuOpen && !win.stackOpen && win.tipText !== "" && win.tipTarget !== null
        // Never takes the pointer, so showing it can't make the icon think the pointer left.
        mask: Region {}
        color: "transparent"
        // Positioned against the dock window and recomputed each time it's shown,
        // the same way Omarchy's own bar popups do it.
        anchor.window: win
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.onAnchoring: {
          if (!win.tipTarget) return
          var pos = win.tipTarget.mapToItem(null, 0, 0)
          tip.anchor.rect.x = Math.round(pos.x + win.tipTarget.width / 2 - tip.implicitWidth / 2)
          tip.anchor.rect.y = Math.round(pos.y - tip.implicitHeight + root.shadowPad - root.popupGap)
        }
        implicitWidth: tipCard.width + root.shadowPad * 2
        implicitHeight: tipCard.height + root.shadowPad * 2

        Rectangle {
          id: tipCard
          x: root.shadowPad
          y: root.shadowPad
          width: tipLabel.implicitWidth + 20
          height: tipLabel.implicitHeight + 10
          color: root.surface
          border.color: root.hairline
          border.width: 1
          radius: root.tipRadius

          layer.enabled: true
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.35)
            shadowBlur: 0.5
            shadowVerticalOffset: 1
          }

          Text {
            id: tipLabel
            anchors.centerIn: parent
            text: win.tipText
            color: Commons.Color.popups.text
            font.family: root.uiFont
            font.pixelSize: root.uiFontSize - 1
          }
        }
      }
    }
  }
}
