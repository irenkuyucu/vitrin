import QtQuick
import qs.Commons

// Horizontal slider in the GNOME/Adwaita style. `moved` fires while dragging (apply live);
// `released` fires once when the user lets go (persist then).
Item {
  id: control

  required property var dock
  property real from: 0
  property real to: 100
  property real stepSize: 1
  property real value: 0
  property bool enabledLook: true
  property bool focused: false          // the keyboard has it: the knob gets a ring

  signal moved(real value)
  signal released(real value)

  implicitWidth: 200
  implicitHeight: 24
  opacity: enabledLook ? 1 : 0.4

  readonly property real fraction: to > from ? (value - from) / (to - from) : 0
  readonly property real knobSize: 18

  function valueAt(x) {
    var f = Math.max(0, Math.min(1, (x - knobSize / 2) / (width - knobSize)))
    var raw = from + f * (to - from)
    return Math.max(from, Math.min(to, Math.round(raw / stepSize) * stepSize))
  }

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    x: control.knobSize / 2
    width: parent.width - control.knobSize
    height: 4
    radius: 2
    color: Util.alpha(control.dock.foreground, 0.18)

    Rectangle {
      width: parent.width * control.fraction
      height: parent.height
      radius: parent.radius
      color: control.dock.accent
    }
  }

  Rectangle {
    width: control.knobSize
    height: control.knobSize
    radius: width / 2
    anchors.verticalCenter: parent.verticalCenter
    x: control.fraction * (control.width - control.knobSize)
    color: "#ffffff"
    border.color: Util.alpha("#000000", 0.15)
    border.width: 1
  }

  Rectangle {
    visible: control.focused
    width: control.knobSize + 8
    height: width
    radius: width / 2
    anchors.verticalCenter: parent.verticalCenter
    x: control.fraction * (control.width - control.knobSize) - 4
    color: "transparent"
    border.width: 2
    border.color: control.dock.accent
  }

  MouseArea {
    anchors.fill: parent
    enabled: control.enabledLook
    preventStealing: true
    onPressed: function(m) { control.moved(control.valueAt(m.x)) }
    onPositionChanged: function(m) { if (pressed) control.moved(control.valueAt(m.x)) }
    onReleased: function(m) { control.released(control.valueAt(m.x)) }
  }
}
