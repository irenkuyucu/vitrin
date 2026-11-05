import QtQuick

// A folder's newest files piled up (see DockButton's "Display as: Stack"): the oldest of
// the three at the back, slightly turned; the newest on top. Also drawn for the copy that
// follows the pointer while the folder is dragged.
Item {
  id: pile

  required property var dock
  property var files: []              // newest first, up to three
  property int size: 48
  // Like macOS, the pile is drawn to fit the slot rather than the slot growing to fit the
  // pile: it never gets wider than the slot's artwork (a document icon's width).
  property real artWidth: size

  Repeater {
    model: pile.files.slice().reverse()
    delegate: FileIcon {
      required property var modelData
      required property int index
      readonly property int depth: pile.files.length - 1 - index   // 0 = newest
      dock: pile.dock
      file: modelData
      size: pile.size
      // Tilted files behind the top one need a little more room for the same width.
      maxWidth: pile.artWidth - (depth === 0 ? 0 : Math.round(pile.size * 0.12))
      anchors.horizontalCenter: parent.horizontalCenter
      y: (pile.height - height) / 2 + 2 - depth * 3
      rotation: depth === 0 ? 0 : (depth === 1 ? -7 : 7)
      opacity: 1 - depth * 0.12
    }
  }
}
