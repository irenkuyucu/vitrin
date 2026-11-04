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

  // Previews come from the shared thumbnail cache (~/.cache/thumbnails), the one Files uses,
  // for every type there's a previewer for: images, PDFs, videos, music covers, Office
  // documents... Missing or outdated ones are made the way Files would (see Dock.qml's
  // requestPreview), which also tells this icon where its preview is. Until then it shows
  // its type icon; images without a preview are shown themselves.
  property string previewUrl: ""
  property bool previewAnswered: false

  function lookUpPreview() {
    var known = file ? dock.previewKnown[file.path] : undefined
    previewUrl = known ? known.url : ""
    previewAnswered = known !== undefined
  }
  function askForPreview() {
    lookUpPreview()
    if (file) dock.requestPreview(file)
  }
  onFileChanged: askForPreview()
  Component.onCompleted: askForPreview()
  // Out of view (scrolled away, stack closed): its preview isn't needed any more.
  Component.onDestruction: dock.cancelPreview(file)
  Connections {
    target: fileIcon.dock
    function onPreviewReady(path) { if (fileIcon.file && path === fileIcon.file.path) fileIcon.lookUpPreview() }
  }

  // What the frame shows: the preview, else the image itself; "" for the type icon.
  readonly property string thumbSource: previewUrl !== "" ? previewUrl
    : (previewAnswered && file && file.image ? Util.fileUrl(file.path) : "")

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
