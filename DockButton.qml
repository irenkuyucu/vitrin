import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// One dock icon: an app (pinned or running) or a folder shortcut.
Item {
  id: button

  required property var dock
  required property var window
  required property var item
  property bool isFolder: false
  property int slot: -1                  // position in the app row (apps only)

  readonly property bool running: !isFolder && item.windows.length > 0
  readonly property bool launching: !isFolder && dock.isLaunching(item.key)
  readonly property bool acceptsFiles: dock.acceptsDrop(item, isFolder)
  readonly property bool beingDragged: !isFolder && window.dragFrom === slot
  readonly property string label: item.name || ""

  // While another icon is dragged, slide aside to open a gap where it would land.
  // While it's being pulled out to remove, close up the gap it leaves instead.
  readonly property real dragShift: {
    if (window.dragFrom === -1 || beingDragged) return 0
    var from = window.dragFrom
    if (window.dragRemoving) return (isFolder || slot > from) ? -window.slotWidth : 0
    if (isFolder) return 0
    var to = window.dragTo
    if (to > from && slot > from && slot <= to) return -window.slotWidth
    if (to < from && slot >= to && slot < from) return window.slotWidth
    return 0
  }

  width: dock.iconSize + dock.itemPad * 2
  height: dock.iconSize + dock.itemPad * 2
  opacity: beingDragged ? 0 : 1

  transform: Translate {
    x: button.dragShift
    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
  }

  // Highlight when files are dragged over an icon that can take them.
  Rectangle {
    anchors.fill: parent
    anchors.margins: 1
    visible: drop.containsDrag
    color: Util.alpha(dock.foreground, 0.14)
    radius: dock.rowRadius + 4
  }

  // Folders set to "Display as: Stack" show their newest files piled up instead of the
  // folder icon (an empty folder still shows the folder icon).
  readonly property var stackFiles: isFolder && dock.displayAsFor(item) === "stack"
    ? dock.filesFor(item).slice(0, 3) : []
  readonly property bool showStack: stackFiles.length > 0

  // Like the macOS dock: no hover highlight (the name label shows instead),
  // and the icon dims briefly while pressed.
  Item {
    id: iconBox
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -1
    width: dock.iconSize
    height: dock.iconSize
    // No press dim for a click that only closes an open menu or stack.
    opacity: mouse.pressed && !mouse.dragging && !mouse.suppressClick ? 0.6 : 1
    scale: drop.containsDrag ? 1.1 : 1
    Behavior on opacity { NumberAnimation { duration: 80 } }
    Behavior on scale { NumberAnimation { duration: 120 } }

    transform: Translate { id: bounce; y: 0 }

    Image {
      visible: !button.showStack
      anchors.fill: parent
      sourceSize.width: dock.iconSourceSize
      sourceSize.height: dock.iconSourceSize
      source: dock.iconSource(button.item.icon)
      fillMode: Image.PreserveAspectFit
      smooth: true
      asynchronous: true
    }

    // The pile: oldest of the three at the back, slightly turned; newest on top.
    Repeater {
      model: button.showStack ? button.stackFiles.slice().reverse() : []
      delegate: FileIcon {
        required property var modelData
        required property int index
        readonly property int depth: button.stackFiles.length - 1 - index   // 0 = newest
        dock: button.dock
        file: modelData
        size: button.dock.iconSize
        anchors.horizontalCenter: parent.horizontalCenter
        y: (parent.height - height) / 2 + 2 - depth * 3
        rotation: depth === 0 ? 0 : (depth === 1 ? -7 : 7)
        opacity: 1 - depth * 0.12
      }
    }
  }

  // Launch feedback: bounce until the app's window shows up.
  SequentialAnimation {
    running: button.launching && button.dock.animateLaunch
    loops: Animation.Infinite
    NumberAnimation { target: bounce; property: "y"; to: -Math.round(dock.iconSize * 0.33); duration: 280; easing.type: Easing.OutQuad }
    NumberAnimation { target: bounce; property: "y"; to: 0; duration: 280; easing.type: Easing.InQuad }
    PauseAnimation { duration: 80 }
    onRunningChanged: if (!running) bounce.y = 0
  }

  // Running indicator: a small dot under every open app.
  Rectangle {
    visible: button.running
    width: 4
    height: 4
    radius: 2
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 0
    color: Util.alpha(dock.foreground, 0.8)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    preventStealing: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

    property real pressX: 0
    property real pressY: 0
    property bool dragging: false
    property bool suppressClick: false
    readonly property int dragThreshold: 8

    onEntered: button.window.showTip(button, button.label)
    onExited: button.window.hideTip(button)

    onPressed: function(m) {
      pressX = m.x
      pressY = m.y
      // A click that just closed a menu is used up by closing it (like macOS/GNOME),
      // so it doesn't also open or switch to this icon.
      suppressClick = button.window.justClosedPopup()
    }

    onPositionChanged: function(m) {
      // Folders and Files (always first) stay put.
      if (button.isFolder || button.dock.isFixed(button.item.key) || !(m.buttons & Qt.LeftButton)) return
      if (!dragging && Math.abs(m.x - pressX) + Math.abs(m.y - pressY) > dragThreshold) {
        dragging = true
        button.window.beginDrag(button.slot, button.item.icon)
      }
      if (dragging) button.window.updateDrag(mapToItem(button.window.dragRow, m.x, m.y))
    }

    onReleased: function(m) {
      if (!dragging) return
      dragging = false
      suppressClick = true
      button.window.endDrag()
    }

    onCanceled: {
      if (!dragging) return
      dragging = false
      button.window.cancelDrag()
    }

    onClicked: function(m) {
      if (suppressClick) {
        suppressClick = false
        return
      }
      if (m.button === Qt.RightButton) {
        button.window.openMenu(button, button.item, button.isFolder)
      } else if (button.isFolder) {
        button.window.folderClicked(button, button.item)
      } else if (m.button === Qt.MiddleButton) {
        button.dock.launch(button.item)
      } else {
        button.dock.activate(button.item)
      }
    }
  }

  // Files dropped here: onto Trash moves them to the Trash; onto a folder (Downloads) moves
  // them into it, or copies them when they're on another drive; onto an app opens them
  // with it. Accepted as a "copy" so the app the files came from never deletes them
  // itself; the dock does any moving, and Trash moves can be undone from the Trash.
  DropArea {
    id: drop
    anchors.fill: parent
    enabled: button.acceptsFiles
    keys: ["text/uri-list"]
    onEntered: function(d) {
      button.window.dropEnter()
      d.accept(Qt.CopyAction)
    }
    onExited: button.window.dropLeave()
    onDropped: function(d) {
      button.window.dropLeave()
      if (!d.hasUrls) return
      d.accept(Qt.CopyAction)
      button.dock.dropFiles(button.item, button.isFolder, d.urls)
    }
  }
}
