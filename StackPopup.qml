import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// A folder opened as a stack: its files, newest first, in a grid above the folder's dock
// icon (up to dock.stackMax of them). The grid shows at most 3 rows (fewer on short
// screens) and scrolls for the rest, creating tiles (and loading thumbnails) only for
// the ones in view. Click a file to open it; right-click for Open / Show in Files.
// Clicking anywhere outside closes it, like the dock's menus. Files can be dragged out of
// it to other apps (a browser upload, Files, a chat), which closes it once dropped.
PopupWindow {
  id: stack

  required property var dock
  required property var window          // the dock window this stack belongs to

  readonly property var folder: window.stackFolder
  readonly property var files: folder ? dock.stackFilesFor(folder) : []
  readonly property int total: folder ? dock.stackTotalFor(folder) : 0
  readonly property int columns: 4
  readonly property int rows: Math.max(1, Math.min(3, Math.ceil(files.length / columns),
    Math.floor((window.screen ? window.screen.height / 2 : 400) / tileHeight)))
  readonly property int tileWidth: 88
  readonly property int tileHeight: 96
  readonly property int iconSize: 48

  // Small per-file menu, drawn inside the stack (right-click a file).
  property var tileMenuFile: null
  property real tileMenuX: 0
  property real tileMenuY: 0

  visible: window.stackOpen && window.stackTarget !== null
  color: "transparent"
  anchor.item: window.stackTarget
  anchor.rect.x: 0
  anchor.rect.y: dock.shadowPad - dock.popupGap
  anchor.rect.width: window.stackTarget ? window.stackTarget.width : 1
  anchor.rect.height: 1
  anchor.edges: Edges.Top
  anchor.gravity: Edges.Top
  implicitWidth: card.width + dock.shadowPad * 2
  implicitHeight: card.height + dock.shadowPad * 2

  onVisibleChanged: if (!visible) tileMenuFile = null

  // File names: up to two lines, shortened in the middle like macOS (see fitName).
  FontMetrics {
    id: nameMetrics
    font.family: stack.dock.uiFont
    font.pixelSize: stack.dock.uiFontSize - 2
  }
  readonly property real nameWidth: stack.tileWidth - 10 - 2   // label width, minus a small safety margin

  // Lines the label would need: wraps after spaces and hyphens, and inside words that
  // are too long for a line (like Text.WrapAtWordBoundaryOrAnywhere).
  function lineCount(s) {
    var tokens = s.match(/[^\s-]*[\s-]*/g).filter(function(t) { return t.length > 0 })
    var lines = 1, x = 0
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i]
      var visible = nameMetrics.advanceWidth(t.replace(/\s+$/, ""))
      if (x > 0 && x + visible > stack.nameWidth) { lines++; x = 0 }
      if (visible <= stack.nameWidth) { x += nameMetrics.advanceWidth(t); continue }
      for (var c = 0; c < t.length; c++) {
        var cw = nameMetrics.advanceWidth(t[c])
        if (x > 0 && x + cw > stack.nameWidth) { lines++; x = 0 }
        x += cw
      }
    }
    return lines
  }

  // macOS-style: a name that needs more than two lines keeps whole words on the first
  // line, and the second line is shortened in the middle, keeping the end of the name
  // (with its extension): "Quarterly report final" / "versi…(copy 3).pdf".
  function fitName(name) {
    if (lineCount(name) <= 2) return name
    // First line: as many whole words (or, for one long word, characters) as fit.
    var tokens = name.match(/[^\s-]*[\s-]*/g).filter(function(t) { return t.length > 0 })
    var first = ""
    for (var i = 0; i < tokens.length; i++) {
      if (nameMetrics.advanceWidth((first + tokens[i]).replace(/\s+$/, "")) > stack.nameWidth) break
      first += tokens[i]
    }
    if (first.length === 0) {
      while (first.length < name.length && nameMetrics.advanceWidth(name.slice(0, first.length + 1)) <= stack.nameWidth)
        first = name.slice(0, first.length + 1)
    }
    var rest = name.slice(first.length)
    first = first.replace(/\s+$/, "")
    // Second line: start of the rest + "…" + end of the name. The end always keeps the
    // extension; the remaining room is shared evenly between start and end (like macOS),
    // growing each by one character in turn until the line is full.
    if (nameMetrics.advanceWidth(rest) <= stack.nameWidth) return first + "\n" + rest
    var dot = rest.lastIndexOf(".")
    var ext = dot > 0 && rest.length - dot <= 8 ? rest.length - dot : 0
    var headLen = 0
    var tailLen = Math.min(ext, rest.length - 1)
    function line(h, t) {
      return rest.slice(0, h).replace(/\s+$/, "") + "…" + rest.slice(rest.length - t)
    }
    var growHead = true
    var stuck = 0
    while (headLen + tailLen < rest.length - 1 && stuck < 2) {
      var h = headLen + (growHead ? 1 : 0)
      var t = tailLen + (growHead ? 0 : 1)
      if (nameMetrics.advanceWidth(line(h, t)) <= stack.nameWidth) {
        headLen = h
        tailLen = t
        stuck = 0
      } else {
        stuck++
      }
      growHead = !growHead
    }
    return first + "\n" + line(headLen, tailLen)
  }

  function openFile(file) {
    stack.window.closeStack()
    stack.dock.openFile(file.path)
  }

  function showInFiles(file) {
    stack.window.closeStack()
    stack.dock.showInFiles(file.path)
  }

  function openFolder() {
    var folder = stack.folder
    stack.window.closeStack()
    stack.dock.openFolder(folder)
  }

  function showTileMenu(tile, file) {
    var pos = tile.mapToItem(card, tile.width / 2, tile.height / 2)
    stack.tileMenuX = Math.max(6, Math.min(card.width - tileMenu.width - 6, pos.x - tileMenu.width / 2))
    stack.tileMenuY = Math.max(6, Math.min(card.height - tileMenu.height - 6, pos.y))
    stack.tileMenuFile = file
  }

  Rectangle {
    id: card
    x: stack.dock.shadowPad
    y: stack.dock.shadowPad
    width: stack.columns * stack.tileWidth + 24
    height: content.implicitHeight + 24
    color: stack.dock.surface
    border.color: stack.dock.hairline
    border.width: 1
    radius: stack.dock.menuRadius

    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: Qt.rgba(0, 0, 0, 0.4)
      shadowBlur: 0.6
      shadowVerticalOffset: 2
    }

    // Clicking empty space closes the per-file menu.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: stack.tileMenuFile = null
    }

    Column {
      id: content
      x: 12
      y: 12
      width: card.width - 24
      spacing: 10

      Text {
        text: stack.folder ? stack.folder.name : ""
        color: Commons.Color.popups.text
        font.family: stack.dock.uiFont
        font.pixelSize: stack.dock.uiFontSize + 1
        font.weight: Font.DemiBold
        leftPadding: 4
      }

      Text {
        visible: stack.files.length === 0
        width: parent.width
        height: 70
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "No items"
        color: Commons.Color.popups.text
        opacity: 0.6
        font.family: stack.dock.uiFont
        font.pixelSize: stack.dock.uiFontSize
      }

      GridView {
        id: grid
        visible: stack.files.length > 0
        width: stack.columns * stack.tileWidth
        height: stack.rows * stack.tileHeight
        cellWidth: stack.tileWidth
        cellHeight: stack.tileHeight
        model: stack.files
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Scrolls with momentum (Qt's own). Not while a file's menu is open: the files stay
        // put under it, like the dock's other menus.
        interactive: stack.tileMenuFile === null
        cacheBuffer: stack.tileHeight      // a row above and below, for smooth scrolling
        readonly property bool scrolls: contentHeight > height + 0.5
        // Back to the newest files whenever the stack opens or the folder changes.
        Connections {
          target: stack
          function onFolderChanged() { grid.positionViewAtBeginning() }
          function onVisibleChanged() { if (stack.visible) grid.positionViewAtBeginning() }
        }

          delegate: Item {
            id: tile
            required property var modelData
            width: stack.tileWidth
            height: stack.tileHeight

            // Dragging the file out, shown as its icon. Offered as copy or move: the app it's
            // dropped on decides. Files moves it (same drive), apps like a browser or a chat
            // copy it. (Modifier keys can't change that here: the dock never has keyboard
            // focus, so it can't see them, and the target only does if it was focused.)
            Drag.dragType: Drag.Automatic
            Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
            Drag.proposedAction: Qt.CopyAction
            Drag.mimeData: ({ "text/uri-list": Util.fileUrl(tile.modelData.path) + "\r\n" })
            Drag.hotSpot.x: stack.iconSize / 2
            Drag.hotSpot.y: stack.iconSize / 2
            Drag.active: tileMouse.drag.active
            Drag.onDragStarted: stack.window.stackDragging = true
            Drag.onDragFinished: function(dropAction) {
              stack.window.stackDragging = false
              stack.window.closeStack()
              stack.dock.refreshFolders()   // a moved file is gone from the folder
            }
            Item { id: dragHandle }         // what the press-and-drag moves (nothing visible)

            Rectangle {
              anchors.fill: parent
              anchors.margins: 2
              radius: stack.dock.rowRadius
              color: tileMouse.pressed && !tileMouse.dismissing ? Util.alpha(stack.dock.foreground, 0.16)
                   : tileMouse.containsMouse || stack.tileMenuFile === tile.modelData ? stack.dock.rowHover
                   : "transparent"
            }

            FileIcon {
              id: tileIcon
              dock: stack.dock
              file: tile.modelData
              size: stack.iconSize
              anchors.horizontalCenter: parent.horizontalCenter
              y: 8
            }

            Text {
              anchors.top: tileIcon.bottom
              anchors.topMargin: 4
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - 10
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WrapAtWordBoundaryOrAnywhere
              maximumLineCount: 2
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: stack.fitName(tile.modelData.name)
              color: Commons.Color.popups.text
              font.family: stack.dock.uiFont
              font.pixelSize: stack.dock.uiFontSize - 2
            }

            MouseArea {
              id: tileMouse
              anchors.fill: parent
              hoverEnabled: true
              onWheel: function(w) { w.accepted = false }   // scrolling is for the grid
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              // Left-dragging a file drags it out of the stack (not while its menu is open).
              drag.target: stack.tileMenuFile === null ? dragHandle : null
              drag.threshold: 8
              preventStealing: true   // a drag is the file's, not the grid scrolling
              onPressed: function(m) {
                dismissing = stack.tileMenuFile !== null
                // The drag image: a snapshot of the icon, ready before the drag starts.
                if (m.button === Qt.LeftButton && !dismissing)
                  tileIcon.grabToImage(function(result) { tile.Drag.imageSource = result.url },
                                       Qt.size(stack.iconSize, stack.iconSize))
              }
              // While a file's menu is open, a click anywhere only closes that menu
              // (like the dock's own menus), so it can't open the file underneath.
              property bool dismissing: false
              onClicked: function(m) {
                if (dismissing) {
                  stack.tileMenuFile = null
                  return
                }
                if (m.button === Qt.RightButton) stack.showTileMenu(tile, tile.modelData)
                else stack.openFile(tile.modelData)
              }
            }
          }

        // Fades over the grid's top and bottom where more files are hidden.
        Rectangle {
          parent: grid
          visible: grid.scrolls && !grid.atYBeginning
          anchors { left: parent.left; right: parent.right; top: parent.top }
          height: 20
          z: 5
          gradient: Gradient {
            GradientStop { position: 0; color: stack.dock.surface }
            GradientStop { position: 1; color: Qt.rgba(stack.dock.surface.r, stack.dock.surface.g, stack.dock.surface.b, 0) }
          }
        }
        Rectangle {
          parent: grid
          visible: grid.scrolls && !grid.atYEnd
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: 20
          z: 5
          gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(stack.dock.surface.r, stack.dock.surface.g, stack.dock.surface.b, 0) }
            GradientStop { position: 1; color: stack.dock.surface }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: stack.dock.hairline
      }

      Item {
        width: parent.width
        height: 32

        // When the folder has more than the stack shows.
        Text {
          visible: stack.total > stack.files.length && stack.files.length > 0
          anchors.verticalCenter: parent.verticalCenter
          leftPadding: 4
          text: "Newest " + stack.files.length.toLocaleString(Qt.locale(), "f", 0)
            + " of " + stack.total.toLocaleString(Qt.locale(), "f", 0)
          color: Commons.Color.popups.text
          opacity: 0.6
          font.family: stack.dock.uiFont
          font.pixelSize: stack.dock.uiFontSize - 1
        }

        Rectangle {
          anchors.right: parent.right
          width: openText.implicitWidth + 24
          height: parent.height
          radius: stack.dock.rowRadius
          color: openMouse.pressed ? Util.alpha(stack.dock.foreground, 0.16)
               : openMouse.containsMouse ? stack.dock.rowHover
               : Util.alpha(stack.dock.foreground, 0.06)
          Text {
            id: openText
            anchors.centerIn: parent
            text: "Open in Files"
            color: Commons.Color.popups.text
            font.family: stack.dock.uiFont
            font.pixelSize: stack.dock.uiFontSize
          }
          MouseArea {
            id: openMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
              if (stack.tileMenuFile !== null) stack.tileMenuFile = null   // just close the file menu
              else stack.openFolder()
            }
          }
        }
      }
    }

    // Per-file menu (right-click a file).
    Rectangle {
      id: tileMenu
      visible: stack.tileMenuFile !== null
      z: 10
      x: stack.tileMenuX
      y: stack.tileMenuY
      width: 160
      height: tileMenuColumn.implicitHeight + 12
      color: Qt.lighter(stack.dock.surface, 1.12)
      border.color: stack.dock.hairline
      border.width: 1
      radius: stack.dock.menuRadius - 2

      Column {
        id: tileMenuColumn
        x: 6
        y: 6
        width: parent.width - 12

        Repeater {
          model: [
            { label: "Open", act: "open" },
            { label: "Show in Files", act: "reveal" }
          ]
          delegate: Rectangle {
            required property var modelData
            width: tileMenuColumn.width
            height: 30
            radius: stack.dock.rowRadius
            color: rowMouse.containsMouse ? stack.dock.rowHover : "transparent"
            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: 10
              text: parent.modelData.label
              color: Commons.Color.popups.text
              font.family: stack.dock.uiFont
              font.pixelSize: stack.dock.uiFontSize
            }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                var file = stack.tileMenuFile
                if (parent.modelData.act === "open") stack.openFile(file)
                else stack.showInFiles(file)
              }
            }
          }
        }
      }
    }
  }
}
