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
    showRecent: true       // a middle section with running and recently used apps (like macOS)
  })
  property int iconSize: settingDefaults.iconSize
  property bool autoHide: settingDefaults.autoHide
  property int hideDelay: settingDefaults.hideDelay
  property bool animateLaunch: settingDefaults.animateLaunch
  property bool dividerResize: settingDefaults.dividerResize
  property bool showRecent: settingDefaults.showRecent

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

  // The file manager is the dock's Finder: always first, always pinned, can't be removed or
  // moved. It's the system's default one (the app that opens folders, see "places" below);
  // Omarchy's, Files (Nautilus), until that's known.
  property string fixedApp: "org.gnome.Nautilus"
  readonly property string fileManagerName: {
    var entry = DesktopEntries.byId(root.fixedApp)
    return entry && entry.name ? String(entry.name) : "Files"
  }
  // File managers the dock may have pinned first before the default changed (see normalizePins).
  readonly property var knownFileManagers: ["org.gnome.Nautilus", "thunar", "org.kde.dolphin", "nemo",
    "pcmanfm", "pcmanfm-qt", "caja", "org.xfce.thunar"]

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
        if (fm && DesktopEntries.byId(fm) && fm !== root.fixedApp) root.fixedApp = fm
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

  // Pins saved under another id (an old "org.omarchy.terminal" pin, or an aliased app id)
  // belong to the icon they're grouped under. The file manager always comes first; a
  // different file manager in first place was the fixed one before the default changed,
  // not a pin of the user's, so it goes.
  function normalizePins(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (typeof p !== "string" || p.length === 0) continue
      if (i === 0 && p !== root.fixedApp && root.knownFileManagers.indexOf(p) !== -1) continue
      var key = root.effectiveAliases[p] || p
      if (out.indexOf(key) === -1) out.push(key)
    }
    return [root.fixedApp].concat(out.filter(function(k) { return k !== root.fixedApp }))
  }

  onTerminalAppChanged: {
    var normalized = normalizePins(root.pins)
    if (JSON.stringify(normalized) !== JSON.stringify(root.pins)) {
      root.pins = normalized
      saveConfig()
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
      // First run: no config yet, so set up the default dock (see "first run").
      root.startFirstRun()
    }
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
        var id = String(text).trim().replace(/\.desktop$/, "")
        var entry = id ? DesktopEntries.byId(id) : null
        if (!entry || entry.noDisplay || id === "omarchy-browser") {
          // No default set: the first known browser that's installed.
          id = ""
          for (var i = 0; i < root.knownBrowsers.length; i++) {
            if (DesktopEntries.byId(root.knownBrowsers[i])) { id = root.knownBrowsers[i]; break }
          }
        }
        root.browserApp = id
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
          folder = Object.assign({}, folder, { name: isTrash(folder) ? root.trashName
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

    // The middle section, in order: [{ key, quitAt }] (quitAt null while the app ran).
    if (Array.isArray(cfg.recent)) {
      var middle = [], quitAt = {}
      for (var r = 0; r < cfg.recent.length; r++) {
        var entry = cfg.recent[r]
        if (!entry || typeof entry.key !== "string" || middle.indexOf(entry.key) !== -1
            || root.hiddenAppIds.indexOf(entry.key) !== -1) continue
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
      showRecent: root.showRecent
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
      recent: root.middle.map(function(k) {
        return { key: k, quitAt: root.recentQuitAt[k] !== undefined ? root.recentQuitAt[k] : null }
      }),
      aliases: root.aliases
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
    var fallback = Quickshell.iconPath("application-x-executable", true)
    if (!name) return fallback
    name = String(name)
    if (name.indexOf("://") !== -1 || name === root.letterIcon) return name   // already resolved
    if (name.charAt(0) === "/") return Util.fileUrl(name)
    return Quickshell.iconPath(name, true) || fallback
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
      else add(Quickshell.iconPath(names[n], true))
    }
    // Pixmaps only for the entry's own names, and only when the theme lacks them.
    for (var m = 0; m < pixmapNames.length; m++) {
      if (!pixmapNames[m] || Quickshell.iconPath(pixmapNames[m], true)) continue
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
    if (url === root.letterIcon) return ""
    return url.indexOf("image://") === 0 || root.iconExtents[url] ? url : ""
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
  property var iconExtents: ({ "vitrin:letter": { l: 0.095, r: 0.905, L: 0.095, R: 0.905, t: 0.095, b: 0.905, hull: 0.6561 } })
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
    root.effectiveAliases, root.windowHints, root.launcherOf)

  // Windows that aren't apps to the user, never shown in the dock: Omarchy's screensaver.
  readonly property var hiddenAppIds: ["org.omarchy.screensaver"]

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

  // The entry id a window under a shared id belongs to; null while not known yet, "" if none.
  function sharedKeyFor(toplevel) {
    var address = hyprAddressFor(toplevel)
    var id = address ? root.launcherOf[address] : undefined
    if (id === undefined) return null
    return id && DesktopEntries.byId(id) ? id : ""
  }

  function computeGroups(toplevels, _apps, _aliases, _hints, _launchers) {
    var byKey = {}
    var order = []
    var pending = false                  // some windows are left out for now (see sharedAppIds)
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t || !t.appId || root.hiddenAppIds.indexOf(t.appId) !== -1) continue
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
      key = key || keyFor(owner.appId || t.appId)
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
    var windows = item.windows
    if (windows.length === 0) {
      launch(item)
      return
    }
    var focused = -1
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].activated) focused = i
    }
    focusWindow(windows[focused === -1 ? 0 : (focused + 1) % windows.length], screen)
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
  Component.onCompleted: Quickshell.execDetached(["bash", root.script("no-warp.sh"), "restore"])

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
    if (icon && icon.charAt(0) !== "/" && Quickshell.iconPath(icon + "-full", true)) return icon + "-full"
    return icon
  }

  Process {
    id: trashCounter
    running: true                // once at startup, then see refreshTrash
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
  // Clicking a folder (except Trash) shows its newest files in a stack above it;
  // middle-click opens it in Files. Each folder has one option, saved in the config file:
  //   displayAs: "stack"  -> the dock icon shows its newest files piled up (the default)
  //              "folder" -> the dock icon is the folder icon
  // Routine refreshes (each time the dock appears, and every 15 s with hiding off) list a
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
      if (Quickshell.iconPath(icons[i], true)) return icons[i]
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
    folderLister.command = ["bash", root.script("list-folders.sh"), String(root.pileMax)].concat(dirs)
    folderLister.running = true
    if (root.stackOpenDir) refreshStack(root.stackOpenDir)
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
    onTriggered: root.refreshFolders()
  }

  // With hiding off the dock is always on screen (it never slides up, which is when the
  // other refreshes happen), so keep its stack icons and the Trash's full/empty icon current.
  Timer {
    interval: 15000
    repeat: true
    running: !root.autoHide && root.dockAllowed
    onTriggered: {
      root.refreshFolders()
      root.refreshTrash()
    }
  }

  onFoldersChanged: folderRefreshSoon.restart()

  // Records are NUL-terminated "<folder index>\t<mime type>\t<icon names>\t<path>" (so any file name,
  // even one with a tab or line break in it, comes through intact).
  function applyFolderListing(dirs, text) {
    var listing = parseFolderListing(dirs, text)
    assignIfChanged("folderFiles", listing.files)
    // A folder that's there always gets a count, even when empty.
    var missing = {}
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
  readonly property string thumbnailCache: (Quickshell.env("XDG_CACHE_HOME") || (root.home + "/.cache")) + "/thumbnails"

  // The cache names a preview after the MD5 of the file's URI, escaped the GLib way.
  function fileUri(path) {
    return ("file://" + encodeURI(path)).replace(/#/g, "%23").replace(/\?/g, "%3F")
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
      if (names[i] && names[i].indexOf("-symbolic") === -1 && Quickshell.iconPath(names[i], true)) found = names[i]
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
      if (candidates[i] && Quickshell.iconPath(candidates[i], true)) return candidates[i]
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
        folderRefreshSoon.restart()
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
    var windows = []
    for (var i = 0; i < item.windows.length; i++) {
      var w = item.windows[i]
      windows.push({ kind: "window", label: windowLabel(w), toplevel: w, current: w.activated })
    }

    var open = item.entry ? appActionRows(item) : []

    var arrange = []
    if (!isFixed(item.key)) {
      // Only pinned apps move (the middle section keeps its order). Position 0 belongs to
      // Files, so the app right after it can't move left.
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
      focusWindow(row.toplevel, screen)
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
    screen: {
      var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
      return screens.length > 0 ? screens[0] : null
    }
    visible: root.dockChoice !== "" && !root.dockChoiceMade
    anchors { top: true; bottom: true; left: true; right: true }
    color: Qt.rgba(0, 0, 0, 0.25)
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: root.slug + "-choice"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    onVisibleChanged: if (visible) choiceCard.forceActiveFocus()

    // No way around the question: clicks and scrolling outside it do nothing.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onWheel: function(w) { w.accepted = true }
    }

    Rectangle {
      id: choiceCard
      anchors.centerIn: parent
      focus: true
      // Enter takes the default, the button on the right.
      Keys.onReturnPressed: root.chooseDock(dockChoiceDialog.starting)
      Keys.onEnterPressed: root.chooseDock(dockChoiceDialog.starting)
      width: 540
      height: choiceColumn.implicitHeight + 48
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
          color: Commons.Color.popups.text
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
          color: Commons.Color.popups.text
          font.family: root.uiFont
          font.pixelSize: root.uiFontSize
          lineHeight: 1.15
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "You can switch between the two any time in the Omarchy menu, under Setup \u2192 Plugins: disable the dock you're using, then enable the other."
          color: Commons.Color.popups.text
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
                 : otherMouse.containsMouse ? root.rowHover
                 : Util.alpha(root.foreground, 0.06)
            Text {
              id: otherText
              anchors.centerIn: parent
              text: dockChoiceDialog.starting ? "Keep Omarchy's Dock" : "Keep Vitrin"
              color: Commons.Color.popups.text
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
            var lines = text.split("\n")
            for (var i = 0; i < lines.length; i++) {
              var f = lines[i].split("\t")
              if (f.length < 3) continue
              folders.push({ path: f[0], name: f[1], icons: f[2].split(",") })
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
        root.stackOpenDir = ""
        root.dropPreviewQueue()
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
        if (row.act !== "cancel") root.runRow(row, item, win.screen)
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
        // Pinned positions it could land at: after Files, up to the end of the pinned apps.
        var last = fromMiddle ? pinnedCount : pinnedCount - 1
        // Slots can differ in width, so try the dragged icon at each position among the
        // other pinned apps and pick the one whose middle is closest to the pointer.
        var best = 1
        var bestDistance = Infinity
        var left = 0
        var k = 0
        for (var i = 0; i < pinnedCount && k <= last; i++) {
          if (i === from) continue
          if (k >= 1) {
            var distance = Math.abs(rowX - (left + win.dragWidth / 2))
            if (distance < bestDistance) { bestDistance = distance; best = k }
          }
          left += root.slotWidthFor(root.pickIcon(root.items[i].icons), win.size)
          k++
        }
        if (k <= last && k >= 1) {
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
          win.dragTo = win.dragToPinned ? Math.max(1, Math.min(last, best)) : from
          return
        }
        win.dragTo = Math.max(1, Math.min(last, best))
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
          x: win.dragRemoving
            ? win.dragSceneX - width / 2 + artOffset
            : Math.max(dockLeft, Math.min(dockLeft + dockBox.width - width, win.dragSceneX - width / 2 + artOffset))
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

            // Many windows: the window rows scroll (wheel or touchpad) in a list capped at
            // maxWindowRows rows (or half the screen), with faded edges where more are hidden;
            // the actions below always stay in view.
            readonly property var windowRows: win.menuList.filter(function(r) { return r.kind === "window" })
            readonly property var otherRows: win.menuList.filter(function(r) { return r.kind !== "window" })
            readonly property int maxWindowRows: 10

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
                  onWheel: function(w) { w.accepted = false }   // scrolling is for the window list
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
      // (Not while a file is dragged out of it: the stack must stay until the drop.)
      HyprlandFocusGrab {
        active: win.stackOpen && !win.stackDragging
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
              text: "Dock Settings"
              color: Commons.Color.popups.text
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
                text: "Drag dividers to resize"
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

            // Between groups: a little more room than between related controls.
            Item {
              width: parent.width
              height: 13
              Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: root.hairline }
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
                color: Commons.Color.popups.text
                font.family: root.uiFont
                font.pixelSize: root.uiFontSize
              }
              DockSwitch {
                id: recentSwitch
                dock: root
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.showRecent
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
                anchors.bottom: parent.bottom
                width: doneText.implicitWidth + 32
                height: 32
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
          var left = win.tipTarget.contentLeft || 0     // not over a divider in front of it
          tip.anchor.rect.x = Math.round(pos.x + left + (win.tipTarget.width - left) / 2 - tip.implicitWidth / 2)
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
