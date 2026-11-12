import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Every app on one grid, like Launchpad: opened from the Apps icon on the dock, or by
// Omarchy's Apps shortcut and menu item while Omarchy's own dock is off (see Dock.qml).
// It covers the screen except the space the bar keeps, and the dock's while it isn't
// hiding. Type to narrow it down, arrows to move, Enter to open, Esc to clear the search
// or close; click an app to open it, right-click for Keep in Dock / Remove from Dock, click
// anywhere else to close.
Scope {
  id: grid

  required property var dock

  property bool opened: false
  property var targetScreen: null
  property string query: ""
  // Apps installed or removed while it's closed are picked up when it next opens.
  property var allApps: []
  readonly property var apps: filterApps(allApps, query)

  function open(screen) {
    grid.targetScreen = screen
    grid.query = ""
    grid.allApps = listApps()
    grid.menuEntry = null
    grid.pointerX = -1
    grid.pointerY = -1
    grid.opened = true
  }
  function close() { grid.opened = false; grid.menuEntry = null }
  function toggle(screen) { if (grid.opened) close(); else open(screen) }

  // Everything the app menu shows (hidden entries skipped), by name.
  function listApps() {
    var entries = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e || e.noDisplay || !e.name) continue
      out.push({ entry: e, id: String(e.id), name: String(e.name),
                 lower: String(e.name).toLowerCase(),
                 extra: [e.genericName, e.comment].concat(e.keywords || []).join(" ").toLowerCase() })
    }
    out.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return out
  }

  // Names starting with the search first, then names containing it, then apps whose
  // description or keywords do ("browser" finds Zen and Chromium).
  function filterApps(list, q) {
    q = String(q || "").trim().toLowerCase()
    if (!q) return list
    var starts = [], contains = [], other = []
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      if (a.lower.indexOf(q) === 0) starts.push(a)
      else if (a.lower.indexOf(q) !== -1) contains.push(a)
      else if (a.extra.indexOf(q) !== -1) other.push(a)
    }
    return starts.concat(contains, other)
  }

  function launch(app) {
    grid.close()
    grid.dock.launch({ key: app.id, entry: app.entry, windows: [] })
  }

  // Where the pointer last was over the grid (in the window), to tell real pointer moves
  // from apps scrolling under it.
  property real pointerX: -1
  property real pointerY: -1

  // The app whose right-click menu is open, and where.
  property var menuEntry: null
  property real menuX: 0
  property real menuY: 0

  PanelWindow {
    id: win
    screen: grid.targetScreen
    visible: grid.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    // Ignore: the dim reaches the screen's edges. The bar stays clear of it (a margin the size of
    // what the compositor reserved for it) and the dock, which is on a higher layer, is drawn over it.
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: 0
    readonly property var reserved: {
      var m = Hyprland.monitorFor(grid.targetScreen)
      return m && m.lastIpcObject && m.lastIpcObject.reserved ? m.lastIpcObject.reserved : [0, 0, 0, 0]
    }
    margins { left: reserved[0]; top: reserved[1]; right: reserved[2] }
    WlrLayershell.namespace: grid.dock.slug + "-apps"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    onVisibleChanged: {
      if (!visible) return
      Hyprland.refreshMonitors()      // (the reserved space is read from the compositor's latest word)
      grow.restart()
      search.text = ""
      search.forceActiveFocus()
      appsView.currentIndex = -1
      appsView.positionViewAtBeginning()
      fade.restart()
    }

    // The screen is dimmed and the apps sit on a panel in the middle of it (so it doesn't depend
    // on how windows are laid out: tiled, floating, with or without gaps).
    Rectangle {
      id: dim
      anchors.fill: parent
      // Black on any theme (the theme's background would only whiten a light theme's surround);
      // less of it on a light one, where black shows up more.
      color: Qt.rgba(0, 0, 0, grid.dock.background.hslLightness > 0.5 ? 0.35 : 0.55)
      opacity: backdrop.opacity
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: grid.close()
      }
    }

    Rectangle {
      id: backdrop
      anchors.horizontalCenter: parent.horizontalCenter
      // Centered in the space the bar and the dock leave free (what the compositor reserved for
      // them), which holds on tiled and floating workspaces alike. The dock's space is only
      // taken off while it isn't hiding.
      readonly property int freeHeight: parent.height - win.reserved[3]
      y: Math.round((freeHeight - height) / 2)
      // Sized from the free height (the scarce side): 80% of it, as wide as 1.8 times that
      // (so ultrawide screens don't get a billboard), but never beyond the screen, which is what
      // a portrait screen runs into. The width is whole columns.
      readonly property int margin: 40
      readonly property int panelHeight: Math.min(freeHeight - 2 * margin, Math.max(Math.round(freeHeight * 0.8), 480))
      readonly property int columns: Math.max(1, Math.floor((Math.min(Math.round(panelHeight * 1.8), parent.width - 2 * margin) - 96) / appsView.cell))
      width: columns * appsView.cell + 96
      height: panelHeight
      radius: grid.dock.menuRadius
      color: Util.alpha(grid.dock.surface, 0.95)
      border.width: 1
      border.color: Util.alpha(grid.dock.foreground, 0.25)
      opacity: 0
      scale: 0.97
      NumberAnimation { id: grow; target: backdrop; property: "scale"; from: 0.97; to: 1; duration: 150; easing.type: Easing.OutCubic }
      NumberAnimation { id: fade; target: backdrop; property: "opacity"; from: 0; to: 1; duration: 150; easing.type: Easing.OutCubic }

      // Clicks that reach here missed every app: close.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: if (grid.menuEntry) grid.menuEntry = null; else grid.close()
      }

      // Search
      Rectangle {
        id: searchBox
        anchors.horizontalCenter: parent.horizontalCenter
        y: 30
        width: 320
        height: 36
        radius: grid.dock.rowRadius + 4
        color: Util.alpha(grid.dock.foreground, 0.08)
        border.color: search.activeFocus ? Util.alpha(grid.dock.accent, 0.8) : grid.dock.hairline
        border.width: 1

        Text {
          anchors.fill: parent
          anchors.leftMargin: 14
          verticalAlignment: Text.AlignVCenter
          visible: search.text.length === 0
          text: "Search"
          color: grid.dock.popupText
          opacity: 0.45
          font.family: grid.dock.uiFont
          font.pixelSize: grid.dock.uiFontSize
        }

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          color: grid.dock.popupText
          selectionColor: Util.alpha(grid.dock.accent, 0.4)
          font.family: grid.dock.uiFont
          font.pixelSize: grid.dock.uiFontSize
          onTextChanged: {
            grid.query = text
            grid.menuEntry = null
            appsView.currentIndex = text.length > 0 ? 0 : -1      // (what's highlighted is what Enter opens)
            appsView.positionViewAtBeginning()
          }

          Keys.onPressed: function(event) {
            switch (event.key) {
            case Qt.Key_Escape:
              if (grid.menuEntry) grid.menuEntry = null
              else if (text.length > 0) text = ""
              else grid.close()
              break
            case Qt.Key_Return:
            case Qt.Key_Enter:
              if (appsView.currentIndex >= 0 && appsView.currentIndex < grid.apps.length)
                grid.launch(grid.apps[appsView.currentIndex])
              break
            case Qt.Key_Left: case Qt.Key_Right: case Qt.Key_Up: case Qt.Key_Down:
              if (appsView.currentIndex < 0) { if (grid.apps.length > 0) appsView.currentIndex = 0 }     // (the first arrow selects the first app)
              else if (event.key === Qt.Key_Left) appsView.moveCurrentIndexLeft()
              else if (event.key === Qt.Key_Right) appsView.moveCurrentIndexRight()
              else if (event.key === Qt.Key_Up) appsView.moveCurrentIndexUp()
              else appsView.moveCurrentIndexDown()
              break
            default: return
            }
            event.accepted = true
          }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: searchBox.bottom
        anchors.topMargin: 48
        visible: grid.apps.length === 0
        text: "No apps found"
        color: grid.dock.popupText
        opacity: 0.6
        font.family: grid.dock.uiFont
        font.pixelSize: grid.dock.uiFontSize + 2
      }

      // The grid: whole columns, centered.
      GridView {
        id: appsView
        readonly property int cell: 136
        readonly property int columns: backdrop.columns
        anchors.top: searchBox.bottom
        anchors.topMargin: 32
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        anchors.horizontalCenter: parent.horizontalCenter
        width: columns * cell
        cellWidth: cell
        cellHeight: 128
        clip: true
        model: grid.apps
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationWraps: false
        highlightFollowsCurrentItem: false
        // While a menu is open, the grid holds still.
        interactive: !grid.menuEntry
        // One highlight: the selected app. The arrow keys move it (and scroll it into
        // view); moving the mouse over an app selects that one instead. (Apps sliding
        // under a still pointer while the grid scrolls don't count as the mouse moving.)
        // Keys scroll the selected app into view; the pointer selecting one doesn't (a row that is
        // half in view stays where it is under the pointer).
        property bool followSelection: true
        onCurrentIndexChanged: if (currentIndex >= 0 && followSelection) positionViewAtIndex(currentIndex, GridView.Contain)

        delegate: Item {
          id: cellItem
          required property var modelData
          required property int index
          readonly property bool current: GridView.isCurrentItem
          width: appsView.cellWidth
          height: appsView.cellHeight
          // Worked out here, not when the grid opens, so the icon follows the lookup's answers
          // (and a candidate that turns out broken is skipped), as on the dock itself.
          readonly property string iconUrl: grid.dock.pickIcon(grid.dock.iconCandidatesFor(modelData.entry, modelData.id))
          onIconUrlChanged: grid.dock.requestMeasurement(iconUrl)
          Component.onCompleted: grid.dock.requestMeasurement(iconUrl)

          Rectangle {
            anchors.fill: parent
            anchors.margins: 6
            radius: grid.dock.menuRadius
            color: cellMouse.pressed ? Util.alpha(grid.dock.foreground, 0.16)
                 : (cellItem.current || grid.menuEntry === cellItem.modelData)
                   ? Util.alpha(grid.dock.foreground, 0.08) : "transparent"
          }

          Image {
            id: icon
            anchors.horizontalCenter: parent.horizontalCenter
            y: 18
            width: 64
            height: 64
            sourceSize.width: 128
            sourceSize.height: 128
            source: grid.dock.gridIcon(cellItem.iconUrl)
            // A file that won't load is skipped from now on (the next candidate is used).
            onStatusChanged: if (status === Image.Error && String(source) !== "") grid.dock.finishMeasurement(String(source), false)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            // (While a different file loads, the old artwork stays instead of blinking out.)
            visible: status === Image.Ready || status === Image.Loading
          }
          LetterIcon {
            anchors.centerIn: icon
            size: 64
            name: cellItem.modelData.name
            visible: icon.status !== Image.Ready && icon.status !== Image.Loading
          }

          Text {
            anchors.top: icon.bottom
            anchors.topMargin: 10
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 20
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: cellItem.modelData.name
            textFormat: Text.PlainText
            color: grid.dock.popupText
            font.family: grid.dock.uiFont
            font.pixelSize: grid.dock.uiFontSize - 1
          }

          MouseArea {
            id: cellMouse
            anchors.fill: parent
            anchors.margins: 6
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // Qt also reports a "move" when the grid scrolls under a still pointer; only a
            // change in where the pointer is on screen counts.
            onPositionChanged: function(m) {
              // (The first one after opening only says where the pointer is.)
              var p = mapToItem(backdrop, m.x, m.y)
              var known = grid.pointerX >= 0
              if (known && Math.abs(p.x - grid.pointerX) < 0.5 && Math.abs(p.y - grid.pointerY) < 0.5) return
              grid.pointerX = p.x
              grid.pointerY = p.y
              if (known && !grid.menuEntry) {
                appsView.followSelection = false
                appsView.currentIndex = cellItem.index
                appsView.followSelection = true
              }
            }
            // The pointer leaving the app takes the highlight with it (not when the grid is merely
            // scrolling under a still pointer, or a menu is open).
            onContainsMouseChanged: if (!containsMouse && !appsView.moving && !grid.menuEntry
                                        && appsView.currentIndex === cellItem.index) appsView.currentIndex = -1
            onClicked: function(m) {
              if (m.button === Qt.RightButton) {
                var p = mapToItem(backdrop, m.x, m.y)
                grid.menuX = p.x
                grid.menuY = p.y
                grid.menuEntry = cellItem.modelData
              } else if (grid.menuEntry) {
                grid.menuEntry = null
              } else {
                grid.launch(cellItem.modelData)
              }
            }
          }
        }
      }

      GlideScroll { anchors.fill: appsView; view: appsView }

      // Rows that scroll out of the panel fade away instead of being cut off.
      Rectangle {
        x: appsView.x
        y: appsView.y
        width: appsView.width
        height: 18
        gradient: Gradient {
          GradientStop { position: 0; color: backdrop.color }
          GradientStop { position: 1; color: Qt.rgba(backdrop.color.r, backdrop.color.g, backdrop.color.b, 0) }
        }
      }
      Rectangle {
        x: appsView.x
        y: appsView.y + appsView.height - 44
        width: appsView.width
        height: 44
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(backdrop.color.r, backdrop.color.g, backdrop.color.b, 0) }
          GradientStop { position: 1; color: backdrop.color }
        }
      }

      // Right-click menu: Open, Keep in Dock / Remove from Dock.
      Rectangle {
        id: menu
        visible: !!grid.menuEntry
        readonly property bool pinned: !!grid.menuEntry && grid.dock.pins.indexOf(grid.menuEntry.id) !== -1
        x: Math.min(grid.menuX, backdrop.width - width - 8)
        y: Math.min(grid.menuY, backdrop.height - height - 8)
        width: 200
        height: menuColumn.implicitHeight + 12
        radius: grid.dock.menuRadius
        color: grid.dock.surface
        border.color: grid.dock.hairline
        border.width: 1

        // Swallow clicks on the menu's own padding.
        MouseArea { anchors.fill: parent }

        Column {
          id: menuColumn
          x: 6
          y: 6
          width: parent.width - 12

          Repeater {
            model: [
              { label: "Open", act: "open" },
              { label: menu.pinned ? "Remove from Dock" : "Keep in Dock", act: menu.pinned ? "unpin" : "pin" }
            ]
            delegate: Rectangle {
              required property var modelData
              width: menuColumn.width
              height: 32
              radius: grid.dock.rowRadius
              color: rowMouse.containsMouse ? grid.dock.rowHover : "transparent"
              Text {
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                text: modelData.label
                color: grid.dock.popupText
                font.family: grid.dock.uiFont
                font.pixelSize: grid.dock.uiFontSize
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                  var app = grid.menuEntry
                  grid.menuEntry = null
                  if (!app) return
                  if (modelData.act === "open") grid.launch(app)
                  else if (modelData.act === "pin") grid.dock.pin(app.id)
                  else grid.dock.unpin(app.id)
                }
              }
            }
          }
        }
      }
    }
  }
}
