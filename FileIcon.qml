import QtQuick
import Quickshell
import qs.Commons

// One file as an icon: images show a small thumbnail in a thin white frame (like macOS);
// everything else shows its file-type icon. `file` comes from Dock.filesFor().
Item {
  id: fileIcon

  required property var dock
  property var file: null
  property int size: 48
  property real maxWidth: size     // the widest the visible picture may be (see DockButton)

  readonly property bool thumbnail: !!file && file.image

  // Thumbnails come from the shared thumbnail cache (~/.cache/thumbnails, filled by Files
  // and other apps) when it has one: small and quick to load. Otherwise the image itself
  // is decoded, which for a big photo is slow. Tried in order; a missing one fails over.
  readonly property var thumbSources: {
    if (!thumbnail) return []
    // The cache names a thumbnail after the MD5 of the file's URI, escaped the GLib way.
    var uri = ("file://" + encodeURI(file.path)).replace(/#/g, "%23").replace(/\?/g, "%3F")
    var hash = Qt.md5(uri)
    var cache = Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")
    return ["file://" + cache + "/thumbnails/large/" + hash + ".png",
            "file://" + cache + "/thumbnails/normal/" + hash + ".png",
            Util.fileUrl(file.path)]
  }
  property int thumbTry: 0
  onFileChanged: thumbTry = 0

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
    width: Math.min(fileIcon.size - 6, fileIcon.maxWidth - 4)   // 4: the white frame
    height: fileIcon.size - 6
    fillMode: Image.PreserveAspectFit
    source: fileIcon.thumbnail && fileIcon.thumbTry < fileIcon.thumbSources.length
      ? fileIcon.thumbSources[fileIcon.thumbTry] : ""
    onStatusChanged: if (status === Image.Error && fileIcon.thumbTry < fileIcon.thumbSources.length - 1) fileIcon.thumbTry++
    sourceSize.width: fileIcon.dock.iconSourceSize
    sourceSize.height: fileIcon.dock.iconSourceSize
    asynchronous: true
    smooth: true
  }

  Image {
    id: typeIcon
    visible: !fileIcon.thumbnail || (thumb.status === Image.Error && fileIcon.thumbTry >= fileIcon.thumbSources.length - 1)
    anchors.fill: parent
    source: fileIcon.file ? fileIcon.dock.iconSource(fileIcon.file.icon) : ""
    // File-type icons wider than maxWidth (once measured) are scaled down to fit.
    readonly property var extent: fileIcon.dock.iconExtents[String(source)]
    scale: extent ? Math.min(1, fileIcon.maxWidth / ((extent.r - extent.l) * fileIcon.size)) : 1
    onSourceChanged: fileIcon.dock.requestMeasurement(String(source))
    Component.onCompleted: fileIcon.dock.requestMeasurement(String(source))
    sourceSize.width: fileIcon.dock.iconSourceSize
    sourceSize.height: fileIcon.dock.iconSourceSize
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
  }
}
