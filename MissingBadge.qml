import QtQuick
import qs.Commons as Commons

// The question mark on a folder that can't be found, at the bottom right of its icon.
// Positioned by whoever shows it: `iconSize` is the icon's drawn size.
Rectangle {
  required property var dock
  property real iconSize: 48

  width: Math.round(iconSize * 0.42)
  height: width
  radius: width / 2
  color: dock.surface
  border.color: dock.hairline
  border.width: 1
  Text {
    anchors.centerIn: parent
    text: "?"
    color: Commons.Color.popups.text
    font.family: dock.uiFont
    font.pixelSize: Math.round(parent.width * 0.62)
    font.bold: true
  }
}
