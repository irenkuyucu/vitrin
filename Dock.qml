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
      // First run: no config yet, so set up the default dock (see "first run").
      root.startFirstRun()
    }
  }

  // ------------------------------------------------------------ first run
  // A new dock starts with Files, the default terminal and the default browser (each only
  // if installed), then Downloads and Trash. Both defaults are looked up asynchronously, so
  // the config is written once both are known (or after firstRunTimeout).
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
    root.firstRun = true
    browserFinder.running = true
    firstRunTimer.start()
  }

  function finishFirstRun(force) {
    if (!root.firstRun || (!force && !(root.terminalKnown && root.browserKnown))) return
    root.firstRun = false
    firstRunTimer.stop()
    root.pins = normalizePins([root.fixedApp, root.terminalApp, root.browserApp].filter(function(id) {
      return !!id && !!DesktopEntries.byId(id)
    }))
    saveConfig()
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
  // Which app (desktop entry) a window belongs to. Most windows match by id; the later
  // steps are fallbacks for apps whose window id doesn't match their entry (and whose entry
  // has no StartupWMClass), e.g. LocalSend: window "org.localsend.localsend_app", entry
  // "localsend.desktop". In order:
  //   1. exact id, Omarchy web apps, Quickshell's fuzzy lookup (certainEntryFor)
  //   2. clues from the window's process (hintEntryFor, see scripts/window-hints.sh)
  //   3. the id's dotted parts (looseEntryFor)
  // Windows of apps launched from the dock are also remembered (see learnFromLaunch), and
  // "aliases" in the config file override all of this.
  function entryFor(appId) {
    if (!appId) return null
    return certainEntryFor(appId) || hintEntryFor(appId) || looseEntryFor(appId) || null
  }

  function certainEntryFor(appId) {
    return DesktopEntries.byId(appId) || webAppEntryFor(appId) || DesktopEntries.heuristicLookup(appId) || null
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
    var windowWords = wordsOf(appId).concat(wordsOf(programs.join(" ")))
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
    if (isFolder && root.displayAsFor(item) === "stack") return root.iconSource("text-x-generic")
    return isFolder ? root.iconSource(item.icon) : root.pickIcon(item.icons)
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
  readonly property var groups: computeGroups(ToplevelManager.toplevels.values, DesktopEntries.applications.values,
    root.effectiveAliases, root.windowHints)

  function computeGroups(toplevels, _apps, _aliases, _hints) {
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
    noteUnmatched()
    learnFromLaunch()
    settleLaunching()
  }

  // Windows that don't match an app for certain: ask their process for clues, and note when
  // they first appeared (for learnFromLaunch).
  // Clues are forgotten once all of an id's windows have closed, so the next window with
  // that id is looked at afresh (it may be a different program).
  property var firstSeen: ({})
  function noteUnmatched() {
    var toplevels = ToplevelManager.toplevels.values
    var open = {}
    for (var i = 0; i < toplevels.length; i++) {
      var appId = toplevels[i] && toplevels[i].appId
      if (!appId) continue
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
      name: isTerminal(key) ? "Terminal" : (entry ? entry.name : prettyName(key, windows)),
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
  // Routine refreshes (each time the dock appears, and every 15 s with hiding off) only
  // need the newest few for the dock icon's pile; an open stack loads the folder's newest
  // stackMax entries (enough for anyone; opening takes about a second at most).
  readonly property int pileMax: 3
  readonly property int stackMax: 1000

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

  // With hiding off the dock is always on screen, so keep its stack icons current.
  Timer {
    interval: 15000
    repeat: true
    running: !root.autoHide
    onTriggered: root.refreshFolders()
  }

  onFoldersChanged: folderRefreshSoon.restart()

  // Records are NUL-terminated "<folder index>\t<mime type>\t<icon names>\t<path>" (so any file name,
  // even one with a tab or line break in it, comes through intact).
  function applyFolderListing(dirs, text) {
    assignIfChanged("folderFiles", parseFolderListing(dirs, text).files)
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
      property string dragIcon: ""            // icon url (or the letter tile)
      property string dragName: ""
      // Slot width of the dragged icon, at the current size (which can change mid-drag: see
      // dockWidthFor).
      readonly property real dragWidth: win.dragFrom !== -1 ? root.slotWidthFor(root.iconSource(win.dragIcon), win.size) : 0
      // Set for the moment a pulled-out icon is removed: everything is already where it
      // belongs, so the slide-aside offsets are dropped without animating.
      property bool snapShifts: false
      readonly property Item dragRow: row
      // For icons fading at the edges of a scrolling dock (see DockButton's edgeFade).
      readonly property real scrollX: rowView.contentX
      readonly property real scrollMax: rowView.maxX
      readonly property real viewWidth: rowView.width
      readonly property real rowX: row.x
      // The icons' actual width, including slots growing in or shrinking away, plus the
      // dock's end padding: what the outline follows. (dockWidthFor is the settled width.)
      readonly property real rowWidth: row.implicitWidth + root.leftPadFor(win.size) + root.rightPadFor(win.size)

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
        for (var i = 0; i < root.dockSources.length; i++) width += root.slotWidthFor(root.dockSources[i], size)
        if (win.dragRemoving) width -= root.slotWidthFor(root.iconSource(win.dragIcon), size)
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
        if (root.openAsFor(folder) === "stack") win.openStack(button, folder)
        else root.openFolder(folder)
      }

      function openStack(button, folder) {
        win.tipText = ""
        win.stackTarget = button
        win.stackFolder = folder
        root.stackOpenDir = root.expandPath(folder.path)
        root.refreshFolders()
        win.stackOpen = true
      }

      // byOutsideClick: closed by clicking elsewhere, so that same click is ignored by the
      // dock (see justClosedPopup); not when closed by choosing something in it.
      function closeStack(byOutsideClick) {
        if (win.stackOpen && byOutsideClick) win.popupClosedAt = Date.now()
        win.stackOpen = false
        root.stackOpenDir = ""
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
        win.dragName = item ? item.name : ""
        // Running apps (even pinned ones) only slide sideways; unpin those from their menu.
        win.dragRemovable = !!item && item.pinned && !root.isFixed(item.key) && item.windows.length === 0
        win.dragTopY = zone.y + dockBox.y
        win.dragFrom = index
        win.dragTo = index
      }

      // `point` is in the app row's coordinates.
      function updateDrag(point) {
        var scene = row.mapToItem(null, point.x, point.y)
        win.dragSceneX = scene.x
        win.dragSceneY = scene.y
        updateDragTarget(point.x)
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

      function updateDragTarget(rowX) {
        var point = { x: rowX }
        win.dragX = rowX
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
          if (i < root.items.length) left += root.slotWidthFor(root.pickIcon(root.items[i].icons), win.size)
          k++
        }
        // Slot 0 is Files' permanent spot; dragged apps can land anywhere after it.
        win.dragTo = Math.max(1, Math.min(root.items.length - 1, best))
      }

      function endDrag() {
        win.autoScrollSpeed = 0
        var from = win.dragFrom
        var to = win.dragTo
        var removing = win.dragRemoving
        if (removing) poof.play(dragGhost.x, dragGhost.y, dragGhost.source, dragGhost.width)
        // Everything is already where it belongs (the gap opened or closed while dragging),
        // so the slide-aside offsets are dropped without animating, and a pulled-out icon
        // goes without its leaving animation.
        win.snapShifts = true
        Qt.callLater(function() { win.snapShifts = false })
        win.dragFrom = -1
        win.dragTo = -1
        if (from !== -1 && from < root.items.length) {
          var key = root.items[from].key
          if (removing) {
            var instant = Object.assign({}, root.removeInstantly)
            instant[key] = true
            root.removeInstantly = instant
            root.unpin(key)
          }
          else if (to !== from) root.moveTo(key, to)
        }
        hideTimer.restart()
      }

      function cancelDrag() {
        win.autoScrollSpeed = 0
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

            // Divider between apps and folders, with breathing room like the macOS dock.
            // Right-click it for Turn Hiding On/Off and Dock Settings….
            Item {
              id: divider
              visible: root.folders.length > 0
              // Wide enough that the gap on each side of the line matches the gap between two
              // icons, like macOS (see dividerWidthFor).
              width: root.dividerWidthFor(win.size)
              // Slides left with the folders while an app is being pulled out to remove.
              transform: Translate {
                x: win.dragRemoving ? -win.dragWidth : 0
                Behavior on x {
                  enabled: !win.snapShifts
                  NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
              }
              height: root.slotHeightFor(win.size)
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                // The icon before it brings gapRight, the one after it gapLeft; the line
                // sits so both sides come out the same.
                x: Math.round(root.dividerSideFor(win.size) - root.gapRightFor(win.size))
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: Math.round(win.size * 1.03)      // macOS: a bit taller than the icons
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
                onWheel: function(w) { w.accepted = false }   // scrolling is for the dock
                property real startScreenY: 0
                property real startSize: 0

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
                    startSize = win.size
                    win.resizePreview = 0   // no preview until the pointer moves
                  }
                }
                onPositionChanged: function(m) {
                  if (!resizing) return
                  // Up = bigger. One 4 px size step per 4 px dragged.
                  // In the Size setting's steps of 4 (the dock may start at a fitted size in
                  // between), and no bigger than what fits on this screen.
                  // When no step fits (the dock is already shrunk below the smallest), it can't
                  // be resized at all, so it stays put.
                  var size = Math.round((startSize + (startScreenY - screenY(m))) / 4) * 4
                  var largest = Math.floor(win.fitFor(72) / 4) * 4
                  win.resizePreview = largest < 32 ? 0 : Math.max(32, Math.min(largest, size))
                }
                function finishResize() {
                  if (!resizing) return
                  resizing = false
                  var size = win.resizePreview
                  // Only an actual drag changes the setting (a click on a dock shrunk to fit
                  // mustn't save the fitted size).
                  if (size > 0 && size !== startSize && size !== root.iconSize) {
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
          source: root.displayableIcon(root.iconSource(win.dragIcon))
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
          opacity: win.dragRemoving ? 0.7 : 1
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
        Image {
          id: poof
          visible: false
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: root.iconSourceSize
          sourceSize.height: root.iconSourceSize
          smooth: true

          function play(px, py, src, size) {
            poof.source = src
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
