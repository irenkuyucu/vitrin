import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// A folder opened as a stack: its newest files in a grid above the folder's dock icon.
// Click a file to open it; right-click for Open / Show in Files. Clicking anywhere
// outside closes it, like the dock's menus.
PopupWindow {
  id: stack

  required property var dock
  required property var window          // the dock window this stack belongs to

  readonly property var folder: window.stackFolder
  readonly property var files: folder ? dock.filesFor(folder) : []
  readonly property int columns: 4
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

      Grid {
        visible: stack.files.length > 0
        columns: stack.columns

        Repeater {
          model: stack.files
          delegate: Item {
            id: tile
            required property var modelData
            width: stack.tileWidth
            height: stack.tileHeight

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
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              // While a file's menu is open, a click anywhere only closes that menu
              // (like the dock's own menus), so it can't open the file underneath.
              property bool dismissing: false
              onPressed: dismissing = stack.tileMenuFile !== null
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
