import QtQuick
import qs.Commons

// A ring just outside its parent, marking the button the keyboard has. (An outline drawn on the
// button itself disappears on the accent-coloured one.)
Rectangle {
  required property var dock
  property bool shown: false

  visible: shown
  anchors.fill: parent
  anchors.margins: -4
  radius: (parent && parent.radius !== undefined ? parent.radius : 8) + 4
  color: "transparent"
  border.width: 2
  border.color: Util.alpha(dock.foreground, 0.9)
}
