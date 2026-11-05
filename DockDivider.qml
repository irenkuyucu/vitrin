import QtQuick
import qs.Commons

// A divider in the dock: a thin vertical line with breathing room on each side, like the
// macOS dock's. The dock has one before the folders, and one between the pinned apps and
// the running/recent apps (drawn as part of the first icon after it, see DockButton).
// Right-click: the dock menu (Turn Hiding On/Off, Dock Settings…). Left-drag up/down (when
// "dividerResize" is on): resize the dock live, in the Size slider's steps; saved on release.
Item {
  id: divider

  required property var dock
  required property var window

  readonly property bool resizing: mouse.resizing
  onResizingChanged: window.dividerResizing = resizing

  height: dock.slotHeightFor(window.size)

  Rectangle {
    // The icon before it brings gapRight, the one after it gapLeft; the line sits so both
    // sides come out the same.
    x: Math.round(divider.dock.dividerSideFor(divider.window.size) - divider.dock.gapRightFor(divider.window.size))
    anchors.verticalCenter: parent.verticalCenter
    width: 1
    height: Math.round(divider.window.size * 1.03)      // macOS: a bit taller than the icons
    radius: 0.5
    color: Util.alpha(divider.dock.foreground, mouse.containsMouse ? 0.45 : 0.22)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    preventStealing: true
    acceptedButtons: divider.dock.dividerResize ? (Qt.LeftButton | Qt.RightButton) : Qt.RightButton
    cursorShape: divider.dock.dividerResize ? Qt.SizeVerCursor : Qt.ArrowCursor
    property bool suppressClick: false
    property bool resizing: false
    onWheel: function(w) { w.accepted = false }   // scrolling is for the dock
    property real startScreenY: 0
    property real startSize: 0

    // Pointer height on screen. The dock window grows and shrinks while resizing, so the
    // pointer's position inside it isn't stable; on screen it is.
    function screenY(m) {
      return mapToItem(null, m.x, m.y).y + (divider.window.screen.height - divider.window.height)
    }

    onPressed: function(m) {
      suppressClick = divider.window.justClosedPopup()
      if (m.button === Qt.LeftButton && !suppressClick) {
        resizing = true
        startScreenY = screenY(m)
        startSize = divider.window.size
        divider.window.resizePreview = 0   // no preview until the pointer moves
      }
    }
    onPositionChanged: function(m) {
      if (!resizing) return
      // Up = bigger. One 4 px size step per 4 px dragged, in the Size setting's steps of 4
      // (the dock may start at a fitted size in between), and no bigger than what fits on
      // this screen. When no step fits (the dock is already shrunk below the smallest), it
      // can't be resized at all, so it stays put.
      var size = Math.round((startSize + (startScreenY - screenY(m))) / 4) * 4
      var largest = Math.floor(divider.window.fitFor(72) / 4) * 4
      divider.window.resizePreview = largest < 32 ? 0 : Math.max(32, Math.min(largest, size))
    }
    function finishResize() {
      if (!resizing) return
      resizing = false
      var size = divider.window.resizePreview
      // Only an actual drag changes the setting (a click on a dock shrunk to fit mustn't
      // save the fitted size).
      if (size > 0 && size !== startSize && size !== divider.dock.iconSize) {
        divider.window.applyingResize = true
        divider.dock.setSetting("iconSize", size, true)
        divider.window.resizePreview = 0
        Qt.callLater(function() { divider.window.applyingResize = false })
      } else {
        divider.window.resizePreview = 0
      }
      divider.window.restartHideTimer()
    }
    onReleased: function(m) { finishResize() }
    onCanceled: finishResize()
    onClicked: function(m) {
      if (m.button === Qt.RightButton && !suppressClick) divider.window.openDockMenu(divider)
    }
  }
}
