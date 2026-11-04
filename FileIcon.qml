import QtQuick
import qs.Commons

// One file as an icon: images show a small thumbnail in a thin white frame (like macOS);
// everything else shows its file-type icon. `file` comes from Dock.filesFor().
Item {
  id: fileIcon

  required property var dock
  property var file: null
  property int size: 48

  readonly property bool thumbnail: !!file && file.image

  width: size
  height: size

  Rectangle {
    visible: fileIcon.thumbnail && thumb.status === Image.Ready
    anchors.centerIn: parent
    width: thumb.paintedWidth + 4
    height: thumb.paintedHeight + 4
    radius: 2
    color: "#ffffff"
    border.color: Util.alpha("#000000", 0.2)
    border.width: 1
  }

  Image {
    id: thumb
    visible: fileIcon.thumbnail
    anchors.centerIn: parent
    width: fileIcon.size - 6
    height: fileIcon.size - 6
    fillMode: Image.PreserveAspectFit
    source: fileIcon.thumbnail ? Util.fileUrl(fileIcon.file.path) : ""
    sourceSize.width: fileIcon.size * 2
    sourceSize.height: fileIcon.size * 2
    asynchronous: true
    smooth: true
  }

  Image {
    visible: !fileIcon.thumbnail || thumb.status === Image.Error
    anchors.fill: parent
    source: fileIcon.file ? fileIcon.dock.iconSource(fileIcon.file.icon) : ""
    sourceSize.width: fileIcon.size * 2
    sourceSize.height: fileIcon.size * 2
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
  }
}
