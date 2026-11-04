import QtQuick

// Last-resort icon for an app with no usable icon: a rounded tile with the app's initial,
// in a color worked out from its name (so different unknown apps look different, and the
// same app always looks the same). Fills 81% of `size`, like a normalized square icon.
Item {
  id: letter

  property string name: ""
  property int size: 48

  width: size
  height: size

  readonly property real hue: {
    var h = 0
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360
    return h / 360
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.round(letter.size * 0.81)
    height: width
    radius: Math.round(width * 0.22)
    color: Qt.hsla(letter.hue, 0.45, 0.42, 1)

    Text {
      anchors.centerIn: parent
      text: letter.name.replace(/[^A-Za-z0-9]/g, "").charAt(0).toUpperCase() || "?"
      color: "#ffffff"
      font.family: "Adwaita Sans"
      font.pixelSize: Math.round(parent.width * 0.5)
      font.weight: Font.DemiBold
    }
  }
}
