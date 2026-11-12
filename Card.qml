import QtQuick
import QtQuick.Effects

// A popup surface: the menus, the stacks, the settings and the labels all share this look
// (the dock's surface colour, a hairline border, rounded corners, a soft shadow). The shadow
// can be tuned for smaller ones.
Rectangle {
  id: card

  required property var dock
  property real shadowOpacity: 0.4
  property real shadowBlur: 0.6
  property real shadowOffset: 2

  color: dock.surface
  border.color: dock.hairline
  border.width: 1
  radius: dock.menuRadius

  layer.enabled: true
  layer.effect: MultiEffect {
    shadowEnabled: true
    shadowColor: Qt.rgba(0, 0, 0, card.shadowOpacity)
    shadowBlur: card.shadowBlur
    shadowVerticalOffset: card.shadowOffset
  }
}
