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
    dividerResize: true,   // drag a divider up/down to resize the dock (like macOS)
    showRecent: true,      // a middle section with running and recently used apps (like macOS)
    showApps: true         // the Apps icon (all apps on a grid), right after the file manager
  })
  property int iconSize: settingDefaults.iconSize
  property bool autoHide: settingDefaults.autoHide
  property int hideDelay: settingDefaults.hideDelay
  property bool animateLaunch: settingDefaults.animateLaunch
  property bool dividerResize: settingDefaults.dividerResize
  property bool showRecent: settingDefaults.showRecent
  property bool showApps: settingDefaults.showApps

  // Look and feel. Shapes follow the GNOME/Adwaita conventions the Files app uses
  // (rounded surfaces, hairline borders, soft shadows); colors follow the Omarchy theme.
  // Spacing and corner rounding scale with the icon size (48 px -> 6 px padding, 16 px corners).
  // Every icon is loaded once at the resolution the largest dock needs (2x for sharpness),
  // so changing the size only scales already-loaded images instead of reloading them.
  readonly property int iconSourceSize: 144
  // Height proportions match the macOS dock (measured from a MacBook Air: at 60 px icons
  // the dock is 86 px tall, like macOS's 85 pt).
  // (Each screen's dock may draw its icons smaller than iconSize to fit; see win.size.)
  readonly property int edgeMargin: 4                  // between the dock and the screen edge
  function radiusFor(size) { return Math.round(size / 3) }
  function padFor(size) { return Math.round(size * 0.1) }
  function slotHeightFor(size) { return Math.round(size) + padFor(size) * 2 }
  readonly property int menuRadius: 12
  readonly property int rowRadius: 6
  readonly property int tipRadius: 6
  readonly property int shadowPad: 12      // room around popups for their shadow
  readonly property int hoverSlack: 12     // extra hover area around the dock, in pixels
  readonly property int popupGap: 8
  readonly property string uiFont: "Adwaita Sans"
  readonly property int uiFontSize: 14
  // Omarchy's colours, read in this one place (the rest of the plugin takes them from here): one
  // it renames or drops falls back to the usual default instead of breaking what is drawn.
  function themeColor(value, fallback) {
    return value === undefined || value === null || String(value) === "" ? fallback : value
  }
  readonly property color foreground: themeColor(Commons.Color.foreground, "#cacccc")
  readonly property color background: themeColor(Commons.Color.background, "#101315")
  readonly property color accent: themeColor(Commons.Color.accent, "#cacccc")
  readonly property color urgent: themeColor(Commons.Color.urgent, "#a55555")
  readonly property color popupText: themeColor(Commons.Color.popups ? Commons.Color.popups.text : undefined, foreground)
  readonly property color surface: Qt.lighter(background, 1.22)   // menus sit slightly above the dock
  readonly property color hairline: Util.alpha(foreground, 0.12)
  readonly property color rowHover: Util.alpha(foreground, 0.10)

  // Windows the dock never appears over, not even from the bottom edge, while they have
  // focus: Omarchy's screensaver is a full-screen terminal window, and nudging the mouse
  // while it runs shouldn't bring the dock up.
  readonly property var neverShowOver: ["org.omarchy.screensaver"]

  // The file manager is the dock's Finder: always first, always pinned, can't be removed or
  // moved. It's the system's default one (the app that opens folders, see "places" below);
  // Omarchy's, Files (Nautilus), until that's known.
  property string fixedApp: "org.gnome.Nautilus"
  property string systemFileManager: ""      // the system's default, once known (see "places")
  readonly property string fileManagerName: {
    var entry = DesktopEntries.byId(root.fixedApp)
    return entry && entry.name ? String(entry.name) : "Files"
  }
  // File managers the dock may have pinned first before the default changed (see normalizePins).
  readonly property var knownFileManagers: ["org.gnome.Nautilus", "thunar", "org.kde.dolphin", "nemo",
    "pcmanfm", "pcmanfm-qt", "caja", "org.xfce.thunar", "folio", "io.github.lgse.Strata", "com.thisisgm.flea", "flea"]

  // The dock's file manager: the system's default; when that isn't known, or isn't installed, the
  // first installed one of the usual ones (Omarchy 4.6 no longer has Nautilus, so the first
  // guess above may not exist). Asked again whenever the installed apps change.
  function resolveFileManager() {
    if (DesktopEntries.applications.values.length === 0) return      // (not loaded yet, or being rescanned)
    var id = root.systemFileManager
    if (!id || !DesktopEntries.byId(id)) {
      id = ""
      for (var i = 0; i < root.knownFileManagers.length; i++) {
        if (DesktopEntries.byId(root.knownFileManagers[i])) { id = root.knownFileManagers[i]; break }
      }
    }
    if (id && id !== root.fixedApp) root.fixedApp = id
  }

  function isFixed(key) {
    return key === root.fixedApp
  }

  // The app launcher's icon (see AppGrid.qml), saved among the pins under this key while
  // it's shown. It starts right after the file manager and moves like a pinned app; it can
  // be pulled out (or turned off in Dock Settings) like on macOS, since Omarchy's Apps
  // shortcut still opens the grid. Turned back on, it returns after the file manager.
  readonly property string appsKey: "vitrin.apps"
  readonly property string appsIcon: "vitrin:apps"
  function isApps(key) { return key === root.appsKey }
  onShowAppsChanged: {
    var normalized = normalizePins(root.pins)
    if (JSON.stringify(normalized) !== JSON.stringify(root.pins)) root.pins = normalized
  }

  // Saved state (see config file)
  property var pins: [fixedApp]
  property var folders: defaultFolders()
  // Extra grouping rules from the config file: { "<window app id>": "<desktop entry id>" }
  // puts that app's windows under another app's icon. Empty by default; terminals are
  // handled automatically (see "terminal" below).
  property var aliases: ({})
  // Apps whose windows are always shown, even where the dock would take them for helpers (see
  // isHelperEntry): ids of windows or desktop entries, from "alwaysShow" in the config file.
  property var alwaysShow: []

  // Session state: the order apps appear in. Pinned apps keep their saved order; apps that
  // aren't pinned are added at the end when they open and removed when they close.
  property var layout: []

  function defaultFolders() {
    return [
      { name: root.downloadsName, icon: "folder-download", path: root.downloadsPath },
      { name: root.trashName, icon: "user-trash", path: "trash:///" }
    ]
  }

  // ------------------------------------------------------------ places
  // The system's file manager, Downloads folder and the Trash's name (localized on many
  // systems), from scripts/default-places.sh; the fallbacks are Omarchy's English defaults.
  property string downloadsPath: "~/Downloads"
  property string downloadsName: "Downloads"
  property string trashName: "Trash"
  property bool placesKnown: false

  Process {
    id: placesFinder
    running: true
    command: ["bash", root.script("default-places.sh")]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).split("\n")
        var fm = lines[0] || ""
        root.systemFileManager = fm
        root.resolveFileManager()
        if (lines[1]) {
          root.downloadsPath = lines[1].indexOf(root.home + "/") === 0 ? "~" + lines[1].slice(root.home.length) : lines[1]
          root.downloadsName = lines[2] || lines[1].split("/").pop()
        }
        if (lines[3]) root.trashName = lines[3]
        root.placesKnown = true
        root.finishFirstRun(false)
      }
    }
  }

  onFixedAppChanged: {
    var normalized = normalizePins(root.pins)
    if (JSON.stringify(normalized) !== JSON.stringify(root.pins)) {
      root.pins = normalized
      if (root.configLoaded) saveConfig()
    }
  }

  // ------------------------------------------------------------ terminal
  // Omarchy opens some terminal windows under its own app id ("org.omarchy.terminal")
  // and others under the terminal's (e.g. "foot"). Both are grouped under the default
  // terminal's icon, and new ones are opened the Omarchy way.
  // The default terminal is whatever Omarchy is set to use (foot, Alacritty, Ghostty,
  // Kitty, ...); see scripts/default-terminal.sh.
  property string terminalApp: ""
  readonly property var knownTerminals: ["foot", "Alacritty", "com.mitchellh.ghostty", "kitty"]

  // The first of these that's installed; failing that, the first app (by id) in this category
  // (a terminal or browser the lists above have never heard of). Entries that aren't meant to be
  // opened by the user, and Omarchy's web apps and link forwarder, don't count.
  function firstInstalled(ids, category) {
    for (var i = 0; i < ids.length; i++) if (DesktopEntries.byId(ids[i])) return ids[i]
    var found = []
    var apps = DesktopEntries.applications.values
    for (var j = 0; j < apps.length; j++) {
      var app = apps[j]
      if (!app || app.noDisplay || (app.categories || []).indexOf(category) === -1) continue
      if (/\s/.test(String(app.id)) || String(app.id) === "omarchy-browser"
          || String(app.execString || "").indexOf("omarchy-launch-webapp") !== -1) continue
      found.push(String(app.id))
    }
    found.sort()
    return found.length > 0 ? found[0] : ""
  }

  // What the system reported as its default terminal (or "") -> the one to use.
  function pickTerminal(reported) {
    return reported && DesktopEntries.byId(reported) ? reported : firstInstalled(root.knownTerminals, "TerminalEmulator")
  }

  // The same for the default browser: Omarchy's forwarder ("omarchy-browser") isn't a browser.
  function pickBrowser(reported) {
    var entry = reported ? DesktopEntries.byId(reported) : null
    if (entry && !entry.noDisplay && reported !== "omarchy-browser") return reported
    return firstInstalled(root.knownBrowsers, "WebBrowser")
  }

  Process {
    id: terminalFinder
    running: true
    command: ["bash", root.script("default-terminal.sh")]
    stdout: StdioCollector {
      onStreamFinished: {
        var id = root.pickTerminal(String(text).trim())
        if (id !== root.terminalApp) root.terminalApp = id
        root.terminalKnown = true
        root.finishFirstRun(false)
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

  // Known by name, or by its desktop entry's category (new file managers keep appearing).
  function isFileManager(id) {
    if (root.knownFileManagers.indexOf(id) !== -1) return true
    var entry = DesktopEntries.byId(id)
    return !!entry && (entry.categories || []).indexOf("FileManager") !== -1
  }

  // Pins saved under another id (an old "org.omarchy.terminal" pin, or an aliased app id)
  // belong to the icon they're grouped under. The file manager always comes first; a
  // different file manager in first place was the fixed one before the default changed,
  // not a pin of the user's, so it goes.
  function normalizePins(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (typeof p !== "string" || p.length === 0) continue
      if (i === 0 && p !== root.fixedApp && root.isFileManager(p)) continue
      var key = root.effectiveAliases[p] || p
      if (out.indexOf(key) === -1) out.push(key)
    }
    var rest = out.filter(function(k) { return k !== root.fixedApp && (root.showApps || k !== root.appsKey) })
    if (root.showApps && rest.indexOf(root.appsKey) === -1) rest.unshift(root.appsKey)
    return [root.fixedApp].concat(rest)
  }

  onTerminalAppChanged: {
    var normalized = normalizePins(root.pins)
    if (JSON.stringify(normalized) !== JSON.stringify(root.pins)) {
      root.pins = normalized
      if (root.configLoaded) saveConfig()    // (before that, the file's own pins are what's normalized)
    }
  }

  // ------------------------------------------------------------ config file
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: function(error) { root.configLoadFailed(error === FileViewError.FileNotFound) }
    onSaveFailed: function(error) {
      console.warn(root.pluginId + ": couldn't save " + root.configPath + " (" + FileViewError.toString(error)
        + "); changes since the last save are kept only until the dock restarts")
    }
  }

  // The file isn't there (first run, or deleted while the dock runs: it starts over), or it is
  // but can't be read (permissions, a folder in its place). The latter must never end up
  // overwritten with defaults: the dock runs on defaults in memory and saves nothing until the
  // file reads again (applyConfig), and one it already has loaded is left as it is.
  function configLoadFailed(missing) {
    if (missing) {
      root.configBroken = false
    } else {
      if (!root.configBroken) console.warn(root.pluginId + ": " + root.configPath + " exists but can't be read. "
        + "Not saving until it can be.")
      root.configBroken = true
      if (root.configLoaded) return
    }
    root.startFirstRun()
  }

  // ------------------------------------------------------------ first run
  // A new dock starts with the file manager, the default terminal and the default browser
  // (each only if installed), then Downloads and Trash. The defaults are looked up
  // asynchronously, so the config is written once all are known (or after firstRunTimeout).
  property bool firstRun: false
  property bool terminalKnown: false
  property string browserApp: ""
  property bool browserKnown: false
  readonly property var knownBrowsers: ["chromium", "firefox", "zen", "google-chrome", "brave-browser",
    "org.mozilla.firefox", "com.brave.Browser"]

  Process {
    id: browserFinder
    // Omarchy's own resolver when present (xdg-settings answers with Omarchy's link
    // forwarder, "omarchy-browser", which isn't a browser), else xdg-settings.
    command: ["bash", "-c", "command -v omarchy-cmd-default-browser >/dev/null && exec omarchy-cmd-default-browser; "
      + "exec xdg-settings get default-web-browser"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.browserApp = root.pickBrowser(String(text).trim().replace(/\.desktop$/, ""))
        root.browserKnown = true
        root.finishFirstRun(false)
      }
    }
  }

  Timer {
    id: firstRunTimer
    interval: 3000
    onTriggered: root.finishFirstRun(true)
  }

  // Also what happens when the config file is deleted while the dock runs: it starts over.
  function startFirstRun() {
    applySettings(root.settingDefaults)
    root.folders = defaultFolders()
    root.aliases = ({})
    root.alwaysShow = []
    root.middle = []
    root.recentQuitAt = ({})
    root.firstRun = true
    browserFinder.running = true
    firstRunTimer.start()
  }

  function finishFirstRun(force) {
    if (!root.firstRun || (!force && !(root.terminalKnown && root.browserKnown && root.placesKnown))) return
    root.firstRun = false
    firstRunTimer.stop()
    root.folders = defaultFolders()
    root.pins = normalizePins([root.fixedApp, root.terminalApp, root.browserApp].filter(function(id) {
      return !!id && !!DesktopEntries.byId(id)
    }))
    root.configLoaded = true
    saveConfig()
  }

  // Set once the config file has been read (or set up on first run): until then, nothing
  // that would save it (like the middle section changing as apps start) may write it.
  property bool configLoaded: false

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
    // The file is there after all (it came back while first-run setup was under way): what it
    // holds is the dock, not the defaults being worked out.
    root.firstRun = false
    firstRunTimer.stop()
    var needsSave = false

    if (cfg.aliases && typeof cfg.aliases === "object" && !Array.isArray(cfg.aliases)) {
      assignIfChanged("aliases", cfg.aliases)
    } else {
      assignIfChanged("aliases", {})        // (removed from the file: the old ones go too)
      needsSave = true
    }

    if (Array.isArray(cfg.alwaysShow)) {
      assignIfChanged("alwaysShow", cfg.alwaysShow.filter(function(id) { return typeof id === "string" && id.length > 0 }))
    } else {
      assignIfChanged("alwaysShow", [])
      needsSave = true
    }

    if (Array.isArray(cfg.folders)) {
      var folders = []
      for (var f = 0; f < cfg.folders.length; f++) {
        var folder = cfg.folders[f]
        if (!folder || typeof folder.path !== "string" || folder.path.length === 0) continue
        if (typeof folder.name !== "string" || folder.name.length === 0) {
          // No name given: use the folder's own name.
          folder = Object.assign({}, folder, { name: isTrash(folder) ? root.trashName
            : expandPath(folder.path).replace(/\/+$/, "").split("/").pop() || folder.path })
        }
        folders.push(folder)
      }
      // The Trash is always the last shortcut (what the move and add code assume).
      var trashAt = folders.findIndex(function(f) { return isTrash(f) })
      if (trashAt !== -1 && trashAt !== folders.length - 1) {
        folders.push(folders.splice(trashAt, 1)[0])
        needsSave = true
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

    // The middle section, in order: [{ key, quitAt }] (quitAt null while the app ran).
    if (Array.isArray(cfg.recent)) {
      var middle = [], quitAt = {}
      for (var r = 0; r < cfg.recent.length; r++) {
        var entry = cfg.recent[r]
        if (!entry || typeof entry.key !== "string" || middle.indexOf(entry.key) !== -1
            || (root.hiddenAppIds.indexOf(entry.key) !== -1 && root.alwaysShow.indexOf(entry.key) === -1)) continue
        middle.push(entry.key)
        if (typeof entry.quitAt === "number") quitAt[entry.key] = entry.quitAt
      }
      assignIfChanged("middle", middle)
      assignIfChanged("recentQuitAt", quitAt)
    }

    if (!applySettings(cfg.settings)) needsSave = true
    root.configLoaded = true
    // (Deferred: the file can be read while the dock is still being set up, and laying it
    // out right then re-enters the window grouping that's being worked out.)
    Qt.callLater(syncLayout)
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
    root.showRecent = bool("showRecent")
    root.showApps = bool("showApps")
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
      dividerResize: root.dividerResize,
      showRecent: root.showRecent,
      showApps: root.showApps
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
    if (root.configBroken || !root.configLoaded) return     // (nothing is saved before the file has been read)
    configFile.setText(JSON.stringify({
      settings: currentSettings(),
      pins: root.pins,
      folders: root.folders,
      recent: root.middle.map(function(k) {
        return { key: k, quitAt: root.recentQuitAt[k] !== undefined ? root.recentQuitAt[k] : null }
      }),
      aliases: root.aliases,
      alwaysShow: root.alwaysShow
    }, null, 2) + "\n")
  }

  // ------------------------------------------------------------ apps & windows
  // Which app (desktop entry) a window belongs to. Most windows match by id; the later
  // steps are fallbacks for apps whose window id doesn't match their entry (and whose entry
  // has no StartupWMClass), e.g. LocalSend: window "org.localsend.localsend_app", entry
  // "localsend.desktop". In order:
  //   1. exact id, Omarchy web apps and terminal apps, Quickshell's fuzzy lookup (certainEntryFor)
  //   2. clues from the window's process (hintEntryFor, see scripts/window-hints.sh)
  //   3. the id's dotted parts (looseEntryFor)
  // Windows of apps launched from the dock are also remembered (see learnFromLaunch), and
  // "aliases" in the config file override all of this.
  function entryFor(appId) {
    if (!appId) return null
    return certainEntryFor(appId) || hintEntryFor(appId) || looseEntryFor(appId) || null
  }

  function certainEntryFor(appId) {
    return DesktopEntries.byId(appId) || webAppEntryFor(appId) || terminalAppEntryFor(appId)
      || DesktopEntries.heuristicLookup(appId) || null
  }

  // Apps that run in a terminal (btop, cliamp, Neovim, ...): Omarchy's shortcuts open them in
  // a terminal window tagged "org.omarchy.<program>" (omarchy-launch-tui), the dock tags them
  // "org.omarchy.<desktop id>" (see scripts/launch.sh). Such a window is the app's, not the
  // terminal's, even though its process is the terminal.
  function terminalAppEntryFor(appId) {
    var m = String(appId).match(/^org\.omarchy\.(.+)$/)
    if (!m) return null
    var byId = DesktopEntries.byId(m[1])
    if (byId && byId.runInTerminal) return byId
    var program = m[1].toLowerCase()
    var apps = DesktopEntries.applications.values
    for (var a = 0; a < apps.length; a++) {
      if (apps[a].runInTerminal && execNameOf(apps[a]) === program) return apps[a]
    }
    return null
  }

  // Words that say nothing about which app something is.
  readonly property var vendorWords: ["org", "com", "net", "io", "dev", "app", "desktop", "github", "gitlab"]
  readonly property var genericWords: ["bin", "lib", "usr", "opt", "share", "program", "libexec", "exe",
    "electron", "java", "python", "python3", "wine", "flatpak", "snap", "client", "gui"]

  // Lowercase words of 3+ letters in a string, minus the meaningless ones.
  function wordsOf(text) {
    return String(text || "").toLowerCase().split(/[^a-z0-9]+/).filter(function(w) {
      return w.length >= 3 && root.vendorWords.indexOf(w) === -1 && root.genericWords.indexOf(w) === -1
    })
  }

  function baseName(path) { return String(path || "").split("/").pop() }
  function dirName(path) { var p = String(path || "").split("/"); return p.length > 1 ? p[p.length - 2] : "" }

  // The program an entry runs: the first word of its Exec line that isn't "env" or a
  // VAR=value, without its folder ("/usr/bin/localsend %U" -> "localsend").
  function execNameOf(entry) {
    var words = String(entry.execString || "").split(/\s+/)
    for (var i = 0; i < words.length; i++) {
      var w = words[i].replace(/^["']|["']$/g, "")
      if (!w || w === "env" || w.indexOf("=") !== -1) continue
      return baseName(w).toLowerCase()
    }
    return ""
  }

  // Step 2: clues from the window's process. The entry it was launched from counts only if
  // it shares a word with the window's id or program, because launch clues are inherited
  // (an app started from a terminal carries the terminal's), and some apps run several
  // windows from one process (LibreOffice's Calc window reports Writer's entry).
  // Otherwise, an entry whose id or program is the window's program.
  property var windowHints: ({})       // app id -> { launched, exe, cmd }, filled in on demand

  function hintEntryFor(appId) {
    var h = root.windowHints[appId]
    if (!h) return null
    var programs = [baseName(h.exe), dirName(h.exe), baseName(h.cmd)]
      .filter(function(n) { return !!n }).map(function(n) { return n.toLowerCase() })
    // (The program's whole path counts: LibreOffice's windows can be "soffice", running
    // /usr/lib/libreoffice/program/soffice.bin, launched from libreoffice-impress.)
    var windowWords = wordsOf(appId).concat(wordsOf(programs.join(" ")), wordsOf(h.exe))
    if (h.launched) {
      var launched = DesktopEntries.byId(h.launched)
      if (launched) {
        var entryWords = wordsOf(launched.id + " " + launched.name + " " + execNameOf(launched))
        for (var w = 0; w < entryWords.length; w++) if (windowWords.indexOf(entryWords[w]) !== -1) return launched
      }
    }
    var apps = DesktopEntries.applications.values
    for (var a = 0; a < apps.length; a++) {
      var id = String(apps[a].id).toLowerCase()
      var exec = execNameOf(apps[a])
      for (var p = 0; p < programs.length; p++) {
        if (programs[p] === id || (exec && programs[p] === exec)) return apps[a]
      }
    }
    return null
  }

  // Asks scripts/window-hints.sh about windows that don't match for certain, one at a time.
  property var hintQueue: []
  Process {
    id: hintFinder
    property string appId: ""
    stdout: StdioCollector {
      onStreamFinished: root.applyHints(hintFinder.appId, text)
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextHint)
    // No answer at all (the script couldn't run): after a moment, the window is shown under
    // its own id instead of waiting for ever.
    onExited: { hintFallback.appId = hintFinder.appId; hintFallback.restart() }
  }
  Timer {
    id: hintFallback
    property string appId: ""
    interval: 500
    onTriggered: if (root.windowHints[appId] === undefined) root.applyHints(appId, "")
  }

  function requestHints(appId) {
    if (root.windowHints[appId] !== undefined || root.hintQueue.indexOf(appId) !== -1) return
    root.hintQueue = root.hintQueue.concat([appId])
    nextHint()
  }

  function nextHint() {
    if (hintFinder.running || root.hintQueue.length === 0) return
    hintFinder.appId = root.hintQueue[0]
    hintFinder.command = ["bash", root.script("window-hints.sh"), hintFinder.appId]
    hintFinder.running = true
  }

  property var reportedUnmatched: ({})
  function applyHints(appId, text) {
    var lines = String(text).split("\n")
    var hints = Object.assign({}, root.windowHints)
    hints[appId] = { launched: lines[0] || "", exe: lines[1] || "", cmd: lines[2] || "" }
    root.windowHints = hints
    root.hintQueue = root.hintQueue.filter(function(id) { return id !== appId })
    // Still no app: say so once, with the fix.
    if (!entryFor(appId) && !root.reportedUnmatched[appId]) {
      root.reportedUnmatched[appId] = true
      console.warn(root.pluginId + ": no app found for windows with id \"" + appId + "\". To fix it, add "
        + "\"aliases\": { \"" + appId + "\": \"<desktop entry id>\" } to " + root.configPath)
    }
  }

  // Step 3: the id's dotted parts, from last to first, also without a trailing
  // "_app"/"-bin"/..., against entry ids and app names.
  function looseEntryFor(appId) {
    var parts = String(appId).toLowerCase().split(".")
    var candidates = []
    for (var i = parts.length - 1; i >= 0; i--) {
      var part = parts[i]
      if (!part || root.vendorWords.indexOf(part) !== -1) continue
      candidates.push(part)
      var stripped = part.replace(/[-_](app|bin|desktop|client|gui)$/, "")
      if (stripped !== part) candidates.push(stripped)
    }
    var apps = DesktopEntries.applications.values
    for (var c = 0; c < candidates.length; c++) {
      var entry = DesktopEntries.byId(candidates[c])
      if (entry) return entry
      for (var a = 0; a < apps.length; a++) {
        if (String(apps[a].name).toLowerCase().replace(/\s+/g, "") === candidates[c]) return apps[a]
      }
    }
    return null
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
    var fallback = themeIcon("application-x-executable")
    if (!name) return fallback
    name = String(name)
    if (name.indexOf("://") !== -1 || name === root.letterIcon || name === root.appsIcon) return name   // already resolved
    if (name.charAt(0) === "/") return Util.fileUrl(name)
    return themeIcon(name) || fallback
  }

  // ------------------------------------------------------------ icon theme
  // Qt reads the icon theme once, when the shell starts, but Omarchy changes it with every
  // theme switch. So the dock finds icons itself (scripts/icon-lookup.py, which follows the
  // freedesktop icon theme spec and keeps running) and watches the icon theme setting: on a
  // change, every icon in use is looked up again and swaps over. Until an icon's first
  // answer arrives (right after startup), Qt's own lookup stands in.
  property var themeIcons: ({})          // icon name -> file URL, "" when no theme has it
  property var iconsWanted: ({})         // names asked for, not answered yet (changed in place)
  property var iconAnswers: ({})         // the batch being answered (changed in place)
  property string iconTheme: ""

  function themeIcon(name) {
    var url = root.themeIcons[name]
    if (url !== undefined) return url
    if (!root.iconsWanted[name]) {
      root.iconsWanted[name] = true
      Qt.callLater(root.askForIcons)
    }
    return Quickshell.iconPath(name, true)
  }

  // The lookup program only runs while there is something to look up: it starts when icons are
  // asked for and stops after a quiet minute (it holds about 17 MB, and icons are asked for in
  // bursts: at startup, when apps come and go, when the theme changes).
  function askForIcons() {
    var names = Object.keys(root.iconsWanted)
    if (names.length === 0) return
    if (!iconLookup.running) {
      if (iconLookup.quickDeaths < 5) iconLookup.running = true      // (asks again once it runs)
      return
    }
    if (iconLookup.idleStop) return                                  // (stopping: asks again once it has)
    root.iconsWanted = ({})
    iconLookup.write(names.join("\n") + "\n@flush\n")
    iconLookupIdle.restart()
  }

  // Everything in use is asked for again: the theme or the installed apps changed.
  function askForAllIcons() {
    var names = Object.keys(root.themeIcons).concat(Object.keys(root.iconsWanted))
    for (var i = 0; i < names.length; i++) root.iconsWanted[names[i]] = true
    root.askForIcons()
  }

  Timer {
    id: iconLookupIdle
    interval: 60000
    onTriggered: {
      if (!iconLookup.running || Object.keys(root.iconsWanted).length > 0) return
      iconLookup.idleStop = true
      iconLookup.running = false
    }
  }

  Process {
    id: iconLookup
    stdinEnabled: true
    command: ["python3", "-I", root.script("icon-lookup.py")]
    property double startedAt: 0
    property int quickDeaths: 0            // stops soon after starting, in a row (see iconToolDied)
    property bool restarted: false
    property bool idleStop: false          // stopped on purpose, for having been idle
    onRunningChanged: if (running) {
      startedAt = Date.now()
      Qt.callLater(root.askForIcons)
      if (restarted) {                       // (a new one after a crash knows nothing: everything in use is asked again)
        restarted = false
        iconRefresh.restart()
      }
    }
    onExited: {
      if (iconLookup.idleStop) {
        iconLookup.idleStop = false
        Qt.callLater(root.askForIcons)       // (anything asked for meanwhile starts it again)
        return
      }
      root.iconToolDied(iconLookup)
    }
    stdout: SplitParser {
      onRead: function(line) {
        if (line === "@done") {
          root.themeIcons = Object.assign({}, root.themeIcons, root.iconAnswers)
          root.iconAnswers = ({})
          return
        }
        var tab = line.indexOf("\t")
        if (tab <= 0) return
        var path = line.slice(tab + 1)
        root.iconAnswers[line.slice(0, tab)] = path ? Util.fileUrl(path) : ""
        if (path) root.resolvedIconFiles[Util.fileUrl(path)] = true
      }
    }
  }

  // Prints "icon-theme: '<name>'" whenever the setting changes.
  Process {
    id: themeMonitor
    running: true
    command: ["gsettings", "monitor", "org.gnome.desktop.interface", "icon-theme"]
    property double startedAt: 0
    property int quickDeaths: 0
    property bool restarted: false
    onRunningChanged: if (running) {
      startedAt = Date.now()
      if (restarted) themeGetter.running = true   // (the theme may have changed while it was down)
    }
    onExited: root.iconToolDied(themeMonitor)
    stdout: SplitParser {
      onRead: function(line) {
        var m = String(line).match(/icon-theme:\s*'([^']*)'/)
        if (m) root.useIconTheme(m[1])
      }
    }
  }

  Process {
    id: themeGetter
    command: ["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"]
    stdout: StdioCollector {
      onStreamFinished: {
        var m = String(text).match(/'([^']*)'/)
        if (m) root.useIconTheme(m[1])
      }
    }
  }

  // The icon lookup and the theme monitor run for as long as the dock does. If one stops, it's
  // started again after a moment; one that keeps stopping right after it starts is left alone.
  function iconToolDied(tool) {
    tool.quickDeaths = Date.now() - tool.startedAt < 10000 ? tool.quickDeaths + 1 : 0
    if (tool.quickDeaths >= 5) {
      console.warn(root.pluginId + ": " + tool.command[0] + " keeps stopping; not starting it again")
      return
    }
    tool.restarted = true
    iconToolsRestart.restart()
  }
  Timer {
    id: iconToolsRestart
    interval: 2000
    onTriggered: {
      if (!iconLookup.running && iconLookup.quickDeaths < 5) iconLookup.running = true
      if (!themeMonitor.running && themeMonitor.quickDeaths < 5) themeMonitor.running = true
    }
  }

  // Apps installed or removed while the dock runs: icons that weren't found may exist now (and
  // removed ones don't), so everything in use is looked up again once the install settles.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { iconRefresh.restart(); iconWarm.restart(); root.resolveFileManager() }
  }
  // The app grid's icons are looked up ahead of time (a moment after the apps are known, and
  // again when they change), so its first opening shows their final files at once: otherwise
  // each icon would show the theme's provisional one and swap to the looked-up file a moment
  // later, which showed as blinking.
  Timer {
    id: iconWarm
    interval: 1000
    running: true
    onTriggered: {
      var entries = DesktopEntries.applications.values
      for (var i = 0; i < entries.length; i++)
        if (entries[i] && !entries[i].noDisplay && entries[i].name) root.iconCandidatesFor(entries[i], String(entries[i].id))
    }
  }
  Timer {
    id: iconRefresh
    interval: 2000
    onTriggered: {
      root.mimeIconCache = ({})
      root.askForAllIcons()
    }
  }

  function useIconTheme(name) {
    if (!name || name === root.iconTheme) return
    root.iconTheme = name
    root.mimeIconCache = ({})               // which names a theme has can differ
    // (A lookup program that isn't running reads the current theme itself when it starts.)
    if (iconLookup.running && !iconLookup.idleStop) iconLookup.write("@theme " + name + "\n")
    root.askForAllIcons()
  }

  // ------------------------------------------------------------ icon fallbacks
  // An app's icon is the first of these that exists and loads (icons that fail to load are
  // found out by the measurer, which marks them false in iconExtents): the entry's Icon=,
  // the same in lowercase, a missing Icon= file's name looked up in the theme, the entry's
  // id, the window id and its parts, then /usr/share/pixmaps (where older apps put icons).
  // Last comes a letter tile (see LetterIcon.qml), so an app is never left without an icon
  // or under the same generic icon as every other unknown app.
  readonly property string letterIcon: "vitrin:letter"

  function iconCandidatesFor(entry, key) {
    var names = []
    var pixmapNames = []
    if (entry) {
      var icon = String(entry.icon || "")
      if (icon) {
        names.push(icon)
        if (icon.charAt(0) === "/") names.push(baseName(icon).replace(/\.[a-z]+$/i, ""))
        else names.push(icon.toLowerCase())
        pixmapNames.push(icon.charAt(0) === "/" ? "" : icon)
      }
      names.push(String(entry.id))
      pixmapNames.push(String(entry.id))
    }
    names.push(String(key))
    var parts = String(key).split(".")
    for (var i = parts.length - 1; i >= 0; i--) {
      if (!parts[i] || root.vendorWords.indexOf(parts[i].toLowerCase()) !== -1) continue
      names.push(parts[i], parts[i].toLowerCase().replace(/[-_](app|bin|desktop|client|gui)$/, ""))
    }
    var urls = []
    function add(url) { if (url && urls.indexOf(url) === -1) urls.push(url) }
    for (var n = 0; n < names.length; n++) {
      if (!names[n]) continue
      if (names[n].charAt(0) === "/") add(Util.fileUrl(names[n]))
      else add(themeIcon(names[n]))
    }
    // Pixmaps only for the entry's own names, and only when the theme lacks them.
    for (var m = 0; m < pixmapNames.length; m++) {
      if (!pixmapNames[m] || themeIcon(pixmapNames[m])) continue
      add("file:///usr/share/pixmaps/" + pixmapNames[m] + ".png")
      add("file:///usr/share/pixmaps/" + pixmapNames[m] + ".svg")
      add("file:///usr/share/pixmaps/" + pixmapNames[m] + ".xpm")
    }
    urls.push(root.letterIcon)
    return urls
  }

  // The first candidate not known to be broken.
  // What an icon Image may show: theme icons at once (the theme lookup only returns icons
  // that exist), image files only once the measurer has loaded them. The measurer loads
  // silently, so a missing file (a fallback candidate, or a stale Icon= path) is skipped
  // without an Image ever trying it and printing "Cannot open" to the shell log.
  function displayableIcon(url) {
    url = String(url || "")
    if (url === root.letterIcon || url === root.appsIcon) return ""
    return url.indexOf("image://") === 0 || root.iconExtents[url] ? url : ""
  }

  // Icon files the lookup found exist, so the app grid's images may load them at once, instead
  // of waiting for the measurer (which takes a moment for the many icons of a first opening).
  property var resolvedIconFiles: ({})
  function gridIcon(url) {
    url = String(url || "")
    if (url === root.letterIcon || url === root.appsIcon) return ""
    return url.indexOf("image://") === 0 || root.resolvedIconFiles[url] || root.iconExtents[url] ? url : ""
  }

  function pickIcon(candidates) {
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] === root.letterIcon || root.iconExtents[candidates[i]] !== false) return candidates[i]
    }
    return root.letterIcon
  }

  // A readable name for a window that matches no app: "org.localsend.localsend_app" ->
  // "Localsend", or the window's title when it's the same name, properly written
  // ("LocalSend").
  function prettyName(appId, windows) {
    var parts = String(appId).split(".").filter(function(p) {
      return p && root.vendorWords.indexOf(p.toLowerCase()) === -1
    })
    var last = (parts.length ? parts[parts.length - 1] : String(appId)).replace(/[-_](app|bin|desktop|client|gui)$/i, "")
    var pretty = last.replace(/([a-z])([A-Z])/g, "$1 $2").split(/[-_\s]+/).filter(function(w) { return !!w })
      .map(function(w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ") || String(appId)
    function squash(t) { return String(t).toLowerCase().replace(/[^a-z0-9]/g, "") }
    var title = windows.length ? String(windows[0].title || "") : ""
    if (title && title.length <= 30 && squash(title) === squash(pretty)) return title
    return pretty
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
  // The letter tile (see LetterIcon.qml) is a rounded square 81% of the icon's width.
  // So is the Apps icon (see AppsIcon.qml).
  property var iconExtents: ({
    "vitrin:letter": { l: 0.095, r: 0.905, L: 0.095, R: 0.905, t: 0.095, b: 0.905, hull: 0.6561 },
    "vitrin:apps": { l: 0.095, r: 0.905, L: 0.095, R: 0.905, t: 0.095, b: 0.905, hull: 0.6561 }
  })
  property var measureQueue: []

  // The gaps and end spaces are set for 52 px icons (the default size) and scale in
  // proportion with the icon size, rounded to whole pixels (15 px at 52 -> 14 at 48, 21 at 72).
  readonly property int spacingBaseSize: 52
  readonly property int baseGap: 15        // between two icons' artwork
  readonly property int baseEnds: 15       // from the dock's edge to the first/last artwork

  // At the Size setting everything lands on whole pixels (exact gaps, crisp icons). A dock
  // shrunk below it to fit the screen (see win.size) uses fractions instead, like macOS, so
  // it fills the space exactly; whole pixels there would make its width jump by up to a
  // slot as apps come and go (all the gaps grow by a pixel at once).
  function fractional(size) { return size < root.iconSize - 0.0001 }
  function px(value, size) { return fractional(size) ? value : Math.round(value) }

  function gapFor(size) { return px(root.baseGap * size / root.spacingBaseSize, size) }
  function endsFor(size) { return px(root.baseEnds * size / root.spacingBaseSize, size) }

  // Every icon's artwork starts this far into its slot, and the rest of the gap follows it,
  // so each gap is the same whole number of pixels even when it's odd (7 + 8 = 15).
  function gapLeftFor(size) { return fractional(size) ? gapFor(size) / 2 : Math.floor(gapFor(size) / 2) }
  function gapRightFor(size) { return gapFor(size) - gapLeftFor(size) }

  // Padding inside the dock's left and right edges (including its 1 px border); the end
  // slots bring the rest of the end space.
  function leftPadFor(size) { return Math.max(1, endsFor(size) - gapLeftFor(size)) }
  function rightPadFor(size) { return Math.max(1, endsFor(size) - gapRightFor(size)) }
  // Slot width for an icon that hasn't been measured yet (or can't be).
  function classicSlotFor(size) { return Math.round(size) + Math.round(size / 8) * 2 }

  // ------------------------------------------------------------ size normalization
  // Icon themes also draw their artwork at different sizes within the square (a document
  // is narrow, some icons fill the whole square), so each icon is scaled to look about as
  // big as the others. The rule is Android Launcher3's: equal outline area (holes filled
  // in), with a slightly larger target for round shapes, which look smaller than squares
  // of the same area. Squares end up about 81% of the square wide, like Apple's icon grid.
  readonly property real squareArea: 375 / 576
  readonly property real circleArea: 380 / 576
  readonly property real maxGrowth: 1.12   // sparse outline icons would otherwise overshoot

  function normScaleFor(src) {
    var e = root.iconExtents[src]
    if (!e || !e.hull) return 1
    var w = e.R - e.L, h = e.b - e.t
    // How square the outline is: 1 for a square, pi/4 for a circle.
    var squareness = e.hull / (w * h)
    var round = Math.PI / 4
    var target = squareness < round ? root.circleArea
      : root.squareArea + (root.circleArea - root.squareArea) * (1 - squareness) / (1 - round)
    return Math.min(Math.sqrt(target / e.hull), root.maxGrowth, 1 / Math.max(w, h))
  }

  // The size an icon is drawn at: its normalized scale applied to the icon size, rounded
  // to whole pixels. Icons are drawn at this exact size on whole-pixel positions (rather
  // than scaled by a fraction), which keeps them sharp; everything below works from it.
  // Of the ideal size and one pixel either way, the one that puts the artwork's left and
  // right edges closest to whole pixels, so they come out crisp and gaps measure exact.
  function drawSizeFor(src, size) {
    var ideal = size * normScaleFor(src)
    if (fractional(size)) return ideal
    var e = root.iconExtents[src]
    if (!e) return Math.round(ideal)
    var best = Math.round(ideal), bestScore = Infinity
    for (var d = Math.round(ideal) - 1; d <= Math.round(ideal) + 1; d++) {
      var score = Math.abs(e.l * d - Math.round(e.l * d)) + Math.abs(e.r * d - Math.round(e.r * d))
        + Math.abs(d - ideal) * 0.01   // tie-break: nearest to the ideal size
      if (score < bestScore) { bestScore = score; best = d }
    }
    return best
  }

  // Where the artwork's visible left edge falls in the drawn icon, and how wide it is,
  // in whole pixels.
  function artLeftFor(src, size) {
    var e = root.iconExtents[src]
    return e ? px(e.l * drawSizeFor(src, size), size) : 0
  }
  function artWidthFor(src, size) {
    var e = root.iconExtents[src]
    var d = drawSizeFor(src, size)
    return e ? px(e.r * d, size) - px(e.l * d, size) : d
  }

  // Slot width for an icon source at a given icon size: its drawn visible width plus one
  // gap. Used for both the real layout and the resize preview, so the two always agree.
  function slotWidthFor(src, size) {
    var e = root.iconExtents[src]
    if (!e) return classicSlotFor(size)
    return artWidthFor(src, size) + gapFor(size)
  }

  // How far to move the drawn icon so its visible middle sits mid-slot, sideways and
  // up/down (whole pixels).
  function artOffsetFor(src, size) {
    var e = root.iconExtents[src]
    return e ? px((0.5 - (e.l + e.r) / 2) * drawSizeFor(src, size), size) : 0
  }
  function artOffsetYFor(src, size) {
    var e = root.iconExtents[src]
    return e && e.hull ? px((0.5 - (e.t + e.b) / 2) * drawSizeFor(src, size), size) : 0
  }

  // Space on each side of the divider line, as a multiple of the gap between two icons,
  // rounded to whole pixels: 21 px beside 15 px gaps (macOS measures about 1.47).
  readonly property real dividerGapRatio: 1.375

  function dividerSideFor(size) { return px(gapFor(size) * root.dividerGapRatio, size) }

  function dividerWidthFor(size) {
    // The icons beside the divider already bring half a gap each; the divider adds the rest
    // plus its 1 px line.
    return 2 * dividerSideFor(size) - gapFor(size) + 1
  }

  // The icon a slot is sized by. A folder shown as a stack is sized by a generic document
  // icon (the shape most piles show) rather than by its current files, so its slot keeps
  // one width as files come and go.
  function slotSourceFor(item, isFolder) {
    // (An empty folder shown as a stack shows its folder icon instead.)
    if (isFolder && root.displayAsFor(item) === "stack" && root.filesFor(item).length > 0)
      return root.iconSource("text-x-generic")
    return isFolder ? root.iconSource(root.folderIconFor(item)) : root.pickIcon(item.icons)
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

  // Measure an icon that isn't a slot of its own (file-type icons in stacks).
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
    var s = String(path)
    return s === "~" || s.indexOf("~/") === 0 ? root.home + s.slice(1) : s
  }

  // Open windows grouped by app: { byKey: { key: [toplevel, ...] }, order: [key, ...] }.
  readonly property var groups: computeGroups(ToplevelManager.toplevels.values, DesktopEntries.applications.values,
    root.effectiveAliases, root.windowHints, root.launcherOf, root.hintClock, root.windowsSettled)

  // A window waits at most this long (ms) for its process to be asked (see computeGroups); the
  // clock ticks while any wait is on, so one that runs out is noticed.
  readonly property int hintWaitMax: 2000
  property int hintClock: 0
  Timer {
    interval: 500
    repeat: true
    running: root.groups.pending
    onTriggered: root.hintClock++
  }

  // Windows that aren't apps to the user, never shown in the dock: Omarchy's screensaver and
  // the webcam overlay it shows over screen recordings.
  readonly property var hiddenAppIds: ["org.omarchy.screensaver", "WebcamOverlay-small",
    "WebcamOverlay-medium", "WebcamOverlay-large"]

  // Windows of an app that are only sometimes in the way, found by the start of their title:
  // omasnap's pinned captures (floating on every workspace) are references, not work in a
  // window; its editor, when set to open as a window, is shown.
  readonly property var hiddenWindows: [{ id: "omasnap", titleStart: "omasnap-pin " }]

  // Whether a window stays out of the dock (an app listed in "alwaysShow" is never hidden).
  // The window's title is only read for an app with a rule about titles: reading it ties the
  // caller to every change of it, and the grouping would otherwise run again each time any
  // window's title changes (a terminal's, a browser tab's).
  function isHiddenWindow(appId, window) {
    if (root.alwaysShow.indexOf(appId) !== -1) return false
    if (root.hiddenAppIds.indexOf(appId) !== -1) return true
    for (var i = 0; i < root.hiddenWindows.length; i++) {
      var rule = root.hiddenWindows[i]
      if (rule.id === appId && String(window && window.title || "").indexOf(rule.titleStart) === 0) return true
    }
    return false
  }

  // An entry marked NoDisplay ("not an app to show") belongs to a helper: the portal's file chooser,
  // previewers, password prompts. Their windows stay out of the dock, as in Omarchy's own. A few
  // such entries are apps you open files in all the same, so their windows stay.
  readonly property var noDisplayApps: ["imv", "imv-dir", "gcr-viewer"]

  function isHelperEntry(entry) {
    if (!entry || !entry.noDisplay) return false
    var id = String(entry.id)
    return root.noDisplayApps.indexOf(id) === -1 && root.pins.indexOf(id) === -1      // (a pin is a choice)
      && root.alwaysShow.indexOf(id) === -1
  }

  // Only for a window that matches its entry for certain (a guess could pick a helper's entry by
  // accident), and not one given an alias in the config file, which is a choice too.
  function isHelperWindow(appId) {
    return root.aliases[appId] === undefined && root.alwaysShow.indexOf(appId) === -1
      && isHelperEntry(certainEntryFor(appId))
  }

  // Said once per window id, in the log, with the way to show such windows after all.
  property var reportedHelpers: ({})
  function reportHelper(appId) {
    if (root.reportedHelpers[appId]) return
    root.reportedHelpers[appId] = true
    console.log(root.pluginId + ": not showing windows with id \"" + appId + "\" (their desktop entry is marked "
      + "NoDisplay, which is for helpers). To show them, add \"" + appId + "\" to \"alwaysShow\" in " + root.configPath)
  }

  // For a key kept in the middle section: a helper's entry id, an id that an alias sends to
  // another app now, or an id no app matches at all (leftovers from before it was known; a click
  // on such an icon starts nothing). Not judged before the list of apps is there.
  function isStaleKey(key) {
    if (isHelperEntry(DesktopEntries.byId(key))) return true
    var to = root.effectiveAliases[key]
    if (to !== undefined && to !== key) return true
    var appsKnown = root.windowsSettled && DesktopEntries.applications.values.length > 0
    return appsKnown && !entryFor(key)
  }

  // Window ids that many apps share, so they say nothing about which app a window is: those of
  // terminal apps added with Omarchy's TUI installer (omarchy-tui-install), e.g. Docker
  // (lazydocker). Such windows go by the desktop entry each was launched from, found per
  // window (see noteSharedWindows): left out until it's known (a moment), so they don't
  // briefly show as an app of their own; without one, they go by their id as usual.
  readonly property var sharedAppIds: ["TUI.tile", "TUI.float"]
  property var launcherOf: ({})          // Hyprland window address -> entry id ("" if none)

  function hyprAddressFor(toplevel) {
    var hypr = Hyprland.toplevels.values
    for (var i = 0; i < hypr.length; i++) if (hypr[i].wayland === toplevel) return String(hypr[i].address)
    return ""
  }

  // ------------------------------------------------------------ hidden windows
  // A window parked on a special workspace is hidden: Omarchy's minimize (Super+M) uses
  // "special:minimized", the scratchpad (Super+Alt+S) "special:scratchpad". Only a dock brings a
  // minimized window back. A special workspace that is on screen (the scratchpad toggled on) shows
  // its windows, so they count as visible. A click on a hidden window's icon or menu row restores
  // it to the workspace in front of the user.
  property var hiddenAddresses: ({})             // Hyprland window address -> true
  property var shownSpecials: ({})               // monitor name -> the special workspace it shows ("" for none)
  property var lastActive: ({})                  // window address -> when it was last focused (higher = later)
  property int activeCounter: 0

  function windowKey(address) { return String(address || "").replace(/^0x/, "") }

  function hyprToplevelFor(toplevel) {
    var hypr = Hyprland.toplevels.values
    for (var i = 0; i < hypr.length; i++) if (hypr[i].wayland === toplevel) return hypr[i]
    return null
  }

  function refreshHidden() {
    var hypr = Hyprland.toplevels.values
    var shown = {}
    for (var m in root.shownSpecials) if (root.shownSpecials[m] !== "") shown[root.shownSpecials[m]] = true
    var map = {}
    for (var i = 0; i < hypr.length; i++) {
      var w = hypr[i].workspace
      var name = w ? String(w.name) : ""
      if (name.indexOf("special:") === 0 && !shown[name]) map[root.windowKey(hypr[i].address)] = true
    }
    if (JSON.stringify(map) !== JSON.stringify(root.hiddenAddresses)) root.hiddenAddresses = map
  }

  function isHidden(toplevel) {
    return !!root.hiddenAddresses[root.windowKey(root.hyprAddressFor(toplevel))]
  }

  // Which special workspaces are on screen, and (once, at the start) when each window was last
  // focused: Hyprland's own focus history, as the first (oldest) entries of lastActive.
  Process {
    id: hyprState
    command: ["bash", "-c", "printf '{\"monitors\":'; hyprctl monitors -j; printf ',\"clients\":'; hyprctl clients -j; printf '}'"]
    stdout: StdioCollector {
      onStreamFinished: {
        var state = null
        try { state = JSON.parse(String(text)) } catch (e) { return }
        var monitors = state.monitors || []
        var clients = state.clients || []
        var shown = {}
        for (var i = 0; i < monitors.length; i++)
          shown[monitors[i].name] = monitors[i].specialWorkspace ? String(monitors[i].specialWorkspace.name || "") : ""
        root.shownSpecials = shown
        for (var j = 0; j < clients.length; j++) {
          var key = root.windowKey(clients[j].address)
          // (negative: before anything focused since the dock started)
          if (root.lastActive[key] === undefined) root.lastActive[key] = -(1 + clients[j].focusHistoryID)
        }
        root.refreshHidden()
      }
    }
  }
  function refreshHyprState() { if (!hyprState.running) hyprState.running = true }

  Timer { id: hiddenRefresh; interval: 120; onTriggered: root.refreshHidden() }
  Timer { id: stateRefresh; interval: 120; onTriggered: root.refreshHyprState() }
  // Hyprland lists its windows a moment after the shell starts, and again as they come and go.
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { hiddenRefresh.restart() }
  }
  Timer {
    interval: 1500
    running: true
    onTriggered: root.refreshHyprState()
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name
      if (n === "movewindowv2" || n === "openwindow" || n === "closewindow" || n === "movewindow") hiddenRefresh.restart()
      else if (n === "activespecial" || n === "activespecialv2" || n === "focusedmon" || n === "monitoraddedv2") stateRefresh.restart()
    }
  }

  // Remember when each window was last the active one (a window Hyprland hasn't told us about
  // yet is tried once more a moment later).
  property var pendingActive: null
  function noteActive(toplevel) {
    var key = root.windowKey(root.hyprAddressFor(toplevel))
    if (key === "") {
      if (root.pendingActive !== toplevel) { root.pendingActive = toplevel; pendingActiveTimer.restart() }
      return
    }
    root.lastActive[key] = ++root.activeCounter
  }
  Timer {
    id: pendingActiveTimer
    interval: 200
    onTriggered: {
      var t = root.pendingActive
      root.pendingActive = null
      if (t && ToplevelManager.activeToplevel === t) {
        var key = root.windowKey(root.hyprAddressFor(t))
        if (key !== "") root.lastActive[key] = ++root.activeCounter
      }
    }
  }
  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() {
      var t = ToplevelManager.activeToplevel
      if (t) root.noteActive(t)
    }
  }

  function recency(toplevel) {
    var v = root.lastActive[root.windowKey(root.hyprAddressFor(toplevel))]
    return v === undefined ? -1e9 : v
  }

  // The window an app was last in, or null when none is known.
  function lastUsedWindow(windows) {
    var best = null
    var bestValue = -1e9
    for (var i = 0; i < windows.length; i++) {
      var v = root.recency(windows[i])
      if (v > bestValue) { best = windows[i]; bestValue = v }
    }
    return best
  }

  // 0: visible on the workspace in front of the user, 1: visible elsewhere, 2: hidden.
  function windowGroup(toplevel) {
    if (root.isHidden(toplevel)) return 2
    var h = root.hyprToplevelFor(toplevel)
    var monitor = Hyprland.focusedMonitor
    if (!h || !h.workspace || !monitor) return 1
    var here = monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    if (h.workspace.id === here) return 0
    return root.shownSpecials[monitor.name] === String(h.workspace.name) ? 0 : 1    // (a scratchpad that is up counts as here)
  }

  // An app's windows in the order of its menu and of repeated clicks: the groups above, each in
  // the order the windows opened.
  function windowsInOrder(windows) {
    var list = []
    for (var i = 0; i < windows.length; i++) list.push({ w: windows[i], group: root.windowGroup(windows[i]), index: i })
    list.sort(function(a, b) { return a.group - b.group || a.index - b.index })
    return list.map(function(e) { return e.w })
  }

  // A hidden window first comes back to the workspace in front of the user, then is focused like
  // any other. The pointer stays where it is: Hyprland's warping is off around both steps.
  Process {
    id: restoreProcess
    property var toplevel: null
    onExited: {
      var t = restoreProcess.toplevel
      restoreProcess.toplevel = null
      if (!t) return
      t.activate()
      root.warpRestoreTarget = t
      warpRestoreTimer.interval = 300
      warpRestoreTimer.restart()
    }
  }

  function bringForward(toplevel, screen) {
    if (!root.isHidden(toplevel)) { root.focusWindow(toplevel, screen); return }
    var monitor = Hyprland.focusedMonitor
    var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var address = root.hyprAddressFor(toplevel)
    if (!(workspace >= 1) || address === "" || restoreProcess.running) { root.focusWindow(toplevel, screen); return }
    if (address.indexOf("0x") !== 0) address = "0x" + address
    restoreProcess.toplevel = toplevel
    restoreProcess.command = ["bash", "-c", "hyprctl dispatch \"$1\"", "vitrin",
      "hl.dsp.window.move({ workspace = \"" + workspace + "\", window = \"address:" + address + "\" })"]
    var start = function() { restoreProcess.running = true }
    if (warpSwitch.running) { start(); return }
    warpSwitch.then = start
    warpSwitch.command = ["bash", root.script("no-warp.sh"), "off"]
    warpSwitch.running = true
  }

  // The entry id a window under a shared id belongs to; null while not known yet, "" if none.
  function sharedKeyFor(toplevel) {
    var address = hyprAddressFor(toplevel)
    var id = address ? root.launcherOf[address] : undefined
    if (id === undefined) return null
    return id && DesktopEntries.byId(id) ? id : ""
  }

  function computeGroups(toplevels, _apps, _aliases, _hints, _launchers, _clock, _settled) {
    var byKey = Object.create(null)      // (no inherited names: an app id can be "constructor")
    var order = []
    var pending = false                  // some windows are left out for now (see sharedAppIds, unmatched ones)
    // Right after startup the app list can still be empty, and every window would look unmatched.
    var entriesMissing = !!_apps && _apps.length === 0 && !root.windowsSettled
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t || !t.appId || root.isHiddenWindow(t.appId, t)) continue
      // A dialog or helper window (one with a parent window) belongs to its top-most
      // parent's app, never shown as an app of its own: e.g. an app's template chooser
      // or file picker that opens under a generic window id.
      var owner = t
      for (var depth = 0; owner.parent && depth < 8; depth++) owner = owner.parent
      var key = ""
      if (root.sharedAppIds.indexOf(owner.appId) !== -1) {
        key = sharedKeyFor(owner)
        if (key === null) { pending = true; continue }
      }
      if (!key) {
        // A window that matches no app for certain waits until its process has been asked
        // (see noteUnmatched). Before that it would sit under its window id for a moment, get
        // that id into the middle section, and leave an icon behind when the answer moves it
        // under its real app (a terminal window opened by a notification, say). It never waits
        // longer than hintWaitMax, whatever happens to the question.
        var id = owner.appId || t.appId
        if (isHelperWindow(id)) continue
        if (entriesMissing) { pending = true; continue }
        var target = root.effectiveAliases[id] || id
        if (!certainEntryFor(target) && root.windowHints[target] === undefined) {
          var since = root.firstSeen[target]
          if (since === undefined || Date.now() - since < root.hintWaitMax) { pending = true; continue }
        }
        key = keyFor(id)
      }
      if (!byKey[key]) {
        byKey[key] = []
        order.push(key)
      }
      byKey[key].push(t)
    }
    return { byKey: byKey, order: order, pending: pending }
  }

  onGroupsChanged: {
    syncLayout()
    // (Just after this update, not during it: both can change what the window grouping
    // depends on, which mid-update would make it re-run itself.)
    Qt.callLater(function() {
      noteUnmatched()
      learnFromLaunch()
    })
    settleLaunching()
  }

  // Windows that don't match an app for certain: ask their process for clues, and note when
  // they first appeared (for learnFromLaunch).
  // Clues are forgotten once all of an id's windows have closed, so the next window with
  // that id is looked at afresh (it may be a different program).
  property var firstSeen: ({})
  // Asks scripts/window-hints.sh which entry each window under a shared id was launched
  // from, one window at a time; forgets closed ones.
  property var launcherQueue: []
  Process {
    id: launcherFinder
    property string address: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var map = Object.assign({}, root.launcherOf)
        map[launcherFinder.address] = String(text).split("\n")[0] || ""
        root.launcherOf = map
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextLauncher)
  }

  function nextLauncher() {
    if (launcherFinder.running) return
    root.launcherQueue = root.launcherQueue.filter(function(a) { return root.launcherOf[a] === undefined })
    if (root.launcherQueue.length === 0) return
    launcherFinder.address = root.launcherQueue[0]
    launcherFinder.command = ["bash", root.script("window-hints.sh"), "--address", launcherFinder.address]
    launcherFinder.running = true
  }

  Timer {
    id: sharedRetry                      // Hyprland can list a new window a moment later
    interval: 250
    onTriggered: root.noteSharedWindows(ToplevelManager.toplevels.values)
  }

  function noteSharedWindows(toplevels) {
    var open = {}
    var missing = false
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t || root.sharedAppIds.indexOf(t.appId) === -1) continue
      var address = hyprAddressFor(t)
      if (!address) { missing = true; continue }
      open[address] = true
      if (root.launcherOf[address] === undefined && root.launcherQueue.indexOf(address) === -1)
        root.launcherQueue = root.launcherQueue.concat([address])
    }
    if (missing) sharedRetry.restart()
    var closed = Object.keys(root.launcherOf).filter(function(a) { return !open[a] })
    if (closed.length > 0) {
      var map = Object.assign({}, root.launcherOf)
      for (var c = 0; c < closed.length; c++) delete map[closed[c]]
      root.launcherOf = map
    }
    nextLauncher()
  }

  function noteUnmatched() {
    var toplevels = ToplevelManager.toplevels.values
    var open = {}
    noteSharedWindows(toplevels)
    for (var i = 0; i < toplevels.length; i++) {
      var appId = toplevels[i] && toplevels[i].appId
      if (!appId || toplevels[i].parent) continue    // grouped under its parent's app
      if (root.isHiddenWindow(appId, toplevels[i])) continue
      if (isHelperWindow(appId)) { reportHelper(appId); continue }
      var target = root.effectiveAliases[appId] || appId
      open[target] = true
      if (certainEntryFor(target)) continue
      if (root.firstSeen[target] === undefined) root.firstSeen[target] = Date.now()
      requestHints(target)
    }
    var stale = Object.keys(root.windowHints).filter(function(id) {
      return !open[id] && root.hintQueue.indexOf(id) === -1
    })
    if (stale.length === 0) return
    var hints = Object.assign({}, root.windowHints)
    for (var s = 0; s < stale.length; s++) {
      delete hints[stale[s]]
      delete root.firstSeen[stale[s]]
      delete root.reportedUnmatched[stale[s]]
    }
    root.windowHints = hints
  }

  // Learning from launches: when the dock is starting exactly one app, and a window that
  // matches no app appears meanwhile, that window belongs to the app being started. Saved
  // under "aliases" in the config file (where it can be corrected), so it matches for
  // certain from then on.
  function learnFromLaunch() {
    var starting = Object.keys(root.launching).filter(function(k) { return !root.groups.byKey[k] })
    if (starting.length !== 1) return
    var since = root.launching[starting[0]].at
    var fresh = root.groups.order.filter(function(k) {
      return !entryFor(k) && root.firstSeen[k] !== undefined && root.firstSeen[k] >= since
    })
    if (fresh.length !== 1 || root.aliases[fresh[0]] !== undefined) return
    var next = Object.assign({}, root.aliases)
    next[fresh[0]] = starting[0]
    console.log(root.pluginId + ": windows with id \"" + fresh[0] + "\" belong to \"" + starting[0]
      + "\" (learned from launching it; saved under \"aliases\" in " + root.configPath + ")")
    root.aliases = next
    saveConfig()
  }
  onPinsChanged: syncLayout()
  onShowRecentChanged: Qt.callLater(syncLayout)

  // ------------------------------------------------------------ sections
  // The dock's apps come in two sections, like macOS with "Show suggested and recent apps":
  // the pinned apps (Files first, then the pins in their saved order), then a divider and
  // the middle section: apps that aren't pinned but are running, or were used recently.
  // The middle section keeps its order: an app that opens joins at the right end; one that
  // quits stays where it is (it just loses its dot) and is remembered as quit at that
  // moment; running it again brings its dot back in place. At most recentMax quit apps stay
  // (running ones don't count): beyond that, the one quit longest ago drops out, from
  // wherever it is. With "showRecent" off there is no divider and quit apps go at once.
  // The middle section is saved under "recent" in the config file.
  readonly property int recentMax: 3
  property var middle: []                // the middle section's keys, in order
  property var recentQuitAt: ({})        // key -> when it quit (ms), for quit apps in it
  readonly property int middleStart: root.layout.length - root.middle.length
  readonly property bool hasMiddle: root.showRecent && root.middle.length > 0

  function inMiddle(key) { return root.middle.indexOf(key) !== -1 }
  function isRecent(key) { return inMiddle(key) && !root.groups.byKey[key] }

  property bool windowsSettled: false
  Timer {
    interval: 1500
    running: true
    onTriggered: { root.windowsSettled = true; root.syncLayout() }
  }

  function syncLayout() {
    var running = root.groups.byKey
    var now = Date.now()
    var pinned = [root.fixedApp].concat(root.pins.filter(function(k) { return k !== root.fixedApp }))
    var quitAt = Object.assign({}, root.recentQuitAt)
    var middle = []
    for (var i = 0; i < root.middle.length; i++) {
      var key = root.middle[i]
      if (pinned.indexOf(key) !== -1 || middle.indexOf(key) !== -1) continue
      if (!running[key] && isStaleKey(key)) continue
      if (running[key]) {
        delete quitAt[key]
      } else {
        if (!root.showRecent) continue
        if (quitAt[key] === undefined) quitAt[key] = now
      }
      middle.push(key)
    }
    // Newly opened apps join at the right end.
    for (var r = 0; r < root.groups.order.length; r++) {
      var opened = root.groups.order[r]
      if (pinned.indexOf(opened) === -1 && middle.indexOf(opened) === -1) middle.push(opened)
    }
    // Over the limit: drop the apps quit longest ago. Not before windows have settled: right
    // after startup the open windows aren't all known yet, and windows left out for a moment
    // (see sharedAppIds) would make their apps look quit too.
    var quit = middle.filter(function(k) { return !running[k] })
    quit.sort(function(a, b) { return quitAt[a] - quitAt[b] })
    var settled = root.windowsSettled && !root.groups.pending
    while (quit.length > root.recentMax && settled) middle.splice(middle.indexOf(quit.shift()), 1)
    for (var k in quitAt) if (middle.indexOf(k) === -1 || running[k]) delete quitAt[k]

    var changed = JSON.stringify(middle) !== JSON.stringify(root.middle)
      || JSON.stringify(quitAt) !== JSON.stringify(root.recentQuitAt)
    if (changed) {
      root.middle = middle
      root.recentQuitAt = quitAt
    }
    var next = pinned.concat(middle)
    if (JSON.stringify(next) !== JSON.stringify(root.layout)) root.layout = next
    if (changed && root.configLoaded) saveConfig()
  }

  // ------------------------------------------------------------ icons on screen
  // The dock's app icons are kept in a model that changes one icon at a time (inserted,
  // moved, or marked as leaving), rather than rebuilt from root.items on every change, so
  // an app opening can grow its slot in and an app closing can shrink its slot away (see
  // DockButton's "appear"), like macOS. Leaving icons stay in the model, marked, until their
  // animation ends. Icons present at startup don't animate.
  ListModel { id: iconModel }
  property bool animateSlots: false
  property var removeInstantly: ({})     // key -> true: no leaving animation (pulled out)
  Timer { interval: 1000; running: true; onTriggered: root.animateSlots = true }

  readonly property var itemsByKey: {
    var map = {}
    for (var i = 0; i < root.items.length; i++) map[root.items[i].key] = root.items[i]
    return map
  }

  function modelIndexOf(key) {
    for (var i = 0; i < iconModel.count; i++) {
      var row = iconModel.get(i)
      if (row.key === key && !row.leaving) return i
    }
    return -1
  }

  function syncIconModel() {
    var target = root.layout
    // Icons no longer in the dock leave (or go at once, when pulled out).
    for (var i = iconModel.count - 1; i >= 0; i--) {
      var row = iconModel.get(i)
      if (row.leaving || target.indexOf(row.key) !== -1) continue
      if (root.removeInstantly[row.key] || !root.animateSlots) iconModel.remove(i)
      else iconModel.setProperty(i, "leaving", true)
    }
    root.removeInstantly = ({})
    // The rest in the dock's order; leaving icons stay where they are among them.
    var at = 0
    for (var t = 0; t < target.length; t++) {
      while (at < iconModel.count && iconModel.get(at).leaving) at++
      var index = modelIndexOf(target[t])
      if (index === -1) iconModel.insert(at, { key: target[t], leaving: false, appearing: root.animateSlots })
      else if (index !== at) iconModel.move(index, at, 1)
      at++
    }
  }

  function finishLeaving(key) {
    for (var i = 0; i < iconModel.count; i++) {
      var row = iconModel.get(i)
      if (row.key === key && row.leaving) { iconModel.remove(i); return }
    }
  }

  onLayoutChanged: syncIconModel()

  readonly property var items: root.layout.map(function(key) {
    if (isApps(key)) return { key: key, entry: null, name: "Apps", icons: [root.appsIcon], pinned: true, windows: [] }
    var entry = DesktopEntries.byId(key) || entryFor(key)
    var windows = root.groups.byKey[key] || []
    return {
      key: key,
      entry: entry,
      name: entry ? entry.name : prettyName(key, windows),
      icons: iconCandidatesFor(entry, key),     // see pickIcon
      pinned: root.pins.indexOf(key) !== -1,
      windows: windows
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
  function activate(item, screen) {
    if (isApps(item.key)) { appGrid.toggle(screen); return }
    var windows = item.windows
    if (windows.length === 0) {
      launch(item)
      return
    }
    // A click on an app that isn't focused goes to the window it was last in, from the first of these
    // groups that has one: visible on the workspace in front of the user, visible elsewhere, hidden.
    // A click while one of its windows is focused moves on through a fixed order (visible windows by
    // workspace, then hidden ones), which doesn't change as the workspace does, so repeated clicks
    // visit every window, hidden ones last.
    var ordered = windowsInOrder(windows)
    var focusedAt = -1
    for (var i = 0; i < windows.length; i++) if (windows[i].activated && !isHidden(windows[i])) focusedAt = i
    var pick = null
    if (focusedAt !== -1) {
      var cycle = []
      for (var c = 0; c < windows.length; c++) {
        var h = hyprToplevelFor(windows[c])
        cycle.push({ w: windows[c], hidden: isHidden(windows[c]) ? 1 : 0, ws: h && h.workspace ? h.workspace.id : 0, index: c })
      }
      cycle.sort(function(a, b) { return a.hidden - b.hidden || a.ws - b.ws || a.index - b.index })
      var at = 0
      for (var k = 0; k < cycle.length; k++) if (cycle[k].w === windows[focusedAt]) at = k
      pick = cycle[(at + 1) % cycle.length].w
    } else {
      pick = ordered[0]
      var group = windowGroup(pick)
      var best = recency(pick)
      for (var j = 1; j < ordered.length && windowGroup(ordered[j]) === group; j++) {
        var v = recency(ordered[j])
        if (v > best) { pick = ordered[j]; best = v }
      }
    }
    bringForward(pick, screen)
  }

  // ------------------------------------------------------------ keeping the pointer
  // Hyprland moves the pointer to the middle of a window it focuses (handy when switching
  // with the keyboard). Switching from the dock with the mouse, the pointer stays where it
  // was instead, like the macOS dock. Hyprland has no per-focus option for that, so its
  // warping is switched off just around the switch (see scripts/no-warp.sh: the user's own
  // values are saved first and put back right after, and at startup in case the shell
  // stopped in between). A window on another screen keeps Hyprland's move (you're going
  // there). Launching an app isn't affected.
  property var warpRestoreTarget: null

  Process {
    id: warpSwitch
    property var then: null
    onExited: {
      var next = warpSwitch.then
      warpSwitch.then = null
      if (next) next()
    }
  }

  function focusWindow(toplevel, screen) {
    var sameScreen = !screen || !toplevel.screens || toplevel.screens.length === 0
    for (var i = 0; !sameScreen && i < toplevel.screens.length; i++) if (toplevel.screens[i] === screen) sameScreen = true
    if (!sameScreen || warpSwitch.running) {
      toplevel.activate()
      return
    }
    warpSwitch.then = function() {
      toplevel.activate()
      root.warpRestoreTarget = toplevel
      warpRestoreTimer.interval = 300
      warpRestoreTimer.restart()
    }
    warpSwitch.command = ["bash", root.script("no-warp.sh"), "off"]
    warpSwitch.running = true
  }

  // Back on shortly after the window is active (Hyprland has focused it by then), or after
  // 300 ms at most.
  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() {
      if (root.warpRestoreTarget && ToplevelManager.activeToplevel === root.warpRestoreTarget) {
        warpRestoreTimer.interval = 50
        warpRestoreTimer.restart()
      }
    }
  }
  Timer {
    id: warpRestoreTimer
    onTriggered: {
      root.warpRestoreTarget = null
      Quickshell.execDetached(["bash", root.script("no-warp.sh"), "restore"])
    }
  }
  // In case the shell stopped while warping was off.
  Component.onCompleted: {
    root.refreshHyprState()
    Quickshell.execDetached(["bash", root.script("no-warp.sh"), "restore"])
    Quickshell.execDetached(["bash", root.script("keep-cursor.sh"), "restore"])
  }

  // In the file manager (a new window: Nautilus's entry asks for one, see scripts/launch.sh).
  function openFolder(folder) {
    Util.execArgv(["bash", root.script("launch.sh"), root.fixedApp, expandPath(folder.path)])
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

  // A folder's icon. The Trash shows a full trash can while it has items: its "iconFull"
  // from the config if it has one (for icons given as image files), else the theme's
  // "-full" variant of its icon (user-trash -> user-trash-full), where the theme has one.
  function folderIconFor(folder) {
    var icon = String(folder.icon || "")
    if (!isTrash(folder) || root.trashCount === 0) return icon
    if (folder.iconFull) return String(folder.iconFull)
    if (icon && icon.charAt(0) !== "/" && themeIcon(icon + "-full")) return icon + "-full"
    return icon
  }

  Process {
    id: trashCounter
    running: true                // once at startup, then see refreshTrash
    command: ["bash", root.script("trash-count.sh")]
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
  // Clicking a folder (except Trash) shows its newest files in a stack above it;
  // middle-click opens it in Files. Each folder has one option, saved in the config file:
  //   displayAs: "stack"  -> the dock icon shows its newest files piled up (the default)
  //              "folder" -> the dock icon is the folder icon
  // Routine refreshes (each time the dock appears, and when a folder changes) list a
  // stack's first screenful (4 x 3), so a stack opens complete at once, and the dock icon's
  // pile takes its newest 3 from them (12 cost about 5% more than 3: ~6 ms in 1,000 files).
  // An open stack then loads the folder's newest stackMax entries in the background, which
  // only adds files below the visible ones (enough for anyone; about a second at most).
  readonly property int pileMax: 12
  readonly property int stackMax: 1000

  function displayAsFor(folder) {
    return isTrash(folder) || folder.displayAs === "folder" ? "folder" : "stack"
  }

  // ------------------------------------------------------------ adding folders
  // Folders dragged onto the dock (between the folders) get shortcuts there, with their
  // own name and icon (as Files shows them, see scripts/folder-info.sh), displayed as a
  // stack. Folders already in the dock aren't added again: their icons bounce instead.
  signal folderBounce(string path)

  function folderIndexOf(path) {
    for (var i = 0; i < root.folders.length; i++)
      if (expandPath(root.folders[i].path) === path) return i
    return -1
  }

  // The first of GIO's icons for it that the icon theme has; "inode-directory" is a file
  // type icon, so the folder icon goes before it.
  function folderIconFromGio(icons) {
    for (var i = 0; i < icons.length; i++) {
      if (icons[i].indexOf("inode-directory") === 0) continue
      if (themeIcon(icons[i])) return icons[i]
    }
    return "folder"
  }

  // `infos`: [{ path, name, icons }]; `at`: position among the folders (before the Trash).
  function addFolders(infos, at) {
    var list = root.folders.slice()
    var end = list.length > 0 && isTrash(list[list.length - 1]) ? list.length - 1 : list.length
    at = at < 0 ? end : Math.min(at, end)
    var added = 0
    for (var i = 0; i < infos.length; i++) {
      var info = infos[i]
      if (folderIndexOf(info.path) !== -1) { root.folderBounce(info.path); continue }
      var path = info.path.indexOf(root.home + "/") === 0 ? "~" + info.path.slice(root.home.length) : info.path
      list.splice(at + added, 0, { name: info.name, icon: folderIconFromGio(info.icons), path: path, displayAs: "stack" })
      added++
    }
    if (added === 0) return
    root.folders = list
    saveConfig()
  }

  // Remove from Dock, for any folder but the Trash (which always stays, last).
  function removeFolder(path) {
    if (path === "trash:///") return
    root.folders = root.folders.filter(function(f) { return f.path !== path })
    saveConfig()
  }

  // Reorder: the folder at `from` goes to `to` (both indexes in root.folders); the Trash
  // stays last.
  function moveFolder(from, to) {
    var list = root.folders.slice()
    var last = list.length - 1
    if (list.length > 0 && isTrash(list[last])) last--
    if (from < 0 || from > last || isTrash(list[from])) return
    to = Math.max(0, Math.min(last, to))
    if (to === from) return
    var moved = list.splice(from, 1)[0]
    list.splice(to, 0, moved)
    root.folders = list
    saveConfig()
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
  // Folders that can't be found (moved, renamed or deleted since): { dir: true }. They stay
  // in the dock, dimmed, until they're back or removed.
  property var missingFolders: ({})

  function isMissing(folder) {
    return !!folder && !isTrash(folder) && !!root.missingFolders[expandPath(folder.path)]
  }
  property bool folderRefreshPending: false

  function filesFor(folder) {
    return root.folderFiles[expandPath(folder.path)] || []
  }

  Process {
    id: folderLister
    property var dirs: []
    property bool partial: false            // only some of the folders were listed
    stdout: StdioCollector {
      onStreamFinished: root.applyFolderListing(folderLister.dirs, text, folderLister.partial)
    }
    onRunningChanged: {
      if (!running && root.folderRefreshPending) {
        root.folderRefreshPending = false
        root.refreshFolders(true)
      }
    }
  }

  // Which folders changed since they were last listed: files arriving in one name just that
  // folder; anything else (a shortcut added, a folder that turned up) means all of them.
  property var folderDirty: ({})
  property bool folderDirtyAll: true
  function refreshFoldersSoon(dir) {
    if (dir === undefined) root.folderDirtyAll = true
    else root.folderDirty[String(dir).replace(/\/+$/, "")] = true
    folderRefreshSoon.restart()
  }

  // -> { dirs: [...], partial: bool }: the folders to list now (and forgets that they were dirty).
  function takeDirtyFolders() {
    var all = root.folders.filter(function(f) { return !isTrash(f) }).map(function(f) { return expandPath(f.path) })
    var dirs = all
    var partial = false
    if (!root.folderDirtyAll) {
      dirs = all.filter(function(d) { return root.folderDirty[d.replace(/\/+$/, "")] })
      partial = dirs.length < all.length
    }
    root.folderDirty = ({})
    root.folderDirtyAll = false
    return { dirs: dirs, partial: partial }
  }

  // Lists the folders (the ones that changed with dirtyOnly, as the file watcher's timer asks;
  // otherwise all of them).
  function refreshFolders(dirtyOnly) {
    if (!dirtyOnly) root.folderDirtyAll = true
    if (folderLister.running) {
      root.folderRefreshPending = true
      return
    }
    var job = takeDirtyFolders()
    var dirs = job.dirs
    if (dirs.length === 0) return
    folderLister.dirs = dirs
    folderLister.partial = job.partial
    // See scripts/list-folders.sh: newest entries by date added, hidden files and
    // unfinished downloads skipped.
    folderLister.command = ["bash", root.script("list-folders.sh"), String(root.pileMax)].concat(dirs)
    folderLister.running = true
    if (root.stackOpenDir && (!job.partial || dirs.indexOf(root.stackOpenDir) !== -1)) refreshStack(root.stackOpenDir)
  }

  // ---- the open stack's full listing
  // { dir, files: [file, ...], total }: total is how many entries the folder has in all.
  property var stackListing: ({ dir: "", files: [], total: 0 })
  property string stackOpenDir: ""        // set while a stack is open (see win.openStack)
  property string stackRefreshPending: ""

  Process {
    id: stackLister
    property string dir: ""
    stdout: StdioCollector {
      onStreamFinished: root.applyStackListing(stackLister.dir, text)
    }
    onRunningChanged: {
      if (!running && root.stackRefreshPending) {
        var dir = root.stackRefreshPending
        root.stackRefreshPending = ""
        root.refreshStack(dir)
      }
    }
  }

  function refreshStack(dir) {
    if (stackLister.running) {
      root.stackRefreshPending = dir
      return
    }
    stackLister.dir = dir
    stackLister.command = ["bash", root.script("list-folders.sh"), String(root.stackMax), dir]
    stackLister.running = true
  }

  function applyStackListing(dir, text) {
    var listing = parseFolderListing([dir], text)
    var next = { dir: dir, files: listing.files[dir] || [], total: listing.totals[dir] || 0 }
    if (JSON.stringify(next) !== JSON.stringify(root.stackListing)) root.stackListing = next
  }

  // An open stack's files: its full listing once loaded, the newest few until then.
  function stackFilesFor(folder) {
    var dir = expandPath(folder.path)
    return root.stackListing.dir === dir ? root.stackListing.files : filesFor(folder)
  }
  function stackTotalFor(folder) {
    var dir = expandPath(folder.path)
    return root.stackListing.dir === dir ? root.stackListing.total : filesFor(folder).length
  }

  Timer {
    id: folderRefreshSoon
    interval: 700
    onTriggered: root.refreshFolders(true)
  }

  // ------------------------------------------------------------ watching folders
  // The system reports files arriving in or leaving the dock's folders and the Trash (see
  // scripts/watch-folders.sh), so stacks and the Trash's full/empty icon update right away and
  // nothing runs in between, with hiding on or off. (The dock sliding up also refreshes them.)
  // Only while Vitrin is the dock in use (see dockAllowed); restarted when the folders change.
  readonly property string trashFilesDir: (Quickshell.env("XDG_DATA_HOME") || (root.home + "/.local/share")) + "/Trash/files"
  readonly property var watchedDirs: {
    if (!root.dockAllowed) return []
    var dirs = []
    for (var i = 0; i < root.folders.length; i++) {
      var f = root.folders[i]
      dirs.push(isTrash(f) ? root.trashFilesDir : expandPath(f.path))
    }
    return dirs
  }

  Process {
    id: folderWatcher
    stdout: SplitParser {
      onRead: function(line) {
        // "<events>|<path>"
        var bar = String(line).indexOf("|")
        var events = String(line).slice(0, bar)
        var dir = String(line).slice(bar + 1).replace(/\/+$/, "")
        if (dir === root.trashFilesDir) trashRefreshSoon.restart()
        else root.refreshFoldersSoon(dir)
        // A folder that went away is waited for (by missingWatcher) from now on.
        if (events.indexOf("DELETE_SELF") !== -1 || events.indexOf("MOVE_SELF") !== -1) Qt.callLater(root.restartWatcher)
      }
    }
    property int stops: 0                  // stops asked for whose exit hasn't come yet
    property double startedAt: 0
    onRunningChanged: if (running) startedAt = Date.now()
    // 0: nothing to watch (all folders missing); anything else: it stopped unexpectedly, so
    // try again shortly.
    onExited: function(code) {
      if (folderWatcher.stops > 0) {       // stopped on purpose, to watch other folders
        folderWatcher.stops--
        if (folderWatcher.stops === 0) Qt.callLater(root.startWatcher)
        return
      }
      if (code !== 0 && root.watchedDirs.length > 0) root.watcherDied(folderWatcher.startedAt)
    }
  }

  // Folders that are missing (not created yet, deleted, or on a drive that isn't there): their
  // nearest existing parent is watched for the folder's name to appear (scripts/watch-missing.sh).
  // Then everything is watched again, so the folder is watched itself and listed.
  Process {
    id: missingWatcher
    property int stops: 0
    property double startedAt: 0
    onRunningChanged: if (running) startedAt = Date.now()
    stdout: SplitParser {
      onRead: function(line) { missingArrived.restart() }
    }
    onExited: function(code) {
      if (missingWatcher.stops > 0) {
        missingWatcher.stops--
        if (missingWatcher.stops === 0) Qt.callLater(root.startMissingWatcher)
        return
      }
      if (code !== 0 && root.watchedDirs.length > 0) root.watcherDied(missingWatcher.startedAt)
    }
  }
  Timer {
    id: missingArrived
    interval: 300                          // (a folder and its contents can arrive in a burst)
    onTriggered: {
      root.restartWatcher()
      root.refreshFoldersSoon()
      trashRefreshSoon.restart()
    }
  }
  Timer {
    id: watcherRestart
    interval: 2000
    onTriggered: root.restartWatcher()
  }
  // A watcher that keeps stopping (inotify out of watches, say) is started again after 2 s,
  // then 4, 8, ... up to a minute, instead of every 2 s for good. One that had been running
  // for a while starts the count over.
  property int watcherFailures: 0
  function watcherRetryDelay(failures) {
    return Math.min(60000, 2000 * Math.pow(2, Math.max(0, failures - 1)))
  }
  function watcherDied(startedAt) {
    if (Date.now() - startedAt > 10000) root.watcherFailures = 0
    root.watcherFailures++
    watcherRestart.interval = root.watcherRetryDelay(root.watcherFailures)
    watcherRestart.restart()
  }
  function restartWatcher() {
    if (folderWatcher.running) {
      folderWatcher.stops++                // starts again once it has stopped
      folderWatcher.running = false
    } else {
      startWatcher()
    }
    if (missingWatcher.running) {
      missingWatcher.stops++
      missingWatcher.running = false
    } else {
      startMissingWatcher()
    }
  }
  function startWatcher() {
    if (folderWatcher.running || root.watchedDirs.length === 0) return
    folderWatcher.command = ["bash", root.script("watch-folders.sh")].concat(root.watchedDirs)
    folderWatcher.running = true
  }
  function startMissingWatcher() {
    if (missingWatcher.running || root.watchedDirs.length === 0) return
    missingWatcher.command = ["bash", root.script("watch-missing.sh")].concat(root.watchedDirs)
    missingWatcher.running = true
  }
  onWatchedDirsChanged: Qt.callLater(root.restartWatcher)


  onFoldersChanged: root.refreshFoldersSoon()

  // Records are NUL-terminated "<folder index>\t<mime type>\t<icon names>\t<path>" (so any file name,
  // even one with a tab or line break in it, comes through intact).
  // With partial, only some of the folders were listed: the others keep what they had.
  function applyFolderListing(dirs, text, partial) {
    var listing = parseFolderListing(dirs, text)
    var files = listing.files
    var missing = {}
    if (partial) {
      files = Object.assign({}, root.folderFiles, files)
      missing = Object.assign({}, root.missingFolders)
      for (var d = 0; d < dirs.length; d++) delete missing[dirs[d]]
    }
    assignIfChanged("folderFiles", files)
    // A folder that's there always gets a count, even when empty.
    for (var i = 0; i < dirs.length; i++) if (listing.totals[dirs[i]] === undefined) missing[dirs[i]] = true
    assignIfChanged("missingFolders", missing)
  }

  // -> { files: { dir: [file, ...] }, totals: { dir: count } } (see scripts/list-folders.sh)
  function parseFolderListing(dirs, text) {
    var map = {}
    var totals = {}
    for (var d = 0; d < dirs.length; d++) map[dirs[d]] = []
    var records = String(text).split("\u0000")
    for (var i = 0; i < records.length; i++) {
      var parts = records[i].split("\t")
      if (parts.length < 3) continue
      var dir = dirs[parseInt(parts[0])]
      if (!map[dir]) continue
      if (parts[1] === "#total") { totals[dir] = parseInt(parts[2]) || 0; continue }
      if (parts.length < 4) continue
      var path = parts.slice(3).join("\t")
      var mime = parts[1] || "application/octet-stream"
      var isDir = mime === "inode/directory"
      map[dir].push({
        path: path,
        name: path.slice(path.lastIndexOf("/") + 1),
        isDir: isDir,
        mime: mime,
        icon: mimeIcon(mime, isDir, parts[2]),
        image: /^image\/(png|jpeg|gif|webp|bmp|svg\+xml)$/.test(mime)
      })
    }
    return { files: map, totals: totals }
  }

  // ---- previews (see scripts/thumbnail.sh)
  // Files shown in a stack (or the dock icon's pile) get their preview from the shared
  // thumbnail cache, and one is made (the way Files would) when it's missing or outdated:
  // in the background, two at a time, newest requests first, in small batches. A tile that
  // scrolls out of view cancels its request, and closing a stack drops the rest, so fast
  // scrolling through a big folder doesn't leave a backlog of work for files no longer in
  // view. Each file is checked once per stack opening (once per session for the pile).
  //
  // The answers are kept in previewKnown, a plain record that is changed in place: nothing
  // is bound to it, so a new answer doesn't make the dock or every tile re-evaluate. The
  // tile concerned is told through previewReady and looks its answer up itself.
  // The cache names a preview after the MD5 of the file's URI, escaped the GLib way.
  function fileUri(path) {
    return ("file://" + encodeURI(path)).replace(/#/g, "%23").replace(/\?/g, "%3F").replace(/;/g, "%3B")
  }

  signal previewReady(string path)
  property var previewKnown: ({})        // path -> { url }: url "" for no preview
  property var previewChecked: ({})      // path -> true: asked for this time
  property var previewQueue: []          // [{ mime, path, uri, hash }], newest last
  property var previewPending: ({})      // hash -> path, for the batch being made

  function requestPreview(file) {
    if (!file || file.isDir || root.previewChecked[file.path]) return
    root.previewChecked[file.path] = true
    var uri = fileUri(file.path)
    root.previewQueue.push({ mime: file.mime, path: file.path, uri: uri, hash: Qt.md5(uri) })
    previewBatchTimer.restart()
  }

  // A tile left the view: if its request hasn't been sent yet, it's not needed any more.
  function cancelPreview(file) {
    if (!file) return
    for (var i = root.previewQueue.length - 1; i >= 0; i--) {
      if (root.previewQueue[i].path === file.path) {
        root.previewQueue.splice(i, 1)
        delete root.previewChecked[file.path]
      }
    }
  }

  function dropPreviewQueue() {
    for (var i = 0; i < root.previewQueue.length; i++) delete root.previewChecked[root.previewQueue[i].path]
    root.previewQueue = []
  }

  // Requests arriving together (a stack's tiles) go to the script together.
  Timer { id: previewBatchTimer; interval: 50; onTriggered: root.nextPreviewBatch() }

  Process {
    id: previewMaker
    stdout: SplitParser {
      // "<md5> <result> [<preview path>]", one line per file as it's done.
      onRead: function(line) {
        var parts = String(line).split(" ")
        var path = root.previewPending[parts[0]]
        if (path === undefined) return
        delete root.previewPending[parts[0]]
        var found = (parts[1] === "ok" || parts[1] === "new") && parts.length > 2
        var url = found ? "file://" + parts.slice(2).join(" ") : ""
        // A remade preview has the same path as the outdated one: a changed URL makes the
        // tile load it afresh (the query is ignored for local files).
        if (found && parts[1] === "new") url += "?" + Date.now()
        root.previewKnown[path] = { url: url }
        root.previewReady(path)
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextPreviewBatch)
  }

  function nextPreviewBatch() {
    if (previewMaker.running || root.previewQueue.length === 0) return
    var batch = root.previewQueue.splice(Math.max(0, root.previewQueue.length - 4), 4)
    var args = ["bash", root.script("thumbnail.sh")]
    root.previewPending = ({})
    for (var i = 0; i < batch.length; i++) {
      args.push(batch[i].mime, batch[i].path, batch[i].uri, batch[i].hash)
      root.previewPending[batch[i].hash] = batch[i].path
    }
    previewMaker.command = args
    previewMaker.running = true
  }

  // File-type icon from the current icon theme, with generic fallbacks. Remembered per
  // type, since a big folder repeats the same few types many times.
  property var mimeIconCache: ({})
  // `icons` is the comma-separated list GIO gives (the icons Files would use, best first):
  // the first one the theme has wins; the guesses in findMimeIcon are the fallback.
  function mimeIcon(mime, isDir, icons) {
    if (isDir) return "folder"
    var cacheKey = mime + "|" + (icons || "")
    if (root.mimeIconCache[cacheKey]) return root.mimeIconCache[cacheKey]
    var found = ""
    var names = String(icons || "").split(",")
    for (var i = 0; i < names.length && !found; i++) {
      if (names[i] && names[i].indexOf("-symbolic") === -1 && themeIcon(names[i])) found = names[i]
    }
    if (!found) found = findMimeIcon(mime)
    root.mimeIconCache[cacheKey] = found
    return found
  }
  function findMimeIcon(mime) {
    var top = mime.split("/")[0]
    var generic = { text: "text-x-generic", image: "image-x-generic", audio: "audio-x-generic",
                    video: "video-x-generic", font: "font-x-generic" }[top]
    var candidates = [mime.replace("/", "-"), generic,
                      /zip|tar|compressed|archive|rar|7z/.test(mime) ? "package-x-generic" : null,
                      "text-x-generic"]
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] && themeIcon(candidates[i])) return candidates[i]
    }
    return "text-x-generic"
  }

  function openFile(path) {
    Util.execArgv(["uwsm-app", "--", "gio", "open", path])
  }

  // The file manager with the file selected: Nautilus's own option, else the standard
  // FileManager1 D-Bus call most file managers answer, else the file's folder.
  function showInFiles(path) {
    Util.execArgv(["bash", root.script("show-file.sh"), root.fixedApp, path])
  }

  // ------------------------------------------------------------ dropping files
  function localPath(url) {
    var s = String(url)
    if (s.indexOf("file://") !== 0) return s
    // (Some apps send names that aren't escaped, so a lone "%" isn't a valid escape: keep the text.)
    try { return decodeURIComponent(s.slice(7)) } catch (e) { return s.slice(7) }
  }

  // See scripts/move-into-folder.sh: moved on the same drive, copied from another,
  // never overwriting.
  function moveIntoFolder(folder, files) {
    Quickshell.execDetached(["bash", root.script("move-into-folder.sh"), folder].concat(files))
  }

  // Trash and folders take dropped files; so do apps, except Files (like Finder on macOS,
  // it isn't a place to drop documents onto).
  function acceptsDrop(item, isFolder) {
    if (isFolder) return isTrash(item) || (!isMissing(item) && expandPath(item.path).charAt(0) === "/")
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
        root.refreshFoldersSoon(expandPath(item.path))
      }
      return
    }

    if (!item.entry) return
    // Open the files with this app, like "Open With" in a file manager.
    markLaunching(item)
    Quickshell.execDetached(["bash", "-l", root.script("launch.sh"), String(item.entry.id)].concat(targets))
  }

  // Keep in Dock: the app joins the pinned apps, at their end (or at `index` when dragged
  // there from the middle section).
  function pin(key, index) {
    if (root.pins.indexOf(key) !== -1) return
    var pins = root.pins.slice()
    pins.splice(index === undefined ? pins.length : Math.max(1, Math.min(pins.length, index)), 0, key)
    root.pins = pins
    saveConfig()
  }

  // Remove from Dock. A pinned app that's running moves to the middle section's end.
  function unpin(key) {
    if (isFixed(key)) return
    if (isApps(key)) { setSetting("showApps", false, true); return }
    root.pins = root.pins.filter(function(p) { return p !== key })
    saveConfig()
  }

  // Remove from Dock, for a recently used app in the middle section.
  function forgetRecent(key) {
    if (!isRecent(key)) return
    root.middle = root.middle.filter(function(k) { return k !== key })
    syncLayout()
    saveConfig()
  }

  // Reorder the pinned apps (pins order = their order on screen). Nothing moves Files, and
  // nothing moves in front of it (position 0); the middle section keeps its own order.
  function move(key, delta) {
    var from = root.pins.indexOf(key)
    var to = from + delta
    if (isFixed(key) || from === -1 || to < 1 || to >= root.pins.length) return
    var pins = root.pins.slice()
    pins.splice(from, 1)
    pins.splice(to, 0, key)
    root.pins = pins
    saveConfig()
  }

  function moveTo(key, to) {
    var from = root.pins.indexOf(key)
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
      if (isMissing(item)) return [
        { kind: "text", label: "“" + (item.name || item.path) + "” can't be found." },
        { kind: "text", label: "It may have been moved, renamed, or deleted.", secondary: true },
        { kind: "separator" },
        { kind: "action", label: "Remove from Dock", act: "remove-folder" }
      ]
      // Same order as the apps' menus: opening, then arranging, then the destructive one.
      if (isTrash(item)) return joinMenuGroups([
        [{ kind: "action", label: "Open in " + root.fileManagerName, act: "open" }],
        [{ kind: "action", label: "Empty Trash…", act: "empty-ask", disabled: root.trashCount === 0 }]
      ])
      var arrange = [{ kind: "submenu", label: "Display as", page: "displayAs",
                       value: displayAsFor(item) === "stack" ? "Stack" : "Folder" }]
      var at = folderIndexOf(expandPath(item.path))
      var lastMovable = root.folders.length - 1 - (root.folders.length > 0 && isTrash(root.folders[root.folders.length - 1]) ? 1 : 0)
      if (at > 0) arrange.push({ kind: "action", label: "Move Left", act: "folder-left" })
      if (at !== -1 && at < lastMovable) arrange.push({ kind: "action", label: "Move Right", act: "folder-right" })
      arrange.push({ kind: "action", label: "Remove from Dock", act: "remove-folder" })
      return joinMenuGroups([[{ kind: "action", label: "Open in " + root.fileManagerName, act: "open" }], arrange])
    }

    // Its windows; opening (New Window and the app's own actions); arranging; Quit.
    // (The check marks the window the app was last in, unless it is hidden; hidden ones get a
    // diamond. The order is the one a click follows.)
    var windows = []
    var ordered = windowsInOrder(item.windows)
    var lead = lastUsedWindow(item.windows)
    for (var i = 0; i < ordered.length; i++) {
      var w = ordered[i]
      var hidden = isHidden(w)
      windows.push({ kind: "window", label: windowLabel(w), toplevel: w, current: w === lead && !hidden, hidden: hidden })
    }

    var open = item.entry ? appActionRows(item) : []

    var arrange = []
    if (!isFixed(item.key)) {
      // Only pinned apps move (the middle section keeps its order). Position 0 belongs to
      // the file manager, so the app right after it can't move left.
      var index = root.pins.indexOf(item.key)
      if (index > 1) arrange.push({ kind: "action", label: "Move Left", act: "left" })
      if (index !== -1 && index < root.pins.length - 1) arrange.push({ kind: "action", label: "Move Right", act: "right" })
      if (!item.pinned && item.entry) arrange.push({ kind: "action", label: "Keep in Dock", act: "pin" })
      if (item.pinned) arrange.push({ kind: "action", label: "Remove from Dock", act: "unpin" })
      else if (isRecent(item.key)) arrange.push({ kind: "action", label: "Remove from Dock", act: "forget" })
    }

    var quit = item.windows.length > 0 ? [{ kind: "action", label: "Quit", act: "quit" }] : []
    return joinMenuGroups([windows, open, arrange, quit])
  }

  // Non-empty groups of rows, with a separator between each two.
  function joinMenuGroups(groups) {
    var rows = []
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].length === 0) continue
      if (rows.length > 0) rows.push({ kind: "separator" })
      rows = rows.concat(groups[i])
    }
    return rows
  }

  // New Window, then the actions the app lists in its desktop entry (New Private Window,
  // New Incognito Window, ...), as GNOME's dock shows them. The dock's New Window is only a
  // fallback: an app action that opens a new window (named so, or running the app's own
  // command, like foot's "New Terminal" or LibreOffice's "New Document") takes its place,
  // under the app's own name.
  function appActionRows(item) {
    var actions = item.entry.actions || []
    var rows = []
    var ownNew = null
    var appCommand = plainCommand(item.entry.execString)
    for (var i = 0; i < actions.length; i++) {
      var a = actions[i]
      if (!a || !a.name) continue
      var row = { kind: "action", label: a.name, act: "desktop-action", actionId: a.id }
      if (!ownNew && (a.id === "new-window" || String(a.name).toLowerCase() === "new window"
                      || (appCommand !== "" && plainCommand(a.execString) === appCommand))) {
        ownNew = row
        continue
      }
      rows.push(row)
    }
    rows.unshift(ownNew || { kind: "action", label: "New Window", act: "new" })
    return rows
  }

  // A desktop entry command without its field codes (%U, %f, ...), for comparing commands.
  function plainCommand(exec) {
    return String(exec || "").replace(/%[a-zA-Z]/g, "").replace(/\s+/g, " ").trim()
  }

  // One of the app's desktop entry actions, the Omarchy way (see scripts/launch.sh).
  function runAppAction(item, actionId) {
    if (!item.entry) return
    markLaunching(item)
    Util.execArgv(["bash", root.script("launch.sh"), item.entry.id + ":" + actionId])
  }

  // Second page of a folder's menu ("Display as"), slid in like the submenus in the Files
  // app's menus.
  function folderSubmenuRows(folder, page) {
    var current = displayAsFor(folder)
    return [
      { kind: "back", label: "Display as" },
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

  function runRow(row, item, screen) {
    if (row.kind === "window") {
      // (The menu can outlive its window: a closed one is skipped.)
      if (ToplevelManager.toplevels.values.indexOf(row.toplevel) !== -1) bringForward(row.toplevel, screen)
      return
    }
    switch (row.act) {
      case "toggle-hide": setSetting("autoHide", !root.autoHide, true); break
      case "empty": emptyTrash(); break
      case "open": openFolder(item); break
      case "new": launch(item); break
      case "unpin": unpin(item.key); break
      case "remove-folder": removeFolder(item.path); break
      case "desktop-action": runAppAction(item, row.actionId); break
      case "folder-left": moveFolder(folderIndexOf(expandPath(item.path)), folderIndexOf(expandPath(item.path)) - 1); break
      case "folder-right": moveFolder(folderIndexOf(expandPath(item.path)), folderIndexOf(expandPath(item.path)) + 1); break
      case "forget": forgetRecent(item.key); break
      case "pin": pin(item.key); break
      case "left": move(item.key, -1); break
      case "right": move(item.key, 1); break
      case "quit": quit(item); break
    }
  }

  // ------------------------------------------------------------ Omarchy's own dock
  // Omarchy 4.5 and later have a dock of their own (the "omarchy.dock" plugin, shown on
  // floating workspaces, where the two would overlap). Only one should be on: whenever both
  // are, Vitrin asks which to keep (see dockChoiceDialog) and turns the other one off, the
  // way the Omarchy menu's Setup > Plugins does. Until then it shows nothing. Omarchy records
  // a built-in plugin that's turned off in shell.json's "disabledPlugins"; without a
  // shell.json of the user's, its defaults apply.
  // (The shell sets this on plugins too.)
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  property bool systemDockInstalled: false
  property bool systemDockKnown: false
  property var shellDisabledPlugins: []
  property bool shellConfigKnown: false
  readonly property bool systemDockOn: root.systemDockInstalled
    && root.shellDisabledPlugins.indexOf("omarchy.dock") === -1
  // Shown only once both are known, so it never flashes up before stepping aside.
  readonly property bool dockAllowed: root.systemDockKnown && root.shellConfigKnown && !root.systemDockOn

  FileView {
    path: root.omarchyPath + "/shell/plugins/dock/manifest.json"
    onLoaded: { root.systemDockInstalled = true; root.systemDockKnown = true }
    onLoadFailed: function(error) { root.systemDockInstalled = false; root.systemDockKnown = true }
  }

  FileView {
    id: shellConfigFile
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var disabled = []
      try {
        var cfg = JSON.parse(text())
        if (cfg && Array.isArray(cfg.disabledPlugins)) disabled = cfg.disabledPlugins.map(String)
      } catch (e) {
        // Caught mid-save: keep what we had; the finished file comes as another change.
        if (root.shellConfigKnown) return
      }
      if (JSON.stringify(disabled) !== JSON.stringify(root.shellDisabledPlugins)) root.shellDisabledPlugins = disabled
      root.shellConfigKnown = true
    }
    onLoadFailed: function(error) {
      if (root.shellDisabledPlugins.length > 0) root.shellDisabledPlugins = []
      root.shellConfigKnown = true
    }
  }

  // Which question to ask while both docks are on: "start" when Omarchy's dock was already
  // on as Vitrin started (Vitrin was just enabled, or both were on at login), "turnedOn" when
  // it was turned on while Vitrin ran. "" when there's nothing to ask.
  property string dockChoice: ""
  property bool systemDockSeenOff: false
  property bool dockChoiceMade: false     // a button was pressed; the switch is on its way
  onSystemDockOnChanged: root.checkDockChoice()
  onSystemDockKnownChanged: root.checkDockChoice()
  onShellConfigKnownChanged: root.checkDockChoice()
  function checkDockChoice() {
    if (!root.systemDockKnown || !root.shellConfigKnown) return
    if (!root.systemDockOn) {
      root.systemDockSeenOff = true
      root.dockChoice = ""
      root.dockChoiceMade = false
    } else if (root.dockChoice === "") {
      root.dockChoice = root.systemDockSeenOff ? "turnedOn" : "start"
    }
  }

  // Keep Vitrin: turn Omarchy's dock off. Keep Omarchy's: turn Vitrin off (it unloads).
  function chooseDock(vitrin) {
    root.dockChoiceMade = true
    Quickshell.execDetached(["omarchy-plugin-disable", vitrin ? "omarchy.dock" : root.pluginId])
  }

  PanelWindow {
    id: dockChoiceDialog
    readonly property bool starting: root.dockChoice === "start"
    screen: root.focusedScreen()
    visible: root.dockChoice !== "" && !root.dockChoiceMade
    anchors { top: true; bottom: true; left: true; right: true }
    color: Qt.rgba(0, 0, 0, 0.25)
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: root.slug + "-choice"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    // Which button the keyboard has: the default (right) one first. Left/Right or Tab move it,
    // Enter picks it.
    property bool focusDefault: true
    onVisibleChanged: if (visible) { focusDefault = true; choiceCard.forceActiveFocus() }

    // No way around the question: clicks and scrolling outside it do nothing.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onWheel: function(w) { w.accepted = true }
    }

    Card {
      id: choiceCard
      dock: root
      anchors.centerIn: parent
      focus: true
      Keys.onPressed: function(event) {
        event.accepted = true
        switch (event.key) {
        case Qt.Key_Left: dockChoiceDialog.focusDefault = false; break
        case Qt.Key_Right: dockChoiceDialog.focusDefault = true; break
        case Qt.Key_Tab: case Qt.Key_Backtab: dockChoiceDialog.focusDefault = !dockChoiceDialog.focusDefault; break
        case Qt.Key_Return: case Qt.Key_Enter:
          root.chooseDock(dockChoiceDialog.focusDefault ? dockChoiceDialog.starting : !dockChoiceDialog.starting)
          break
        default: event.accepted = false
        }
      }
      width: 540
      height: choiceColumn.implicitHeight + 48

      Column {
        id: choiceColumn
        x: 24
        y: 24
        width: parent.width - 48
        spacing: 16

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: dockChoiceDialog.starting ? "Use Vitrin instead of Omarchy's dock?"
                                          : "Use Omarchy's dock instead of Vitrin?"
          color: root.popupText
          font.family: root.uiFont
          font.pixelSize: root.uiFontSize + 2
          font.weight: Font.DemiBold
          bottomPadding: 6
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: dockChoiceDialog.starting
            ? "Omarchy's own dock is also on. It shows up on floating workspaces, where it would overlap Vitrin, so only one dock should be on at a time."
            : "Omarchy's own dock was just turned on. It would overlap Vitrin on floating workspaces, so only one dock should be on at a time."
          color: root.popupText
          font.family: root.uiFont
          font.pixelSize: root.uiFontSize
          lineHeight: 1.15
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "You can switch between the two any time in the Omarchy menu, under Setup \u2192 Plugins: disable the dock you're using, then enable the other."
          color: root.popupText
          opacity: 0.75
          font.family: root.uiFont
          font.pixelSize: root.uiFontSize
          lineHeight: 1.15
        }

        // Buttons: the other dock on the left, the default (the latest choice) on the right.
        Item {
          width: parent.width
          height: 32 + 6

          Rectangle {
            anchors.right: defaultButton.left
            anchors.rightMargin: 10
            anchors.bottom: parent.bottom
            width: otherText.implicitWidth + 24
            height: 32
            radius: root.rowRadius
            color: otherMouse.pressed ? Util.alpha(root.foreground, 0.16)
                 : otherMouse.containsMouse || !dockChoiceDialog.focusDefault ? root.rowHover
                 : Util.alpha(root.foreground, 0.06)
            FocusRing { dock: root; shown: !dockChoiceDialog.focusDefault }   // the keyboard's button
            Text {
              id: otherText
              anchors.centerIn: parent
              text: dockChoiceDialog.starting ? "Keep Omarchy's Dock" : "Keep Vitrin"
              color: root.popupText
              font.family: root.uiFont
              font.pixelSize: root.uiFontSize
            }
            MouseArea {
              id: otherMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.chooseDock(!dockChoiceDialog.starting)
            }
          }

          Rectangle {
            id: defaultButton
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: defaultText.implicitWidth + 32
            height: 32
            radius: root.rowRadius
            color: defaultMouse.pressed ? Qt.darker(root.accent, 1.15)
                 : defaultMouse.containsMouse ? Qt.lighter(root.accent, 1.08)
                 : root.accent
            FocusRing { dock: root; shown: dockChoiceDialog.focusDefault }
            Text {
              id: defaultText
              anchors.centerIn: parent
              text: dockChoiceDialog.starting ? "Use Vitrin" : "Use Omarchy's Dock"
              color: root.background
              font.family: root.uiFont
              font.pixelSize: root.uiFontSize
              font.weight: Font.DemiBold
            }
            MouseArea {
              id: defaultMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.chooseDock(dockChoiceDialog.starting)
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ apps grid
  AppGrid {
    id: appGrid
    dock: root
  }
  onDockAllowedChanged: if (!root.dockAllowed) appGrid.close()

  // Omarchy's Apps shortcut (Super+Alt+Space) and its menu's Apps item ask "omarchy.dock" to
  // open its app grid. While Omarchy's dock is off, nothing else answers to that name, so
  // Vitrin does, with its own grid (on the focused screen). When Vitrin is off, or Omarchy's
  // dock is on, this stays quiet and Omarchy's grid answers as usual.
  ShellIpc {
    target: "omarchy.dock"
    enabled: root.dockAllowed
    function apps(): void { appGrid.toggle(root.focusedScreen()) }
    // (Omarchy's workspace layout commands call this; Vitrin has nothing to refresh.)
    function refresh(): void {}
  }

  // The dock windows by screen name (filled by each window as it appears).
  property var docks: ({})

  // Commands for key bindings: `omarchy-shell vitrin <command>`.
  ShellIpc {
    target: "vitrin"
    enabled: root.dockAllowed
    // Super+D: show the dock and drive it with the keyboard (again: leave).
    function focus(): void {
      var screen = root.focusedScreen()
      var w = screen ? root.docks[screen.name] : null
      if (!w) return
      if (w.keyMode) w.exitKeyMode()
      else w.enterKeyMode()
    }
  }

  function focusedScreen() {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  // ------------------------------------------------------------ one dock per screen
  Variants {
    model: root.dockAllowed ? Quickshell.screens : []

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
      Component.onCompleted: {
        reservedHeightTimer.restart()
        root.docks[win.screen.name] = win
      }
      Component.onDestruction: if (root.docks[win.screen.name] === win) delete root.docks[win.screen.name]
      WlrLayershell.namespace: root.slug           // the blur rule matches this name
      // Overlay, so it can slide up over full-screen apps too (like macOS).
      WlrLayershell.layer: WlrLayer.Overlay
      // Only while the dock is driven by the keyboard (see enterKeyMode): Exclusive to get the
      // keyboard (nothing else makes the compositor hand it over), then on-demand, so that a
      // click on another window can take it away again (which ends the mode).
      WlrLayershell.keyboardFocus: !win.keyMode ? WlrKeyboardFocus.None
        : (win.keyReleased ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)

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
      // The control the keyboard has in the settings dialog: 0 Size, 1 Drag dividers, 2 Auto-hide,
      // 3 Hide delay, 4 App launcher, 5 Recent apps, 6 Animate, 7 Reset, 8 Done.
      property int settingsFocus: 0
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
      property string dragIcon: ""            // icon url (or the letter tile)
      property string dragName: ""
      property var dragFiles: []              // a stack folder's pile, drawn on the dragged copy
      property bool dragMissing: false        // a folder that can't be found (dimmed, "?")
      // Slot width of the dragged icon, at the current size (which can change mid-drag: see
      // dockWidthFor).
      readonly property real dragWidth: win.dragFrom !== -1 ? root.slotWidthFor(win.dragSlot, win.size) : 0
      property string dragSlot: ""            // the dragged icon's sizing icon (see slotSourceFor)
      // A folder is being dragged (dragFrom/dragTo are then indexes into root.folders).
      property bool dragFolder: false
      // Set for the moment a pulled-out icon is removed: everything is already where it
      // belongs, so the slide-aside offsets are dropped without animating.
      property bool snapShifts: false
      // A middle-section app is being dragged in among the pinned apps (to pin it at dragTo).
      // Its own flag, because dragTo alone can't tell "at the end of the pinned apps" from
      // "back where it was" for the middle section's first app: both are the same position.
      property bool dragToPinned: false
      readonly property Item dragRow: row
      // For icons fading at the edges of a scrolling dock (see DockButton's edgeFade).
      readonly property real scrollX: rowView.contentX
      readonly property real scrollMax: rowView.maxX
      readonly property real viewWidth: rowView.width
      readonly property real rowX: row.x
      // The icons' actual width, including slots growing in or shrinking away, plus the
      // dock's end padding: what the outline follows. (dockWidthFor is the settled width.)
      readonly property real rowWidth: row.implicitWidth + root.leftPadFor(win.size) + root.rightPadFor(win.size)
        + win.dropGap

      // Drag out to remove (pinned apps other than Files): pull the icon this far above
      // the dock and "Remove" appears; letting go there removes it from the dock.
      property real dragSceneX: 0
      property real dragSceneY: 0
      property bool dragRemovable: false
      readonly property int removeDistance: 40
      // The dock's top edge when the drag started: fixed for the drag, because the dock's
      // height can change while an icon is pulled out (and that mustn't move the line).
      property real dragTopY: 0
      readonly property bool dragRemoving: dragFrom !== -1 && dragRemovable
        && (dragTopY - dragSceneY) > removeDistance

      // Files dragged over the dock from another app (Files, browser, ...)
      property int dropDepth: 0

      // Folders dragged over the dock: which of the dragged items are folders (looked up
      // when the drag comes in), and where among the folders a gap is open for them (-1:
      // none). One gap however many there are; they're all added there, in order.
      property string dropKey: ""
      property var dropInfo: null            // { key, folders: [{ path, name, icons }] }
      property int dropInsert: -1
      property real dropRowX: 0              // last pointer position over the folders
      property bool dropOverFolders: false
      // The spot right before the Trash opens only once the pointer stays there a moment,
      // like macOS: otherwise reaching for the Trash would push it away from under the
      // pointer. Every other spot opens right away, and an open gap follows the pointer.
      property int dropPendingInsert: -1
      Timer {
        id: gapDwell
        interval: 200
        onTriggered: if (win.dropOverFolders) win.dropInsert = win.dropPendingInsert
      }
      // Over the middle of a folder's icon (see DockButton). The gap stays open meanwhile:
      // closing it would slide the folders under the pointer, onto another spot.
      property int dropOnFolderIcon: 0
      function settleDropGap() {
        Qt.callLater(function() {
          if (!win.dropOverFolders && win.dropOnFolderIcon === 0) win.dropInsert = -1
        })
      }
      property int pendingInsert: -2         // a drop waiting for the lookup (-2: none)
      readonly property bool dropHasFolders: !!dropInfo && dropInfo.key === dropKey && dropInfo.folders.length > 0
      readonly property bool dropHasNewFolders: dropHasFolders && dropInfo.folders.some(function(f) {
        return root.folderIndexOf(f.path) === -1
      })
      // New folders show as stacks: their slot is a stack's.
      readonly property string dropGapSource: root.iconSource("text-x-generic")
      readonly property real dropGapWidth: root.slotWidthFor(win.dropGapSource, win.size)
      property real dropGap: dropInsert >= 0 ? dropGapWidth : 0
      Behavior on dropGap {
        enabled: !win.snapShifts
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
      }
      onDropInfoChanged: if (win.dropOverFolders) win.updateDropInsert(win.dropRowX)

      Process {
        id: folderInfo
        property string key: ""
        stdout: StdioCollector {
          onStreamFinished: {
            var folders = []
            var fields = String(text).split("\u0000")      // path, name, icons, path, name, icons, ...
            for (var i = 0; i + 2 < fields.length; i += 3) {
              folders.push({ path: fields[i], name: fields[i + 1], icons: fields[i + 2].split(",") })
            }
            win.dropInfo = { key: folderInfo.key, folders: folders }
            if (win.pendingInsert !== -2) {
              if (folderInfo.key === win.dropKey) root.addFolders(folders, win.pendingInsert)
              win.pendingInsert = -2
            }
          }
        }
      }

      function lookUpDrop(urls) {
        var key = Array.prototype.map.call(urls, String).join("\n")
        if (key === win.dropKey) return
        win.dropKey = key
        win.dropInfo = null
        var paths = Array.prototype.map.call(urls, root.localPath).filter(function(p) { return p.charAt(0) === "/" })
        if (paths.length === 0) { win.dropInfo = { key: key, folders: [] }; return }
        folderInfo.running = false
        folderInfo.key = key
        folderInfo.command = ["bash", root.script("folder-info.sh")].concat(paths)
        folderInfo.running = true
      }

      // Where the gap for dragged folders opens: before or after the folder under the
      // pointer, whichever half it's on (decided on the dock without the gap, so the gap
      // stays put while the pointer is in it). Never after the Trash.
      function updateDropInsert(rowX) {
        win.dropRowX = rowX
        if (!win.dropHasFolders) { win.dropInsert = -1; return }
        var start = divider.x + divider.width
        var widths = root.folders.map(function(f) { return root.slotWidthFor(root.slotSourceFor(f, true), win.size) })
        if (win.dropInsert >= 0) {
          var gapLeft = start
          for (var j = 0; j < win.dropInsert; j++) gapLeft += widths[j]
          if (rowX >= gapLeft && rowX <= gapLeft + win.dropGapWidth) return
          if (rowX > gapLeft + win.dropGapWidth) rowX -= win.dropGapWidth
        }
        var count = root.folders.length
        var end = count > 0 && root.isTrash(root.folders[count - 1]) ? count - 1 : count
        var at = count
        var left = start
        for (var i = 0; i < count; i++) {
          if (rowX < left + widths[i]) { at = rowX < left + widths[i] / 2 ? i : i + 1; break }
          left += widths[i]
        }
        at = Math.max(0, Math.min(end, at))
        var beforeTrash = end < count && at === end
        if (!beforeTrash) {
          gapDwell.stop()
          win.dropInsert = at
          return
        }
        if (win.dropInsert === at) return
        // A gap open elsewhere stays put meanwhile (closing it would slide the folders
        // under the pointer).
        if (win.dropPendingInsert !== at || !gapDwell.running) {
          win.dropPendingInsert = at
          gapDwell.restart()
        }
      }

      function dropFoldersAt(at) {
        if (win.dropHasFolders) root.addFolders(win.dropInfo.folders, at)
        else if (!win.dropInfo || win.dropInfo.key !== win.dropKey) win.pendingInsert = at
      }

      // Divider resizing: while dragging, the dock is only scaled visually (cheap: no
      // re-layout, no window resize per step); the real size is applied once on release.
      property int resizePreview: 0          // previewed icon size; 0 = not resizing

      // The dock's exact width and height at a given icon size (same arithmetic as the real
      // layout), so the preview lands exactly where the real dock will be on release.
      // While an icon is pulled out to remove it, the dock is sized as if it were already
      // gone: a dock shrunk to fit then lets its other icons grow into the space right away
      // (instead of narrowing now and widening again on release).
      function dockWidthFor(size) {
        var width = root.folders.length > 0 ? root.dividerWidthFor(size) : 0
        // Before the middle section (not while its only app is being pulled out).
        if (root.hasMiddle && !(win.dragRemoving && !win.dragFolder && root.middle.length === 1 && win.dragFrom >= root.middleStart))
          width += root.dividerWidthFor(size)
        for (var i = 0; i < root.dockSources.length; i++) width += root.slotWidthFor(root.dockSources[i], size)
        if (win.dragRemoving) width -= root.slotWidthFor(win.dragSlot, size)
        if (win.dropInsert >= 0) width += root.slotWidthFor(win.dropGapSource, size)
        return width + root.leftPadFor(size) + root.rightPadFor(size)
      }
      function dockHeightFor(size) { return root.slotHeightFor(size) + (root.padFor(size) + 1) * 2 }
      readonly property real previewScaleX: resizePreview > 0 ? dockWidthFor(resizePreview) / dockWidthFor(win.size) : 1
      readonly property real previewScaleY: resizePreview > 0 ? dockHeightFor(resizePreview) / dockHeightFor(win.size) : 1

      // ---------------------------------------------------------- fitting the screen
      // Like macOS, the Size setting is a maximum: when the dock would be wider than the
      // screen (leaving the end space free at each side), its icons are drawn smaller, down
      // to minFitSize, at the exact fractional size that fills the space (see "fractional").
      // Each screen fits its own dock. Size changes apply at once: easing them would make a
      // full dock first narrow (an app's slot gone at the old size), then widen again.
      readonly property int minFitSize: 32    // the smallest Size setting: never smaller than that
      function fitsAt(size) { return dockWidthFor(size) + 2 * root.endsFor(size) <= win.width }
      // The largest size up to maxSize that fits: maxSize itself if it does, else the exact
      // fractional size, found by halving the interval.
      function fitFor(maxSize) {
        if (fitsAt(maxSize)) return maxSize
        if (!fitsAt(win.minFitSize)) return win.minFitSize
        var low = win.minFitSize, high = maxSize
        for (var i = 0; i < 16; i++) {
          var mid = (low + high) / 2
          if (fitsAt(mid)) low = mid
          else high = mid
        }
        return low
      }
      readonly property real fitTarget: win.width > 0 ? fitFor(root.iconSize) : root.iconSize
      // While an icon is being dragged (a pulled-out icon can let a crowded dock's icons
      // grow, and dragging it back in shrinks them again), size changes ease in along with
      // the gap opening or closing, instead of jumping. At other times they apply at once.
      property real size: fitTarget
      Behavior on size {
        enabled: win.dragFrom !== -1 && !win.snapShifts
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
      }

      // Even at minFitSize the dock may not fit (dozens of apps): then it takes the screen's
      // width and its icons scroll sideways (mouse wheel or touchpad), see rowView.
      readonly property int maxDockWidth: win.width - 2 * root.endsFor(win.size)
      readonly property bool overflowing: dockWidthFor(win.size) > win.maxDockWidth
      onOverflowingChanged: if (!overflowing) rowView.contentX = 0

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

      // ---------------------------------------------------------- keyboard mode
      property bool keyMode: false
      property Item kbButton: null            // the highlighted icon
      // A menu opened from keyboard mode: the dock keeps the keyboard and handles the menu's
      // keys itself (the menu's own focus grab would take the keyboard from the dock).
      property bool menuByKey: false
      property var menuKeyRow: null           // the highlighted row
      property string menuKeyKey: ""          // and its rowKey (the menu's Repeater hands out copies of rows)
      property string menuReturnKey: ""       // the submenu row we came from: highlighted again on the way back
      // A stack opened from keyboard mode: like menus, the dock keeps the keyboard and the stack's
      // focus grab stays off. stackKeyIndex is the highlighted file (-1: none yet).
      property bool stackByKey: false
      property int stackKeyIndex: -1
      property bool stackButtonFocus: false   // the stack's "Open in Files" button has the highlight

      // The icons in order, left to right (leaving ones skipped).
      function keyButtons() {
        var list = []
        var kids = row.children
        for (var i = 0; i < kids.length; i++) {
          var c = kids[i]
          if (c.dock !== undefined && c.isFolder !== undefined && !c.isLeaving && c.visible) list.push(c)
        }
        list.sort(function(a, b) { return a.mapToItem(row, 0, 0).x - b.mapToItem(row, 0, 0).x })
        return list
      }

      // 0 = apps, 1 = recent apps, 2 = folders (the dividers' sections).
      function keySection(b) {
        if (b.isFolder) return 2
        return root.hasMiddle && root.middle.indexOf(b.item.key) !== -1 ? 1 : 0
      }

      function enterKeyMode() {
        if (win.suppressed || win.keyMode || appGrid.opened) return   // (the launcher has the keyboard)
        win.closeMenu()
        win.closeStack()
        win.reveal()
        var list = win.keyButtons()
        if (list.length === 0) return
        win.keyMode = true
        win.keyHeld = false
        keyGiveUp.restart()
        win.keyPrepared = false
        keySetup.running = true
        keyCatcher.forceActiveFocus()
        win.keySelect(list[0])
        keyTipRefresh.restart()
      }

      // The first label is placed while a hidden dock is still sliding up (from where the icon
      // was, not where it ends up): place it again once the slide (180 ms) is done.
      Timer {
        id: keyTipRefresh
        interval: 260
        onTriggered: if (win.keyMode && tip.visible) tip.anchor.updateAnchor()
      }

      function exitKeyMode() {
        if (!win.keyMode) return
        win.keyMode = false
        win.keyTyped = ""
        if (win.menuByKey) win.closeMenu()
        if (win.stackByKey) win.closeStack()
        win.keyHeld = false
        win.keyPrepared = false
        win.kbButton = null
        win.tipTarget = null      // hides the label as it is (clearing its text first made it jump)
        Quickshell.execDetached(["bash", root.script("keep-cursor.sh"), "restore"])
        hideTimer.restart()
      }

      // ---- stacks by keyboard
      function keyOpenStack(button) {
        win.stackByKey = true
        win.stackKeyIndex = 0
        win.tipText = ""
        win.folderClicked(button, button.item)
      }

      // The keys of an open stack, however it was opened (see menuKey). Returns whether used.
      function stackKey(event) {
        // A file's menu is open: it takes the keys.
        if (stackPopup.tileMenuFile !== null) return stackPopup.tileMenuKey(event)
        // The "Open in Files" button has the highlight (Tab gets there and back).
        if (win.stackButtonFocus) {
          switch (event.key) {
          case Qt.Key_Escape: win.closeKeyStack(); return true
          case Qt.Key_Return: case Qt.Key_Enter:
            win.exitKeyMode()
            stackPopup.openFolder()
            return true
          case Qt.Key_Tab: case Qt.Key_Backtab: case Qt.Key_Up: win.stackButtonFocus = false; return true
          }
          return false
        }
        var files = stackPopup.files
        var n = files.length
        var cols = stackPopup.columns
        var i = Math.min(win.stackKeyIndex, n - 1)
        var next = i
        switch (event.key) {
        case Qt.Key_Escape: win.closeKeyStack(); return true
        case Qt.Key_Tab: case Qt.Key_Backtab: win.stackButtonFocus = true; return true
        case Qt.Key_Menu: stackPopup.showTileMenuAt(i); return true
        case Qt.Key_F10:
          if (!(event.modifiers & Qt.ShiftModifier)) return false
          stackPopup.showTileMenuAt(i)
          return true
        case Qt.Key_Return: case Qt.Key_Enter:
          if (event.modifiers & Qt.ShiftModifier) { stackPopup.showTileMenuAt(i); return true }
          if (i >= 0 && i < n) {
            win.exitKeyMode()
            stackPopup.openFile(files[i])
          }
          return true
        case Qt.Key_Left: next = i < 0 ? 0 : (i - 1 + n) % n; break
        case Qt.Key_Right: next = i < 0 ? 0 : (i + 1) % n; break
        case Qt.Key_Up:
          if (i < 0) next = 0
          else if (i - cols >= 0) next = i - cols
          else {   // off the top: the bottom of the same column
            next = Math.floor((n - 1) / cols) * cols + i % cols
            if (next >= n) next = Math.max(0, next - cols)
          }
          break
        case Qt.Key_Down:
          if (i < 0) next = 0
          else if (i + cols < n) next = i + cols
          else next = i % cols            // off the bottom: the top of the same column
          break
        case Qt.Key_Home: next = 0; break
        case Qt.Key_End: next = n - 1; break
        case Qt.Key_PageUp: next = Math.max(0, i - stackPopup.rows * cols); break
        case Qt.Key_PageDown: next = Math.min(n - 1, i + stackPopup.rows * cols); break
        default: return false
        }
        if (n > 0) win.stackKeyIndex = Math.max(0, Math.min(n - 1, next))
        return true
      }

      // Esc: close the stack and go back to the dock, the folder's icon still highlighted.
      function closeKeyStack() {
        win.closeStack(true)
        if (win.keyMode && win.kbButton) win.showTip(win.kbButton, win.kbButton.label, true)
      }

      // ---- menus by keyboard
      // The rows that can be chosen, in the order they're drawn (window rows first).
      function keyMenuRows() {
        var chooseable = function(r) { return r.kind !== "separator" && r.kind !== "text" && !r.disabled }
        var windows = win.menuList.filter(function(r) { return r.kind === "window" && chooseable(r) })
        var others = win.menuList.filter(function(r) { return r.kind !== "window" && chooseable(r) })
        return windows.concat(others)
      }

      // What identifies a row (windows by their own address: two can share a title).
      function rowKey(r) {
        if (r.kind === "window") {
          var address = r.toplevel ? root.hyprAddressFor(r.toplevel) : ""
          return "window|" + (address || win.menuList.indexOf(r))
        }
        return [r.kind, r.label || "", r.act || "", r.page || "", r.key || "", r.value || ""].join("|")
      }
      function keyMenuIndex(rows) {
        for (var i = 0; i < rows.length; i++) if (win.rowKey(rows[i]) === win.menuKeyKey) return i
        return -1
      }

      function keyMenuSelect(row) {
        win.menuKeyRow = row
        win.menuKeyKey = row ? win.rowKey(row) : ""
        // Keep a window row in view when the window list scrolls.
        if (row && row.kind === "window") {
          var at = menuColumn.windowRows.indexOf(row)
          if (at !== -1) {
            var top = at * 32
            if (top < windowList.contentY) windowList.contentY = top
            else if (top + 32 > windowList.contentY + windowList.height) windowList.contentY = top + 32 - windowList.height
          }
        }
      }

      // A new page of rows: highlight the row we came back from, else the first real choice
      // (not the "back" row, which Esc is for).
      onMenuListChanged: if (win.menuByKey) {
        var rows = win.keyMenuRows()
        var pick = null
        if (win.menuReturnKey !== "") {
          for (var i = 0; i < rows.length && !pick; i++) if (win.rowKey(rows[i]) === win.menuReturnKey) pick = rows[i]
          if (pick) win.menuReturnKey = ""      // (the page we're going into doesn't have it: keep it for the way back)
        }
        for (var j = 0; j < rows.length && !pick; j++) if (rows[j].kind !== "back") pick = rows[j]
        win.keyMenuSelect(pick || (rows.length > 0 ? rows[0] : null))
      }

      // Shift+Enter, the Menu key or Shift+F10 on the highlighted icon.
      function keyOpenMenu() {
        var button = win.kbButton
        if (!button) return
        win.openMenu(button, button.item, button.isFolder)
        win.menuByKey = true
        var rows = win.keyMenuRows()
        win.keyMenuSelect(rows.length > 0 ? rows[0] : null)
      }

      function keyMenuMove(delta) {
        var rows = win.keyMenuRows()
        if (rows.length === 0) return
        var at = win.keyMenuIndex(rows)
        win.keyMenuSelect(rows[(at === -1 ? (delta > 0 ? 0 : rows.length - 1) : at + delta + rows.length) % rows.length])
      }

      function keyMenuEdge(last) {
        var rows = win.keyMenuRows()
        if (rows.length > 0) win.keyMenuSelect(rows[last ? rows.length - 1 : 0])
      }

      // The keys of an open menu, whichever way it was opened (a keyboard-opened one gets them
      // through keyCatcher; a mouse-opened one through the menu's own window, which is where
      // the keyboard goes while the menu's focus grab is on). Returns whether the key was used.
      function menuKey(event) {
        switch (event.key) {
        case Qt.Key_Up: win.keyMenuMove(-1); return true
        case Qt.Key_Down: win.keyMenuMove(1); return true
        case Qt.Key_Home: win.keyMenuEdge(false); return true
        case Qt.Key_End: win.keyMenuEdge(true); return true
        case Qt.Key_Return: case Qt.Key_Enter:
          if (win.menuKeyRow) win.handleMenuRow(win.menuKeyRow)
          return true
        case Qt.Key_Escape: win.keyMenuBack(); return true
        }
        return false
      }

      // Esc: back one level (submenu -> menu, "empty the Trash?" -> menu, menu -> the dock).
      function keyMenuBack() {
        var back = win.menuList.filter(function(r) { return r.kind === "back" })
        if (back.length > 0) { win.handleMenuRow(back[0]); return }
        if (win.menuConfirming) {
          win.menuConfirming = false
          win.menuList = root.menuRows(win.menuItem, win.menuIsFolder)
          return
        }
        win.closeKeyMenu()
      }

      // Back to the dock's keyboard mode, with the same icon highlighted (also used when an icon
      // is clicked while the menu is open: that click is used up by closing the menu).
      function closeKeyMenu() {
        win.closeMenu(true)
        if (win.keyMode && win.kbButton) win.showTip(win.kbButton, win.kbButton.label, true)
      }

      // A menu or stack just closed in keyboard mode. If a click had moved the keyboard into its
      // window, nothing would hand it back to the dock: take it again (Exclusive, then on-demand
      // once it's there, like when keyboard mode starts).
      function reclaimKeyboard() {
        if (!win.keyMode) return
        win.keyHeld = false
        keyReclaim.restart()
      }
      Timer {
        id: keyReclaim
        interval: 200
        onTriggered: if (win.keyMode) win.keyHeld = true
      }

      // The highlighted icon can vanish (its app leaves Recent, the config changes): the
      // highlight moves to the icon now at its place, or the mode ends if none is left.
      property int keyLastIndex: 0
      Timer {
        id: keyRecheck
        interval: 120
        onTriggered: {
          if (!win.keyMode || win.menuByKey || win.stackByKey) return
          var list = win.keyButtons()
          if (list.length === 0) { win.exitKeyMode(); return }
          if (list.indexOf(win.kbButton) === -1) win.keySelect(list[Math.min(win.keyLastIndex, list.length - 1)])
        }
      }

      function keySelect(button) {
        if (win.kbButton === button && win.tipText !== "") return   // already there: leave the label alone
        win.kbButton = button
        win.keyLastIndex = win.keyButtons().indexOf(button)
        win.keyReveal(button)
        win.showTip(button, button.label, true)
      }

      // In a dock that scrolls (too many icons to fit), bring the highlighted icon into view.
      function keyReveal(button) {
        if (!win.overflowing) return
        var x = button.mapToItem(rowView.contentItem, 0, 0).x
        var margin = 12
        if (x - margin < rowView.contentX) rowView.contentX = Math.max(0, x - margin)
        else if (x + button.width + margin > rowView.contentX + rowView.width)
          rowView.contentX = Math.min(rowView.maxX, x + button.width + margin - rowView.width)
      }

      // Typing jumps to an icon by name. One letter goes to the next icon starting with it (the same
      // letter again, to the one after); several letters typed in a row narrow it down ("lo" for
      // LocalSend). The letters are forgotten after a second. Case and accents don't matter.
      property string keyTyped: ""
      Timer {
        id: keyTypedReset
        interval: 1000
        onTriggered: win.keyTyped = ""
      }

      // Lower case without accents (and the Turkish dotless i as i), so "o" finds "Öğrenci".
      function keyFold(text) {
        var s = text.toLowerCase().replace(/\u0131/g, "i")
        try { s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "") } catch (e) {}
        return s
      }

      function keyTypeEvent(event) {
        var t = event.text
        var plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
        if (!plain || t.length !== 1 || t.charCodeAt(0) < 32 || (t === " " && win.keyTyped === "")) {
          event.accepted = false
          return
        }
        event.accepted = true
        var list = win.keyButtons()
        var n = list.length
        if (n === 0) return
        var typed = win.keyTyped + t
        var cycling = typed.split("").every(function(c) { return c.toLowerCase() === typed[0].toLowerCase() })
        var prefix = win.keyFold(cycling ? t : typed)
        var at = Math.max(0, list.indexOf(win.kbButton))
        var found = null
        for (var i = cycling ? 1 : 0; i <= n && !found; i++) {
          var b = list[(at + i) % n]
          if (win.keyFold(b.label).indexOf(prefix) === 0) found = b
        }
        win.keyTyped = typed
        keyTypedReset.restart()
        if (found) win.keySelect(found)
      }

      function keyMove(delta) {
        var list = win.keyButtons()
        if (list.length === 0) return
        var at = list.indexOf(win.kbButton)
        win.keySelect(list[(at + delta + list.length) % list.length])   // wraps around
      }

      function keyEdge(last) {
        var list = win.keyButtons()
        if (list.length > 0) win.keySelect(list[last ? list.length - 1 : 0])
      }

      // Tab: the first icon of the next (or previous) section, wrapping around.
      function keySection_step(dir) {
        var list = win.keyButtons()
        if (list.length === 0) return
        var sections = []
        for (var i = 0; i < list.length; i++) {
          var s = win.keySection(list[i])
          if (sections.indexOf(s) === -1) sections.push(s)
        }
        var at = sections.indexOf(win.keySection(win.kbButton))
        var target = sections[(at + dir + sections.length) % sections.length]
        for (var j = 0; j < list.length; j++) {
          if (win.keySection(list[j]) === target) { win.keySelect(list[j]); return }
        }
      }

      // Enter: what a click does. The dock lets go of the keyboard first, so the app or
      // stack that follows gets it.
      function keyActivate() {
        var button = win.kbButton
        if (!button) return
        // A folder's stack opens right here and takes the arrow keys; the rest ends keyboard mode.
        if (button.isFolder && !root.isTrash(button.item)) {
          if (root.isMissing(button.item)) win.keyOpenMenu()      // explains, offers removal
          else win.keyOpenStack(button)
          return
        }
        win.exitKeyMode()
        Qt.callLater(function() {
          if (button.isFolder) win.folderClicked(button, button.item)
          else root.activate(button.item, win.screen)
        })
      }

      Item {
        id: keyCatcher
        focus: win.keyMode
        Window.onActiveChanged: {
          if (!win.keyMode) return
          if (Window.active) win.keyHeld = true
          else if (win.keyReleased && !win.settingsOpen) win.exitKeyMode()   // (Dock Settings has the keyboard meanwhile)
        }
        Keys.onPressed: function(event) {
          if (!win.keyMode) return
          event.accepted = true
          if (win.menuByKey) {
            event.accepted = win.menuKey(event)
            return
          }
          if (win.stackByKey) {
            event.accepted = win.stackKey(event)
            return
          }
          switch (event.key) {
          case Qt.Key_Left: case Qt.Key_Up: win.keyMove(-1); break
          case Qt.Key_Right: case Qt.Key_Down: win.keyMove(1); break
          case Qt.Key_Home: win.keyEdge(false); break
          case Qt.Key_End: win.keyEdge(true); break
          // (Shift+Tab arrives as Backtab, or as Tab with Shift held, depending on the keyboard.)
          case Qt.Key_Tab: win.keySection_step(event.modifiers & Qt.ShiftModifier ? -1 : 1); break
          case Qt.Key_Backtab: win.keySection_step(-1); break
          case Qt.Key_Return: case Qt.Key_Enter:
            if (event.modifiers & Qt.ShiftModifier) win.keyOpenMenu()
            else win.keyActivate()
            break
          case Qt.Key_Menu: win.keyOpenMenu(); break
          // Ctrl+comma: Dock Settings. Ctrl+H: hide or show the dock automatically. Ctrl is for the
          // dock itself, Shift for the highlighted icon.
          case Qt.Key_Comma:
            if (event.modifiers & Qt.ControlModifier) win.openSettings()
            else win.keyTypeEvent(event)
            break
          case Qt.Key_H:
            if (event.modifiers & Qt.ControlModifier) {
              // Keyboard mode only exists while the dock is on screen: turning hiding on ends it (the
              // dock then hides, and Super+D brings it back); turning it off leaves it on.
              var hide = !root.autoHide
              root.setSetting("autoHide", hide, true)
              if (hide) win.exitKeyMode()
            } else win.keyTypeEvent(event)
            break
          case Qt.Key_F10:
            if (event.modifiers & Qt.ShiftModifier) win.keyOpenMenu()
            else event.accepted = false
            break
          case Qt.Key_Escape: win.exitKeyMode(); break
          default: win.keyTypeEvent(event)
          }
        }
      }

      // Keyboard mode lasts exactly as long as the dock holds the keyboard. Clicking another
      // window (or switching workspace) takes it away and ends the mode. No focus grab: a grab
      // also cuts the pointer off from every other window. With follow_mouse 2 (set while the
      // mode is on, see scripts/keep-cursor.sh) merely hovering another window doesn't take
      // the keyboard, and the pointer keeps working there.
      property bool keyHeld: false        // the dock has the keyboard
      property bool keyPrepared: false    // follow_mouse is already set (see keep-cursor.sh)
      // Let go of Exclusive only when both are true: if follow_mouse were still 1 at that
      // moment, Hyprland would hand the keyboard to the window under the pointer.
      readonly property bool keyReleased: keyHeld && keyPrepared
      Process {
        id: keySetup
        command: ["bash", root.script("keep-cursor.sh"), "off"]
        onExited: win.keyPrepared = true
      }
      Timer {
        id: keyGiveUp
        interval: 1500
        onTriggered: if (win.keyMode && !win.keyHeld) win.exitKeyMode()   // the keyboard never came
      }

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

      // The settings dialog's keys: Tab/Shift+Tab (or Down/Up) move between the controls, Left/Right
      // change a slider, Space or Enter toggles a switch, Enter presses a button, Esc closes.
      function settingsKey(event) {
        var last = 8
        var step = function(dir) {
          var next = win.settingsFocus
          do { next = (next + dir + last + 1) % (last + 1) } while (next === 3 && !root.autoHide)  // (no delay without hiding)
          win.settingsFocus = next
        }
        var switches = { 1: "dividerResize", 2: "autoHide", 4: "showApps", 5: "showRecent", 6: "animateLaunch" }
        switch (event.key) {
        case Qt.Key_Escape: win.closeSettings(); return true
        case Qt.Key_Tab: step(event.modifiers & Qt.ShiftModifier ? -1 : 1); return true
        case Qt.Key_Backtab: case Qt.Key_Up: step(-1); return true
        case Qt.Key_Down: step(1); return true
        case Qt.Key_Left: case Qt.Key_Right:
          var dir = event.key === Qt.Key_Right ? 1 : -1
          if (win.settingsFocus === 0) root.setSetting("iconSize", Math.max(32, Math.min(72, root.iconSize + dir * 4)), true)
          else if (win.settingsFocus === 3) root.setSetting("hideDelay", Math.max(0, Math.min(2000, root.hideDelay + dir * 100)), true)
          return true
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
          if (switches[win.settingsFocus] !== undefined) root.setSetting(switches[win.settingsFocus], !root[switches[win.settingsFocus]], true)
          else if (event.key !== Qt.Key_Space && win.settingsFocus === 7) root.resetSettings()   // (buttons: Enter only)
          else if (event.key !== Qt.Key_Space && win.settingsFocus === 8) win.closeSettings()
          return true
        }
        return false
      }

      function openSettings() {
        win.tipText = ""
        win.settingsFocus = 0
        win.revealed = true
        win.settingsOpen = true
      }

      function closeSettings() {
        win.settingsOpen = false
        hideTimer.restart()
        // Opened from keyboard mode (Ctrl+comma): back to the dock, the same icon highlighted.
        if (win.keyMode) {
          win.reclaimKeyboard()
          if (win.kbButton) win.showTip(win.kbButton, win.kbButton.label, true)
        }
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
      property bool dividerResizing: false    // a divider is being dragged to resize (DockDivider)
      function restartHideTimer() { hideTimer.restart() }

      property bool stackOpen: false
      property bool stackDragging: false      // a file is being dragged out of the stack
      property Item stackTarget: null
      property var stackFolder: null

      function folderClicked(button, folder) {
        // Clicking the folder again closes its open stack.
        if (win.stackOpen && win.stackFolder && win.stackFolder.path === folder.path) {
          win.closeStack()
          return
        }
        if (root.isMissing(folder)) win.openMenu(button, folder, true)   // explains, offers removal
        else if (root.isTrash(folder)) root.openFolder(folder)
        else win.openStack(button, folder)
      }

      function openStack(button, folder) {
        win.tipText = ""
        win.stackTarget = button
        win.stackFolder = folder
        root.stackOpenDir = root.expandPath(folder.path)
        root.previewChecked = ({})          // check the stack's previews afresh
        root.refreshFolders()
        win.stackOpen = true
      }

      // byOutsideClick: closed by clicking elsewhere, so that same click is ignored by the
      // dock (see justClosedPopup); not when closed by choosing something in it.
      function closeStack(byOutsideClick) {
        if (win.stackOpen && byOutsideClick) win.popupClosedAt = Date.now()
        win.stackOpen = false
        win.reclaimKeyboard()
        win.stackByKey = false
        win.stackKeyIndex = -1
        win.stackButtonFocus = false
        root.stackOpenDir = ""
        root.dropPreviewQueue()
        hideTimer.restart()
      }

      // Menu rows that change the menu itself instead of running an action.
      function handleMenuRow(row) {
        if (row.disabled || row.kind === "text" || row.kind === "separator") return
        if (row.kind === "submenu") {
          win.menuReturnKey = win.rowKey(row)
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
          win.exitKeyMode()
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
          win.exitKeyMode()
          win.openSettings()
          return
        }
        // Moving an icon left or right keeps the menu open, to move it on.
        if (row.act === "left" || row.act === "right" || row.act === "folder-left" || row.act === "folder-right") {
          root.runRow(row, win.menuItem, win.screen)
          Qt.callLater(function() { win.refreshMoveMenu(row) })
          return
        }
        var item = win.menuItem
        var byKey = win.menuByKey
        win.closeMenu()
        // From keyboard mode, "Cancel" goes back to the dock; anything else is done and ends it.
        if (row.act === "cancel" && byKey) { if (win.kbButton) win.showTip(win.kbButton, win.kbButton.label, true); return }
        win.exitKeyMode()
        if (row.act !== "cancel") root.runRow(row, item, win.screen)
      }

      // After a move: rebuild the open menu (an end of the dock has no further move one way),
      // keep the highlight on the same row or, if it's gone, on the opposite move, and bring the
      // menu along with the icon, which slides to its new place.
      function refreshMoveMenu(movedRow) {
        if (!win.menuOpen || !win.menuItem) return
        if (!win.menuIsFolder && root.itemsByKey[win.menuItem.key]) win.menuItem = root.itemsByKey[win.menuItem.key]
        win.menuList = root.menuRows(win.menuItem, win.menuIsFolder)
        if (win.menuByKey || win.menuKeyKey !== "") {
          var rows = win.keyMenuRows()
          var opposite = { "left": "right", "right": "left", "folder-left": "folder-right", "folder-right": "folder-left" }[movedRow.act]
          var target = null
          for (var i = 0; i < rows.length && !target; i++) if (win.rowKey(rows[i]) === win.rowKey(movedRow)) target = rows[i]
          for (var j = 0; j < rows.length && !target; j++) if (rows[j].act === opposite) target = rows[j]
          if (target) win.keyMenuSelect(target)
        }
        menuReanchor.restart()
      }
      Timer {
        id: menuReanchor
        interval: 280
        onTriggered: if (win.menuOpen) menu.anchor.updateAnchor()
      }

      // Trash count arrives asynchronously; refresh the open Trash menu when it does.
      Connections {
        target: root
        function onTrashCountChanged() {
          if (win.menuOpen && win.menuIsFolder && !win.menuConfirming && root.isTrash(win.menuItem))
            win.menuList = root.menuRows(win.menuItem, true)
        }
        // Apps opening or closing mid-drag change the icons' order; drop the drag rather
        // than move the wrong one. (Not on items: that is rebuilt whenever any window's
        // title changes, which would end a drag at random.)
        function onLayoutChanged() {
          if (win.keyMode) keyRecheck.restart()
          if (win.dragFrom !== -1 && !win.dragFolder) win.cancelDrag()
        }
        function onFoldersChanged() {
          if (win.dragFrom !== -1 && win.dragFolder) win.cancelDrag()
        }

      }

      function beginDrag(index, icon) {
        var item = root.items[index]
        win.tipText = ""
        win.dragIcon = icon
        win.dragName = item ? item.name : ""
        // Pinned apps that aren't running, and recently used ones in the middle section, can
        // be pulled out to remove them. Running apps only slide sideways (unpin those from
        // their menu).
        win.dragRemovable = !!item && !root.isFixed(item.key) && item.windows.length === 0
          && (item.pinned || root.isRecent(item.key))
        win.dragTopY = zone.y + dockBox.y
        win.dragSlot = root.iconSource(icon)
        win.dragFiles = []
        win.dragMissing = false
        win.dragFolder = false
        win.dragFrom = index
        win.dragTo = index
        win.dragToPinned = false
      }

      // Folders move among the folders; any but the Trash (always last) can be pulled out.
      function beginFolderDrag(index, icon, slotUrl, files) {
        var folder = root.folders[index]
        if (!folder || root.isTrash(folder)) return false
        win.tipText = ""
        win.dragFiles = files || []
        win.dragMissing = root.isMissing(folder)
        // A pile is drawn at its slot's size (see DockButton).
        win.dragIcon = win.dragFiles.length > 0 ? slotUrl : icon
        win.dragName = folder.name || ""
        win.dragRemovable = true
        win.dragTopY = zone.y + dockBox.y
        win.dragSlot = slotUrl
        win.dragFolder = true
        win.dragToPinned = false
        win.dragFrom = index
        win.dragTo = index
        return true
      }

      // `point` is in the app row's coordinates.
      function updateDrag(point) {
        var scene = row.mapToItem(null, point.x, point.y)
        win.dragSceneX = scene.x
        win.dragSceneY = scene.y
        // Pulled out to remove: no longer being dragged in among the pinned apps.
        if (win.dragRemoving) win.dragToPinned = false
        else updateDragTarget(point.x)
        updateAutoScroll(point.x)
      }

      // Dragging near an edge of a scrolling dock scrolls it that way, faster nearer the
      // edge (up to autoScrollMax px per frame); the landing gap follows along.
      property real autoScrollSpeed: 0
      readonly property int autoScrollMax: 10
      function updateAutoScroll(rowX) {
        var edge = Math.min(2 * win.size, rowView.width / 4)
        var inView = row.x + rowX - rowView.contentX
        var speed = 0
        if (win.overflowing && !win.dragRemoving) {
          if (inView < edge) speed = -win.autoScrollMax * (1 - Math.max(0, inView) / edge)
          else if (inView > rowView.width - edge)
            speed = win.autoScrollMax * (1 - Math.max(0, rowView.width - inView) / edge)
        }
        win.autoScrollSpeed = speed
      }
      Timer {
        interval: 16
        repeat: true
        running: win.dragFrom !== -1 && win.autoScrollSpeed !== 0
        onTriggered: {
          rowView.cancelFlick()
          rowView.contentX = Math.max(0, Math.min(rowView.maxX, rowView.contentX + win.autoScrollSpeed))
          // The pointer hasn't moved, but the icons have moved under it.
          var p = row.mapFromItem(null, win.dragSceneX, win.dragSceneY)
          win.updateDragTarget(p.x)
          win.updateAutoScroll(p.x)
        }
      }

      // Where a dragged app would land. Pinned apps move among the pinned apps; an app from
      // the middle section can be dragged in among the pinned apps (pinning it there), and
      // otherwise stays where it is: the middle section keeps its own order.
      function updateDragTarget(rowX) {
        win.dragX = rowX
        if (win.dragFolder) { updateFolderDragTarget(rowX); return }
        var from = win.dragFrom
        var pinnedCount = root.middleStart
        var fromMiddle = from >= pinnedCount
        // Pinned positions it could land at: after the file manager, up to the end of the
        // pinned apps.
        var first = 1
        var last = fromMiddle ? pinnedCount : pinnedCount - 1
        // Slots can differ in width, so try the dragged icon at each position among the
        // other pinned apps and pick the one whose middle is closest to the pointer.
        var best = first
        var bestDistance = Infinity
        var left = 0
        var k = 0
        for (var i = 0; i < pinnedCount && k <= last; i++) {
          if (i === from) continue
          if (k >= first) {
            var distance = Math.abs(rowX - (left + win.dragWidth / 2))
            if (distance < bestDistance) { bestDistance = distance; best = k }
          }
          left += root.slotWidthFor(root.pickIcon(root.items[i].icons), win.size)
          k++
        }
        if (k <= last && k >= first) {
          var end = Math.abs(rowX - (left + win.dragWidth / 2))
          if (end < bestDistance) { bestDistance = end; best = k }
        }
        // From the middle section, staying where it is counts as one more spot: at its own
        // place, past the divider. Whichever spot is closest to the pointer wins, so the
        // zone that means "pin it last" reaches halfway to its own place, not just to the
        // divider (which made it a narrow strip to hit).
        if (fromMiddle) {
          var ownLeft = root.hasMiddle ? root.dividerWidthFor(win.size) : 0
          for (var j = 0; j < from; j++) ownLeft += root.slotWidthFor(root.pickIcon(root.items[j].icons), win.size)
          var stay = Math.abs(rowX - (ownLeft + win.dragWidth / 2))
          win.dragToPinned = bestDistance < stay
          win.dragTo = win.dragToPinned ? Math.max(first, Math.min(last, best)) : from
          return
        }
        win.dragTo = Math.max(first, Math.min(last, best))
      }

      // Where a dragged folder would land among the other folders (the Trash stays last).
      // Over the apps, that's the first spot: like apps over the folders, it lands at the
      // nearest end of its own section.
      function updateFolderDragTarget(rowX) {
        var from = win.dragFrom
        var start = divider.x + divider.width
        var count = root.folders.length
        var last = count - 1
        if (count > 0 && root.isTrash(root.folders[count - 1])) last--
        var best = from
        var bestDistance = Infinity
        var left = start
        var k = 0
        for (var i = 0; i <= last + 1 && k <= last; i++) {
          if (i === from) continue
          var distance = Math.abs(rowX - (left + win.dragWidth / 2))
          if (distance < bestDistance) { bestDistance = distance; best = k }
          if (i < count) left += root.slotWidthFor(root.slotSourceFor(root.folders[i], true), win.size)
          k++
        }
        win.dragTo = Math.max(0, Math.min(last, best))
      }

      function endDrag() {
        if (win.dragFolder) { endFolderDrag(); return }
        win.autoScrollSpeed = 0
        var from = win.dragFrom
        var to = win.dragTo
        var removing = win.dragRemoving
        var toPinned = win.dragToPinned
        if (removing) poof.play(dragGhost.x, dragGhost.y, dragGhost.source, dragGhost.width)
        // Everything is already where it belongs (the gap opened or closed while dragging),
        // so the slide-aside offsets are dropped without animating, and a pulled-out icon
        // goes without its leaving animation.
        win.snapShifts = true
        Qt.callLater(function() { win.snapShifts = false })
        win.dragToPinned = false
        win.dragFrom = -1
        win.dragTo = -1
        if (from !== -1 && from < root.items.length) {
          var key = root.items[from].key
          var fromMiddle = from >= root.middleStart
          if (removing || (fromMiddle && toPinned)) {
            // Already gone from its spot on screen (pulled out, or dragged into the pinned
            // apps): no leaving animation.
            var instant = Object.assign({}, root.removeInstantly)
            instant[key] = true
            root.removeInstantly = instant
          }
          if (removing) {
            if (root.isRecent(key)) root.forgetRecent(key)
            else root.unpin(key)
          } else if (fromMiddle) {
            if (toPinned) root.pin(key, to)
          } else if (to !== from) {
            root.moveTo(key, to)
          }
        }
        hideTimer.restart()
      }

      function endFolderDrag() {
        win.autoScrollSpeed = 0
        var from = win.dragFrom
        var to = win.dragTo
        var removing = win.dragRemoving
        if (removing) poof.play(dragGhost.x, dragGhost.y, dragGhost.source, dragGhost.width, win.dragFiles,
                                root.artWidthFor(root.iconSource(win.dragIcon), win.size))
        win.snapShifts = true
        Qt.callLater(function() { win.snapShifts = false })
        win.dragFrom = -1
        win.dragTo = -1
        win.dragFolder = false
        win.dragFiles = []
        var folder = root.folders[from]
        if (folder) {
          if (removing) root.removeFolder(folder.path)
          else if (to !== from) root.moveFolder(from, to)
        }
        hideTimer.restart()
      }

      function cancelDrag() {
        win.autoScrollSpeed = 0
        win.dragFolder = false
        win.dragToPinned = false
        win.dragFrom = -1
        win.dragTo = -1
        hideTimer.restart()
      }

      function dropEnter(d) {
        win.dropDepth += 1
        if (d && d.hasUrls) win.lookUpDrop(d.urls)
        win.reveal()
      }

      function dropLeave() {
        win.dropDepth = Math.max(0, win.dropDepth - 1)
        // (Checked after the event: moving from one drop area to the next can leave the
        // old one before entering the new one.)
        if (win.dropDepth === 0) Qt.callLater(function() {
          if (win.dropDepth !== 0) return
          win.dropInsert = -1
          win.dropPendingInsert = -1
          gapDwell.stop()
          win.dropOverFolders = false
          win.dropOnFolderIcon = 0
          dropForget.restart()
        })
        hideTimer.restart()
      }
      // The next drag is looked up afresh (the folders may have changed by then).
      Timer {
        id: dropForget
        interval: 1000
        onTriggered: if (win.dropDepth === 0 && win.pendingInsert === -2) win.dropKey = ""
      }

      function closeMenu(byOutsideClick) {
        if (win.menuOpen && byOutsideClick) win.popupClosedAt = Date.now()
        win.menuOpen = false
        win.reclaimKeyboard()
        win.menuByKey = false
        win.menuKeyRow = null
        win.menuKeyKey = ""
        win.menuReturnKey = ""
        hideTimer.restart()
      }

      // When a menu is dismissed by clicking elsewhere on the dock, that same click
      // arrives right after; icons use this to ignore it.
      property real popupClosedAt: 0
      function justClosedPopup() {
        return Date.now() - win.popupClosedAt < 300
      }

      // fromKey: the label of the icon chosen with the keyboard. In keyboard mode the pointer's
      // own labels are ignored (a pointer resting on an icon would override the keyboard's).
      function showTip(button, text, fromKey) {
        if (win.menuOpen || win.stackOpen) return
        if (win.keyMode && !fromKey) return
        win.tipTarget = button
        win.tipText = text
      }

      function hideTip(button) {
        if (win.keyMode) return
        if (win.tipTarget === button) win.tipText = ""
      }

      Timer {
        id: hideTimer
        // At least 150 ms even for "Immediately": with 0 the dock could hide in the instant
        // between the pointer leaving the edge strip and entering the dock.
        interval: Math.max(150, root.hideDelay)
        onTriggered: {
          if (!win.hidingNow || win.settingsOpen) return
          if (zoneHover.hovered || hotspot.containsMouse || win.menuOpen || win.stackOpen || win.keyMode) return
          if (win.dragFrom !== -1 || win.dropDepth > 0 || win.dividerResizing) return
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
          onEntered: function(d) { win.dropEnter(d) }
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
          radius: root.radiusFor(win.size)

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
          // (A scrolling dock stays full width: it still overflows without the pulled-out icon.)
          width: Math.min(win.rowWidth - (win.dragRemoving ? win.dragWidth : 0), win.maxDockWidth)
          height: win.dockHeightFor(win.size)
          color: "transparent"
          border.color: root.hairline
          border.width: 1
          radius: root.radiusFor(win.size)
          transform: Scale {
            origin.x: dockBox.width / 2
            origin.y: dockBox.height
            xScale: win.previewScaleX
            yScale: win.previewScaleY
          }

          Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          // Animated only while an icon is being dragged, so pulling it out closes the dock
          // in smoothly (with the icons sliding over). Otherwise the width changes in the same
          // frame as the icons: animating it then would only make the outline lag behind them
          // and slide the icons sideways while it re-centers.
          Behavior on width {
            enabled: win.dragFrom !== -1 && !win.snapShifts
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
          }


          // The icons, in a view that scrolls sideways only when the dock overflows the
          // screen (see win.overflowing). Icons fade out toward an edge with more beyond it
          // (see DockButton's edgeFade).
          Flickable {
            id: rowView
            anchors.fill: parent
            contentWidth: win.rowWidth
            contentHeight: height
            // Qt's own scrolling (with momentum, like the menus and stacks) for sideways
            // swipes; up/down scrolling is turned sideways by the layer below.
            interactive: win.overflowing
            boundsBehavior: Flickable.StopAtBounds
            clip: win.overflowing

            readonly property real maxX: Math.max(0, contentWidth - width)

          // Folders dragged in between the folders (or onto the edges of their icons; the
          // middle of an icon moves them into that folder, see DockButton) get shortcuts
          // there. Under the icons, so their own drop areas come first.
          DropArea {
            x: row.x + divider.x
            y: 0
            width: win.rowWidth - x
            height: rowView.height
            visible: root.folders.length > 0
            keys: ["text/uri-list"]
            function rowX(d) { return d.x + x - row.x }
            onEntered: function(d) {
              win.dropEnter(d)
              d.accept(Qt.CopyAction)
              win.dropOverFolders = true
              win.updateDropInsert(rowX(d))
            }
            onPositionChanged: function(d) { win.updateDropInsert(rowX(d)) }
            onExited: {
              win.dropOverFolders = false
              win.settleDropGap()
              win.dropLeave()
            }
            onDropped: function(d) {
              d.accept(Qt.CopyAction)
              // (Dropped before the gap had time to open: where it would have opened.)
              var at = gapDwell.running || win.dropInsert < 0 ? win.dropPendingInsert : win.dropInsert
              gapDwell.stop()
              // New shortcuts take the gap's place without sliding; with nothing new (only
              // folders already in the dock, which bounce), the gap eases closed.
              if (win.dropHasNewFolders) {
                win.snapShifts = true
                Qt.callLater(function() { win.snapShifts = false })
              }
              win.dropFoldersAt(at)
              win.dropOverFolders = false
              win.dropInsert = -1
              win.dropLeave()
            }
          }

          Row {
            id: row
            // Pinned to the left padding rather than centered, so a dock that shrinks while
            // an icon is pulled out closes in from both ends evenly.
            x: root.leftPadFor(win.size)
            y: Math.round((rowView.height - implicitHeight) / 2)
            spacing: 0

            Repeater {
              model: iconModel
              delegate: DockButton {
                required property string key
                required property bool leaving
                required property bool appearing
                // A leaving icon's app is gone from root.items: it keeps its last look.
                readonly property var liveItem: root.itemsByKey[key] || null
                property var keptItem: null
                onLiveItemChanged: if (liveItem) keptItem = liveItem
                dock: root
                window: win
                item: liveItem || keptItem || { key: key, name: "", icons: [root.letterIcon], windows: [], pinned: false }
                slot: leaving ? -1 : root.layout.indexOf(key)
                isLeaving: leaving
                animateIn: appearing
              }
            }

            // Divider between apps and folders (see DockDivider.qml).
            DockDivider {
              id: divider
              dock: root
              window: win
              visible: root.folders.length > 0
              // Wide enough that the gap on each side of the line matches the gap between two
              // icons, like macOS (see dividerWidthFor).
              width: root.dividerWidthFor(win.size)
              anchors.verticalCenter: parent.verticalCenter
              // Slides left with the folders while an app is being pulled out to remove.
              transform: Translate {
                x: win.dragRemoving && !win.dragFolder ? -win.dragWidth : 0
                Behavior on x {
                  enabled: !win.snapShifts
                  NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
              }
            }

            Repeater {
              model: root.folders
              delegate: DockButton {
                required property var modelData
                required property int index
                dock: root
                window: win
                item: modelData
                isFolder: true
                folderIndex: index
              }
            }
          }
          }

          // Up/down scrolling when the dock overflows, turned into sideways scrolling with
          // the same momentum as Qt's own: a layer over the whole dock that only takes scroll
          // events (clicks, hovering and dropped files pass through to the icons). Sideways
          // swipes pass through to rowView, which scrolls them itself.
          MouseArea {
            id: scrollLayer
            anchors.fill: parent
            enabled: win.overflowing
            acceptedButtons: Qt.NoButton

            // A wheel notch flicks as far as Qt's own does sideways (~72 px); each notch
            // restarts the glide at that speed, as Qt's does (measured: 3 quick notches move
            // about 135 px either way). Velocities are Qt's: positive moves the icons back
            // toward the start.
            readonly property real notchVelocity: 465
            // Notches in quick succession (spinning the wheel) get a small boost each, up to
            // six, as Qt's do; tuned against Qt's own sideways scrolling (3, 6 and 10 quick
            // notches land within about 7% of it).
            readonly property real streakBoost: 0.12
            property real lastNotchAt: 0
            property int notchStreak: 0
            property real lastStep: 0
            // Touchpad: follow the fingers, then glide on at the speed they left with.
            property var samples: []          // [{ t, d }] of the last ~100 ms

            function scrollBy(d) {
              rowView.contentX = Math.max(0, Math.min(rowView.maxX, rowView.contentX - d))
            }

            onWheel: function(e) {
              var dx = e.pixelDelta.x || e.angleDelta.x
              var dy = e.pixelDelta.y || e.angleDelta.y
              if (Math.abs(dx) > Math.abs(dy)) { e.accepted = false; return }   // sideways: Qt's
              if (e.pixelDelta.y !== 0) {
                rowView.cancelFlick()
                scrollBy(e.pixelDelta.y)
                var now = Date.now()
                samples = samples.filter(function(s) { return now - s.t < 100 }).concat([{ t: now, d: e.pixelDelta.y }])
                glideTimer.restart()
              } else if (e.angleDelta.y !== 0) {
                var step = (e.angleDelta.y / 120) * notchVelocity
                var t = Date.now()
                notchStreak = t - lastNotchAt < 150 && Math.sign(step) === Math.sign(lastStep) ? notchStreak + 1 : 0
                lastNotchAt = t
                lastStep = step
                rowView.flick(step * (1 + streakBoost * Math.min(notchStreak, 6)), 0)
              }
            }

            Timer {
              id: glideTimer
              interval: 60
              onTriggered: {
                var now = Date.now()
                var recent = scrollLayer.samples.filter(function(s) { return now - s.t < 160 })
                scrollLayer.samples = []
                if (recent.length < 2) return
                var sum = 0
                for (var i = 0; i < recent.length; i++) sum += recent[i].d
                var seconds = Math.max(0.016, (recent[recent.length - 1].t - recent[0].t) / 1000)
                var velocity = sum / seconds
                if (Math.abs(velocity) > 100)
                  rowView.flick(Math.max(-rowView.maximumFlickVelocity, Math.min(rowView.maximumFlickVelocity, velocity)), 0)
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
          // Drawn at the same normalized size as in the dock.
          width: root.drawSizeFor(root.iconSource(win.dragIcon), win.size)
          height: width
          sourceSize.width: root.iconSourceSize
          sourceSize.height: root.iconSourceSize
          source: win.dragFiles.length > 0 ? "" : root.displayableIcon(root.iconSource(win.dragIcon))
          smooth: true
          readonly property real dockLeft: zone.x + dockBox.x
          readonly property real restingY: zone.y + dockBox.y + row.y + root.padFor(win.size) - 1
            + Math.round((win.size - height) / 2)
          // The visible artwork (not the padded square) stays centered under the pointer.
          readonly property real artOffset: root.artOffsetFor(root.iconSource(win.dragIcon), win.size)
          readonly property real artOffsetY: root.artOffsetYFor(root.iconSource(win.dragIcon), win.size)
          x: (win.dragRemoving
            ? win.dragSceneX - width / 2 + artOffset
            : Math.max(dockLeft, Math.min(dockLeft + dockBox.width - width, win.dragSceneX - width / 2 + artOffset)))
            + shakeOffset
          // An icon that can't be pulled out (a running app) shakes its head when tugged
          // upward, once per tug (pulling back down re-arms it).
          readonly property real pullUp: Math.max(0, restingY - (win.dragSceneY - height / 2))
          property bool tugging: false
          onPullUpChanged: {
            if (win.dragRemovable) return
            if (!tugging && pullUp > 48) { tugging = true; shake.restart() }
            else if (tugging && pullUp < 18) tugging = false
          }
          property real shakeT: 1
          readonly property real shakeOffset: win.dragRemovable ? 0 : 7 * Math.sin(shakeT * 3 * 2 * Math.PI) * (1 - shakeT)
          NumberAnimation { id: shake; target: dragGhost; property: "shakeT"; from: 0; to: 1; duration: 400 }
          Connections {
            target: win
            function onDragFromChanged() { if (win.dragFrom === -1) { shake.stop(); dragGhost.shakeT = 1; dragGhost.tugging = false } }
          }
          y: dragLayer.offsetY + artOffsetY
             + (win.dragRemovable ? Math.min(restingY, win.dragSceneY - height / 2) : restingY)
          opacity: (win.dragRemoving ? 0.7 : 1) * (win.dragMissing ? 0.4 : 1)
        }

        MissingBadge {
          visible: dragGhost.visible && win.dragMissing
          dock: root
          iconSize: dragGhost.width
          x: dragGhost.x + dragGhost.width - width * 0.85
          y: dragGhost.y + dragGhost.height - height * 0.85
        }

        FilePile {
          visible: dragGhost.visible && win.dragFiles.length > 0
          x: dragGhost.x
          y: dragGhost.y
          width: dragGhost.width
          height: dragGhost.height
          dock: root
          files: win.dragFiles
          size: dragGhost.width
          artWidth: root.artWidthFor(root.iconSource(win.dragIcon), win.size)
          opacity: dragGhost.opacity
        }

        LetterIcon {
          visible: dragGhost.visible && win.dragIcon === root.letterIcon
          x: dragGhost.x
          y: dragGhost.y
          name: win.dragName
          size: dragGhost.width
          opacity: dragGhost.opacity
        }

        AppsIcon {
          visible: dragGhost.visible && win.dragIcon === root.appsIcon
          x: dragGhost.x
          y: dragGhost.y
          size: dragGhost.width
          accent: root.accent
          opacity: dragGhost.opacity
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
            color: root.popupText
            font.family: root.uiFont
            font.pixelSize: root.uiFontSize - 1
          }
        }

        // Removal "poof": the icon puffs up and fades where it was let go.
        Item {
          id: poof
          visible: false
          width: root.iconSize
          height: root.iconSize
          property alias source: poofImage.source
          property var files: []
          property real artWidth: width

          Image {
            id: poofImage
            anchors.fill: parent
            visible: poof.files.length === 0
            sourceSize.width: root.iconSourceSize
            sourceSize.height: root.iconSourceSize
            smooth: true
          }
          FilePile {
            anchors.fill: parent
            dock: root
            files: poof.files
            size: poof.width
            artWidth: poof.artWidth
          }

          function play(px, py, src, size, files, artWidth) {
            poof.files = files || []
            poof.artWidth = artWidth || size
            poof.source = poof.files.length > 0 ? "" : src
            poof.width = size
            poof.height = size
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
          if (right < left) { done(false); return }
          // The whole outline, for size normalization: its full width and the area it
          // covers with holes filled in (each row counted from its first to its last
          // opaque pixel).
          var fullLeft = w, fullRight = -1, hull = 0
          for (y = top; y <= bottom; y++) {
            var rowLeft = -1, rowRight = -1
            for (x = 0; x < w; x++) if (opaque(x, y)) { rowLeft = x; break }
            if (rowLeft === -1) continue
            for (x = w - 1; x >= rowLeft; x--) if (opaque(x, y)) { rowRight = x; break }
            hull += rowRight - rowLeft + 1
            fullLeft = Math.min(fullLeft, rowLeft)
            fullRight = Math.max(fullRight, rowRight)
          }
          done({ l: left / w, r: (right + 1) / w,
                 L: fullLeft / w, R: (fullRight + 1) / w, t: top / h, b: (bottom + 1) / h,
                 hull: hull / (w * h) })
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
        // Over the icon itself, not a divider drawn in front of it (see DockButton).
        anchor.rect.x: win.menuTarget && win.menuTarget.contentLeft !== undefined ? win.menuTarget.contentLeft : 0
        anchor.rect.y: root.shadowPad - root.popupGap
        anchor.rect.width: win.menuTarget ? win.menuTarget.width - (win.menuTarget.contentLeft || 0) : 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Top
        implicitWidth: menuCard.width + root.shadowPad * 2
        implicitHeight: menuCard.height + root.shadowPad * 2


        // The menu's keys when the keyboard is in this window: a menu opened with the mouse, or a
        // keyboard-opened one after a click inside it moved the keyboard here (the dock's own key
        // handler has it otherwise; only one of the two ever does).
        Item {
          focus: true
          Keys.onPressed: function(event) {
            if (!win.menuOpen) { event.accepted = false; return }
            event.accepted = win.menuKey(event)
          }
        }

        Card {
          id: menuCard
          dock: root
          x: root.shadowPad
          y: root.shadowPad
          width: Math.min(300, Math.max(180, menuColumn.naturalWidth)) + 12
          height: menuColumn.implicitHeight + 12

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

            // Many windows: the window rows scroll (wheel or touchpad) in a list capped at
            // maxWindowRows rows (or half the screen), with faded edges where more are hidden;
            // the actions below always stay in view.
            readonly property var windowRows: win.menuList.filter(function(r) { return r.kind === "window" })
            readonly property var otherRows: win.menuList.filter(function(r) { return r.kind !== "window" })
            readonly property int maxWindowRows: 10
            // How wide the widest row wants to be. (The Column's own implicitWidth can't say: every row
            // takes its width from the column, so it would only ever echo the current width.)
            readonly property real naturalWidth: {
              var w = 0
              var repeaters = [windowRepeater, otherRepeater]
              for (var r = 0; r < repeaters.length; r++)
                for (var i = 0; i < repeaters[r].count; i++) {
                  var row = repeaters[r].itemAt(i)
                  if (row) w = Math.max(w, row.implicitWidth)
                }
              return w
            }

            Flickable {
              id: windowList
              visible: menuColumn.windowRows.length > 0
              width: parent.width
              implicitWidth: windowColumn.implicitWidth
              height: Math.min(windowColumn.implicitHeight,
                               Math.min(menuColumn.maxWindowRows * 32, win.screen ? win.screen.height / 2 : 400))
              contentHeight: windowColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              readonly property bool scrolls: contentHeight > height + 0.5

              Column {
                id: windowColumn
                width: windowList.width
                Repeater {
                  id: windowRepeater
                  model: menuColumn.windowRows
                  delegate: menuRowComponent
                }
              }

              // Fades over the list's top and bottom where more windows are hidden.
              Rectangle {
                parent: windowList
                visible: windowList.scrolls && !windowList.atYBeginning
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 20
                gradient: Gradient {
                  GradientStop { position: 0; color: root.surface }
                  GradientStop { position: 1; color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0) }
                }
              }
              Rectangle {
                parent: windowList
                visible: windowList.scrolls && !windowList.atYEnd
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 20
                gradient: Gradient {
                  GradientStop { position: 0; color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 0) }
                  GradientStop { position: 1; color: root.surface }
                }
              }
            }

            Repeater {
              id: otherRepeater
              model: menuColumn.otherRows
              delegate: menuRowComponent
            }

            Component {
              id: menuRowComponent
              Item {
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
                  : label.implicitWidth + (indented ? 42 : 24) + (isSubmenu ? trailing.implicitWidth + 16 : 0)
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
                       : (rowMouse.containsMouse || (win.menuKeyKey !== "" && win.rowKey(menuRow.modelData) === win.menuKeyKey)) ? root.rowHover
                       : "transparent"
                  radius: root.rowRadius
                }

                // Leading column: check mark (focused window, selected choice) or back arrow.
                Text {
                  visible: (menuRow.isWindow && (menuRow.modelData.current || menuRow.modelData.hidden))
                        || (menuRow.isChoice && menuRow.modelData.checked) || menuRow.isBack
                  anchors.verticalCenter: parent.verticalCenter
                  x: 10
                  text: menuRow.isBack ? "‹" : (menuRow.isWindow && menuRow.modelData.hidden) ? "◇" : "✓"
                  color: root.popupText
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
                  color: root.popupText
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
                  textFormat: Text.PlainText
                  color: menuRow.modelData.danger ? root.urgent : root.popupText
                  opacity: menuRow.modelData.disabled ? 0.4 : menuRow.modelData.secondary ? 0.65 : 1
                  font.family: root.uiFont
                  font.pixelSize: menuRow.modelData.secondary ? root.uiFontSize - 1 : root.uiFontSize
                  font.weight: (menuRow.isText && !menuRow.modelData.secondary) || menuRow.isBack ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                  id: rowMouse
                  onWheel: function(w) { w.accepted = false }   // scrolling is for the window list
                  enabled: menuRow.interactive
                  anchors.fill: parent
                  hoverEnabled: true
                  // In a keyboard-opened menu the pointer moves the one highlight too.
                  onEntered: if (menuRow.interactive && (win.menuByKey || win.menuKeyKey !== "")) win.keyMenuSelect(menuRow.modelData)
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
      // (Not while a file is dragged out of it: the stack must stay until the drop.)
      HyprlandFocusGrab {
        active: win.stackOpen && !win.stackDragging && !win.stackByKey
        windows: [stackPopup]
        onCleared: win.closeStack(true)
      }

      // Any click outside the menu closes it, including on the dock itself.
      HyprlandFocusGrab {
        active: win.menuOpen && !win.menuByKey
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

        Card {
          id: settingsCard
          dock: root
          anchors.centerIn: parent
          focus: true
          Keys.onPressed: function(event) { event.accepted = win.settingsKey(event) }
          width: 360
          height: settingsColumn.implicitHeight + 32

          Column {
            id: settingsColumn
            x: 16
            y: 16
            width: parent.width - 32
            spacing: 14

            Text {
              text: "Dock Settings"
              color: root.popupText
              font.family: root.uiFont
              font.pixelSize: root.uiFontSize + 2
              font.weight: Font.DemiBold
              bottomPadding: 6     // 20 px to the first control, like the gaps around separators
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
                  color: root.popupText
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                }
                Text {
                  anchors.right: parent.right
                  text: root.iconSize + " px"
                  color: root.popupText
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
                focused: win.settingsFocus === 0
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
                text: "Drag dividers to resize"
                color: root.popupText
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: dividerSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.dividerResize
                focused: win.settingsFocus === 1
                onToggled: function(on) { root.setSetting("dividerResize", on, true) }
              }
            }

            // Between groups: a little more room than between related controls.
            Item {
              width: parent.width
              height: 13
              Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: root.hairline }
            }

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
                color: root.popupText
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: hideSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.autoHide
                focused: win.settingsFocus === 2
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
                  color: root.popupText
                  font.family: root.uiFont
                  font.pixelSize: root.uiFontSize
                }
                Text {
                  anchors.right: parent.right
                  text: root.hideDelay === 0 ? "Immediately" : (root.hideDelay / 1000).toFixed(1) + " s"
                  color: root.popupText
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
                focused: win.settingsFocus === 3
                enabledLook: root.autoHide
                onMoved: function(v) { root.setSetting("hideDelay", v, false) }
                onReleased: function(v) { root.setSetting("hideDelay", v, true) }
              }
            }

            // Between groups: a little more room than between related controls.
            Item {
              width: parent.width
              height: 13
              Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: root.hairline }
            }

            // Show the Apps icon
            Item {
              width: parent.width
              height: Math.max(appsLabel.implicitHeight, appsSwitch.implicitHeight)
              Text {
                id: appsLabel
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - appsSwitch.width - 12
                wrapMode: Text.WordWrap
                text: "Show app launcher in Dock"
                color: root.popupText
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: appsSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.showApps
                focused: win.settingsFocus === 4
                onToggled: function(on) { root.setSetting("showApps", on, true) }
              }
            }

            // Show recent apps (the middle section)
            Item {
              width: parent.width
              height: Math.max(recentLabel.implicitHeight, recentSwitch.implicitHeight)
              Text {
                id: recentLabel
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - recentSwitch.width - 12
                wrapMode: Text.WordWrap
                text: "Show recent apps in Dock"
                color: root.popupText
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: recentSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.showRecent
                focused: win.settingsFocus === 5
                onToggled: function(on) { root.setSetting("showRecent", on, true) }
              }
            }

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
                color: root.popupText
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: animSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.animateLaunch
                focused: win.settingsFocus === 6
                onToggled: function(on) { root.setSetting("animateLaunch", on, true) }
              }
            }

            // Footer buttons
            // (6 px above the buttons: 20 px from the controls, like around separators.)
            Item {
              width: parent.width
              height: 32 + 6

              Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                width: resetText.implicitWidth + 24
                height: 32
                radius: root.rowRadius
                color: resetMouse.pressed ? Util.alpha(root.foreground, 0.16)
                     : resetMouse.containsMouse || win.settingsFocus === 7 ? root.rowHover
                     : Util.alpha(root.foreground, 0.06)
                FocusRing { dock: root; shown: win.settingsFocus === 7 }
                Text {
                  id: resetText
                  anchors.centerIn: parent
                  text: "Reset to Defaults"
                  color: root.popupText
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
                anchors.bottom: parent.bottom
                width: doneText.implicitWidth + 32
                height: 32
                radius: root.rowRadius
                color: doneMouse.pressed ? Qt.darker(root.accent, 1.15)
                     : doneMouse.containsMouse ? Qt.lighter(root.accent, 1.08)
                     : root.accent
                FocusRing { dock: root; shown: win.settingsFocus === 8 }
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
          var left = win.tipTarget.contentLeft || 0     // not over a divider in front of it
          tip.anchor.rect.x = Math.round(pos.x + left + (win.tipTarget.width - left) / 2 - tip.implicitWidth / 2)
          tip.anchor.rect.y = Math.round(pos.y - tip.implicitHeight + root.shadowPad - root.popupGap)
        }
        implicitWidth: tipCard.width + root.shadowPad * 2
        implicitHeight: tipCard.height + root.shadowPad * 2

        Card {
          id: tipCard
          dock: root
          x: root.shadowPad
          y: root.shadowPad
          width: tipLabel.implicitWidth + 20
          height: tipLabel.implicitHeight + 10
          radius: root.tipRadius
          shadowOpacity: 0.35
          shadowBlur: 0.5
          shadowOffset: 1

          Text {
            id: tipLabel
            anchors.centerIn: parent
            text: win.tipText
            textFormat: Text.PlainText
            color: root.popupText
            font.family: root.uiFont
            font.pixelSize: root.uiFontSize - 1
          }
        }
      }
    }
  }
}
