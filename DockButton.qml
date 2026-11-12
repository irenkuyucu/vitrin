import QtQuick
import Quickshell
import qs.Commons

// One dock icon: an app (pinned or running) or a folder shortcut.
Item {
  id: button

  required property var dock
  required property var window
  required property var item
  property bool isFolder: false
  property int slot: -1                  // position in the app row (apps only)
  property int folderIndex: -1           // position among the folders (folders only)
  property bool isLeaving: false         // closing: shrinks away, then is removed
  property bool animateIn: false         // just opened: grows in

  // 0..1: how far this icon's slot is open. Opening apps grow from 0, closing ones shrink
  // to 0; the icons beside them slide along and the dock widens or narrows with them.
  property real appear: animateIn ? 0 : 1
  NumberAnimation {
    id: appearAnimation
    target: button
    property: "appear"
    duration: 180
    easing.type: Easing.OutCubic
    onFinished: if (button.isLeaving) button.dock.finishLeaving(button.item.key)
  }
  Component.onCompleted: if (animateIn) { appearAnimation.to = 1; appearAnimation.start() }
  onIsLeavingChanged: if (isLeaving) { appearAnimation.stop(); appearAnimation.to = 0; appearAnimation.start() }

  readonly property bool running: !isFolder && item.windows.length > 0
  // Every window of the app is hidden (minimized or in the scratchpad): the running dot is hollow.
  readonly property bool allHidden: running && item.windows.every(function(w) { return dock.isHidden(w) })
  readonly property bool missing: isFolder && dock.isMissing(item)
  // Holding a drag over it brings it forward (see springTimer): running apps, and Files
  // even when it isn't running.
  readonly property bool springs: !isFolder && (running || dock.isFixed(item.key))
  readonly property bool launching: !isFolder && dock.isLaunching(item.key)
  readonly property bool acceptsFiles: dock.acceptsDrop(item, isFolder)
  readonly property bool beingDragged: window.dragFrom !== -1 && (isFolder
    ? window.dragFolder && folderIndex !== -1 && window.dragFrom === folderIndex
    : !window.dragFolder && slot !== -1 && window.dragFrom === slot)
  readonly property string label: item.name || ""
  // Apps pick the first of their icon candidates that works (see "icon fallbacks").
  readonly property string iconUrl: isFolder ? dock.iconSource(dock.folderIconFor(item)) : dock.pickIcon(item.icons)
  readonly property bool letterIcon: iconUrl === dock.letterIcon
  readonly property bool appsIcon: iconUrl === dock.appsIcon
  readonly property string slotUrl: dock.slotSourceFor(item, isFolder)

  // The artwork is scaled to look as big as the others ("size normalization" in Dock.qml)
  // and each slot is as wide as the scaled artwork plus one gap ("spacing"), with the
  // artwork nudged so its visible middle sits mid-slot.
  readonly property int drawSize: dock.drawSizeFor(slotUrl, window.size)
  readonly property int artOffsetY: dock.artOffsetYFor(slotUrl, window.size)

  // While another icon is dragged, slide aside (by the dragged icon's slot width) to open
  // a gap where it would land. While it's being pulled out to remove, close up the gap it
  // leaves instead.
  readonly property real dragShift: {
    // Folders dragged in from elsewhere: the folders from the gap on move right.
    if (window.dragFrom === -1)
      return isFolder && window.dropInsert >= 0 && folderIndex >= window.dropInsert ? window.dropGapWidth : 0
    if (beingDragged) return 0
    var from = window.dragFrom
    var to = window.dragTo
    if (window.dragFolder) {
      // Apps stay put; the folders after it close up when it's pulled out, or make room.
      if (!isFolder) return 0
      var i = folderIndex
      if (window.dragRemoving) return i > from ? -window.dragWidth : 0
      if (to > from && i > from && i <= to) return -window.dragWidth
      if (to < from && i >= to && i < from) return window.dragWidth
      return 0
    }
    if (window.dragRemoving) return (isFolder || slot > from) ? -window.dragWidth : 0
    if (isFolder) return 0
    // A middle-section app dragged in among the pinned apps: everything from its landing
    // spot up to where it came from moves right to make room (the divider too, see below).
    if (window.dragToPinned) return slot >= to && slot < from ? window.dragWidth : 0
    if (to > from && slot > from && slot <= to) return -window.dragWidth
    if (to < from && slot >= to && slot < from) return window.dragWidth
    return 0
  }

  readonly property real fullWidth: dock.slotWidthFor(slotUrl, window.size)

  // The first app of the middle section (see "sections" in Dock.qml) carries the divider
  // before it, at its left: it moves, appears and goes with the section that way.
  readonly property bool sectionStart: !isFolder && !isLeaving && slot !== -1
    && dock.hasMiddle && slot === dock.middleStart
  // Pulling out the middle section's only app takes the whole section with it: the divider
  // closes up too, while it's held out (see Dock.qml's dockWidthFor).
  readonly property bool sectionGoing: beingDragged && !isFolder && window.dragRemoving && dock.middle.length === 1
  property real sectionGap: sectionStart && !sectionGoing ? dock.dividerWidthFor(window.size) : 0
  Behavior on sectionGap {
    enabled: button.window.dragFrom !== -1 && !button.window.snapShifts
    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
  }
  readonly property real contentLeft: sectionGap * appear

  width: (fullWidth + sectionGap) * appear
  enabled: !isLeaving
  height: dock.slotHeightFor(window.size)
  opacity: edgeFade

  // When the dock scrolls (too many icons for the screen), icons fade out as they near an
  // edge that has more icons beyond it: fully faded at the edge, over one icon's width.
  readonly property real edgeFade: {
    if (!window.overflowing) return 1
    // Where the icon is on screen: including its slide while another icon is dragged.
    var mid = window.rowX + x + dragShift + width / 2 - window.scrollX
    var fade = 1
    if (window.scrollX > 0.5) fade = Math.min(fade, mid / width)
    if (window.scrollX < window.scrollMax - 0.5) fade = Math.min(fade, (window.viewWidth - mid) / width)
    return Math.max(0, Math.min(1, fade))
  }

  transform: Translate {
    x: button.dragShift
    Behavior on x {
      enabled: !button.window.snapShifts
      NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
  }

  // Folders set to "Display as: Stack" show their newest files piled up instead of the
  // folder icon (an empty folder still shows the folder icon).
  readonly property var stackFiles: isFolder && dock.displayAsFor(item) === "stack"
    ? dock.filesFor(item).slice(0, 3) : []
  readonly property bool showStack: stackFiles.length > 0

  // The pile is drawn to fit the slot (see FilePile), so the gaps stay even and nothing
  // shifts when a wider file (a landscape photo) arrives.
  readonly property real artWidth: dock.artWidthFor(slotUrl, window.size)

  DockDivider {
    visible: button.sectionGap > 0.5
    dock: button.dock
    window: button.window
    width: button.contentLeft
    anchors.verticalCenter: parent.verticalCenter
    // When this app itself is being dragged in among the pinned apps, its icon is gone from
    // here but the divider must still move right with the pinned apps' new room.
    transform: Translate {
      x: button.beingDragged && button.window.dragToPinned && !button.window.dragRemoving ? button.window.dragWidth : 0
      Behavior on x {
        enabled: !button.window.snapShifts
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
      }
    }
  }

  // The icon chosen with the keyboard (see Dock.qml's keyboard mode).
  readonly property bool kbFocused: window.keyMode && window.kbButton === button
  // The same square for every icon, centered on it (icons differ in how much of their
  // box they fill, so a box around the artwork would differ from icon to icon).
  Rectangle {
    visible: button.kbFocused
    width: Math.round(window.size * 1.2)
    height: width
    x: iconBox.x + (iconBox.width - width) / 2
    y: iconBox.y + (iconBox.height - height) / 2
    radius: Math.round(window.size * 0.24)
    color: Util.alpha(dock.foreground, 0.18)
  }

  // Like the macOS dock: no hover highlight (the name label shows instead),
  // and the icon dims briefly while pressed.
  Item {
    id: iconBox
    // The artwork's visible left edge sits exactly gapLeft into the slot (see "spacing").
    // (While the slot grows in or shrinks away, the icon stays centered in it and scales
    // with it.)
    x: (dock.iconExtents[button.slotUrl]
      ? dock.gapLeftFor(window.size) - dock.artLeftFor(button.slotUrl, window.size)
      : Math.round((button.fullWidth - width) / 2)) - (1 - button.appear) * button.fullWidth / 2
      + button.contentLeft
    scale: button.appear
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: -1 + button.artOffsetY
    width: button.drawSize
    height: button.drawSize
    // Dims while pressed (no press dim for a click that only closes an open menu or
    // stack), and the same way while files are dragged over an icon that can take them,
    // like the macOS dock. (No box around it: slots differ in width, so a box would be
    // uneven or reach over the neighbours.)
    // (Hidden while it's being dragged: the dragged copy follows the pointer instead.)
    opacity: button.beingDragged ? 0
      : ((mouse.pressed && !mouse.dragging && !mouse.suppressClick) || (drop.containsDrag && (button.acceptsFiles || button.springs)) ? 0.6 : 1)
        * (button.missing ? 0.4 : 1)
    Behavior on opacity { NumberAnimation { duration: 80 } }

    transform: Translate { id: bounce; y: 0 }

    Image {
      visible: !button.showStack && !button.letterIcon && !button.appsIcon
      anchors.fill: parent
      sourceSize.width: dock.iconSourceSize
      sourceSize.height: dock.iconSourceSize
      source: dock.displayableIcon(button.iconUrl)   // (see displayableIcon)
      fillMode: Image.PreserveAspectFit
      smooth: true
      asynchronous: true
    }

    LetterIcon {
      visible: button.letterIcon
      anchors.fill: parent
      name: button.label
      size: button.drawSize
    }

    AppsIcon {
      visible: button.appsIcon
      anchors.fill: parent
      size: button.drawSize
      accent: button.dock.accent
    }

    FilePile {
      anchors.fill: parent
      dock: button.dock
      files: button.showStack ? button.stackFiles : []
      size: button.drawSize
      artWidth: button.artWidth
    }
  }

  Timer {
    id: springTimer
    interval: 1000
    onTriggered: {
      if (!drop.containsDrag) return
      var windows = button.item.windows || []
      if (windows.length === 0) {
        // Files, not running: a new window, at the home folder.
        if (button.dock.isFixed(button.item.key)) button.dock.openFolder({ path: "~" })
        return
      }
      for (var i = 0; i < windows.length; i++) if (windows[i].activated) return   // already in front
      button.dock.bringForward(windows[0], button.window.screen)
    }
  }

  // A folder that can't be found: a question mark on its dimmed icon.
  MissingBadge {
    visible: button.missing && !button.beingDragged
    dock: button.dock
    iconSize: button.drawSize
    x: iconBox.x + iconBox.width - width * 0.85
    y: iconBox.y + iconBox.height - height * 0.85
  }

  // A folder that's already in the dock bounces when it's dragged onto the dock again.
  Connections {
    target: button.dock
    enabled: button.isFolder
    function onFolderBounce(path) {
      if (button.dock.expandPath(button.item.path) === path) folderBounce.restart()
    }
  }
  SequentialAnimation {
    id: folderBounce
    loops: 2
    NumberAnimation { target: bounce; property: "y"; to: -Math.round(window.size * 0.33); duration: 280; easing.type: Easing.OutQuad }
    NumberAnimation { target: bounce; property: "y"; to: 0; duration: 280; easing.type: Easing.InQuad }
  }

  // Launch feedback: bounce until the app's window shows up.
  SequentialAnimation {
    running: button.launching && button.dock.animateLaunch
    loops: Animation.Infinite
    NumberAnimation { target: bounce; property: "y"; to: -Math.round(window.size * 0.33); duration: 280; easing.type: Easing.OutQuad }
    NumberAnimation { target: bounce; property: "y"; to: 0; duration: 280; easing.type: Easing.InQuad }
    PauseAnimation { duration: 80 }
    onRunningChanged: if (!running) bounce.y = 0
  }

  // Running indicator: a small dot under every open app, scaled with the icon size
  // (4 px at 60 px icons, like macOS; never smaller than 3 px).
  Rectangle {
    visible: button.running && !button.beingDragged
    width: Math.max(3, Math.round(window.size / 15))
    height: width
    radius: width / 2
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.horizontalCenterOffset: button.contentLeft / 2    // under the icon, not the divider
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 0
    color: button.allHidden ? "transparent" : Util.alpha(dock.foreground, 0.8)
    border.width: button.allHidden ? 1 : 0
    border.color: Util.alpha(dock.foreground, 0.8)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.leftMargin: button.contentLeft      // the divider part has its own (DockDivider)
    hoverEnabled: true
    preventStealing: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

    property real pressX: 0
    property real pressY: 0
    property bool dragging: false
    property bool suppressClick: false
    property bool dragLost: false
    readonly property int dragThreshold: 8

    // Scrolling is for the dock (when it overflows), not for the icon.
    onWheel: function(w) { w.accepted = false }

    onEntered: button.window.showTip(button, button.label)
    onExited: button.window.hideTip(button)

    onPressed: function(m) {
      pressX = m.x
      pressY = m.y
      dragLost = false
      // A click that just closed a menu is used up by closing it (like macOS/GNOME),
      // so it doesn't also open or switch to this icon.
      if (button.window.menuByKey) button.window.closeKeyMenu()   // a menu opened from the keyboard
      if (button.window.stackByKey) button.window.closeKeyStack() // and a stack
      suppressClick = button.window.justClosedPopup()
    }

    onPositionChanged: function(m) {
      // Files (always first) and the Trash (always last) stay put.
      if (!(m.buttons & Qt.LeftButton)) return
      // The dock dropped the drag (an app opened or closed under it): the gesture is over.
      if (dragging && button.window.dragFrom === -1) { dragging = false; dragLost = true }
      if (dragLost) return
      if (button.isFolder ? button.dock.isTrash(button.item) : button.dock.isFixed(button.item.key)) return
      if (!dragging && Math.abs(m.x - pressX) + Math.abs(m.y - pressY) > dragThreshold) {
        if (button.isFolder) {
          if (!button.window.beginFolderDrag(button.folderIndex, button.iconUrl, button.slotUrl, button.stackFiles)) return
        } else {
          button.window.beginDrag(button.slot, button.iconUrl)
        }
        dragging = true
      }
      if (dragging) button.window.updateDrag(mapToItem(button.window.dragRow, m.x, m.y))
    }

    onReleased: function(m) {
      if (dragLost) suppressClick = true
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
      // The app launcher has no middle-click (its menu has Move and Remove only).
      if (!button.isFolder && button.dock.isApps(button.item.key) && m.button === Qt.MiddleButton) {
        return
      }
      // A click ends keyboard mode, as Enter does (else the dock keeps the keyboard from the app).
      if (m.button !== Qt.RightButton && button.window.keyMode) button.window.exitKeyMode()
      if (m.button === Qt.RightButton) {
        button.window.openMenu(button, button.item, button.isFolder)
      } else if (button.missing) {
        button.window.folderClicked(button, button.item)
      } else if (button.isFolder && m.button === Qt.MiddleButton) {
        button.dock.openFolder(button.item)        // middle-click: open it in Files
      } else if (button.isFolder) {
        button.window.folderClicked(button, button.item)
      } else if (m.button === Qt.MiddleButton) {
        button.dock.launch(button.item)
      } else {
        button.dock.activate(button.item, button.window.screen)
      }
    }
  }

  // Files dropped here: onto Trash moves them to the Trash; onto a folder (Downloads) moves
  // them into it, or copies them when they're on another drive; onto an app opens them
  // with it. Accepted as a "copy" so the app the files came from never deletes them
  // itself; the dock does any moving, and Trash moves can be undone from the Trash.
  // While folders are dragged, only the middle of a folder's icon takes them (moving them
  // into it); its edges are for adding them to the dock (see Dock.qml's folder drop area).
  // Spring-loading: holding a drag over a running app's icon for a second brings its window
  // forward, to drop the files there instead (Files too, though it takes no drops on its icon).
  DropArea {
    id: drop
    readonly property real inset: button.isFolder && button.window.dropHasFolders ? Math.round(button.fullWidth / 4) : 0
    anchors.fill: parent
    anchors.leftMargin: button.contentLeft + inset
    // The Trash, always last, also takes what's dropped past it, up to the end of the
    // dock's hover area: nothing can be added after it, so no gap opens there.
    anchors.rightMargin: button.dock.isTrash(button.item) && button.isFolder
      ? -(button.dock.rightPadFor(button.window.size) + button.dock.hoverSlack) : inset
    enabled: button.acceptsFiles || button.springs
    keys: ["text/uri-list"]
    onEntered: function(d) {
      button.window.dropEnter(d)
      d.accept(Qt.CopyAction)
      if (button.springs) springTimer.restart()
      if (button.isFolder) button.window.dropOnFolderIcon++
    }
    onExited: {
      springTimer.stop()
      if (button.isFolder) {
        button.window.dropOnFolderIcon = Math.max(0, button.window.dropOnFolderIcon - 1)
        button.window.settleDropGap()
      }
      button.window.dropLeave()
    }
    onDropped: function(d) {
      springTimer.stop()
      if (button.isFolder) button.window.dropOnFolderIcon = Math.max(0, button.window.dropOnFolderIcon - 1)
      button.window.dropLeave()
      if (!d.hasUrls || !button.acceptsFiles) { d.accepted = false; return }
      d.accept(Qt.CopyAction)
      button.dock.dropFiles(button.item, button.isFolder, d.urls)
    }
  }
}
