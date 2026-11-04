import QtQuick
import qs.Commons

// On/off switch in the GNOME/Adwaita style: a rounded track with a sliding knob.
Item {
  id: control

  required property var dock
  property bool checked: false
  signal toggled(bool checked)

  implicitWidth: 42
  implicitHeight: 24

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: control.checked ? control.dock.accent : Util.alpha(control.dock.foreground, 0.18)
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      width: parent.height - 6
      height: width
      radius: width / 2
      y: 3
      x: control.checked ? parent.width - width - 3 : 3
      color: "#ffffff"
      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }
  }

  MouseArea {
    anchors.fill: parent
    onClicked: control.toggled(!control.checked)
  }
}
