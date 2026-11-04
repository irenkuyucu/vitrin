import QtQuick
import Quickshell
import qs.Commons

// One file as an icon: a preview in a thin white frame (like macOS) when there is one,
// else its file-type icon. `file` comes from Dock.filesFor().
Item {
  id: fileIcon

  required property var dock
  property var file: null
  property int size: 48
  property real maxWidth: size     // the widest the visible picture may be (see DockButton)

  // Previews come from the shared thumbnail cache (~/.cache/thumbnails), which Files fills
  // for every type it has a previewer for: images, PDFs, videos, music covers, Office
  // documents... So any file Files shows a preview for gets the same one here (once Files
  // has made it; we don't generate any). Images without one are shown themselves (slower
  // for big photos); other files show their type icon. Whether the cache has one is
  // checked by the dock's silent icon measurer (as for icon files, see Dock.qml's
  // displayableIcon), so a missing cache file never makes an Image print "Cannot open".
  readonly property var cacheSources: {
    if (!file || file.isDir) return []
    // The cache names a thumbnail after the MD5 of the file's URI, escaped the GLib way.
    var uri = ("file://" + encodeURI(file.path)).replace(/#/g, "%23").replace(/\?/g, "%3F")
    var hash = Qt.md5(uri)
    var cache = Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")
    return ["file://" + cache + "/thumbnails/large/" + hash + ".png",
            "file://" + cache + "/thumbnails/normal/" + hash + ".png"]
  }
  function requestCacheChecks() {
    for (var i = 0; i < cacheSources.length; i++) dock.requestMeasurement(cacheSources[i])
  }
  onCacheSourcesChanged: requestCacheChecks()
  Component.onCompleted: requestCacheChecks()

  // The first cached thumbnail that loads, else the image itself (images only); "" for no
  // preview, or while still checking.
  readonly property string thumbSource: {
    if (cacheSources.length === 0) return ""
    for (var i = 0; i < cacheSources.length; i++) {
      var known = dock.iconExtents[cacheSources[i]]
      if (known) return cacheSources[i]
      if (known === undefined) return ""
    }
    return file.image ? Util.fileUrl(file.path) : ""
  }

  width: size
  height: size

  Rectangle {
    visible: fileIcon.thumbSource !== "" && thumb.status === Image.Ready
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
    visible: fileIcon.thumbSource !== ""
    anchors.centerIn: parent
    width: Math.min(fileIcon.size - 6, fileIcon.maxWidth - 4)   // 4: the white frame
    height: fileIcon.size - 6
    fillMode: Image.PreserveAspectFit
    source: fileIcon.thumbSource
    autoTransform: true          // photos' rotation tags (portrait phone photos stay upright)
    sourceSize.width: fileIcon.dock.iconSourceSize
    sourceSize.height: fileIcon.dock.iconSourceSize
    asynchronous: true
    smooth: true
  }

  Image {
    id: typeIcon
    // The file-type icon: with no preview, while one is still being looked up, and if the
    // image itself can't be read.
    visible: fileIcon.thumbSource === "" || thumb.status === Image.Error
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
