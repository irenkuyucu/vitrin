import QtQuick
import qs.Commons as Commons

// The Apps icon: a 3x3 grid of tiles in a thin outlined square, drawn in the Omarchy
// theme's accent color (so it follows theme switches and looks the same with any icon
// theme). Fills 81% of `size`, like a normalized square icon (see LetterIcon.qml).
// Sizes and positions are whole pixels, so the tiles sit exactly centered and crisp.
Item {
  id: apps

  property int size: 48

  width: size
  height: size

  Rectangle {
    id: frame
    x: Math.floor((apps.size - width) / 2)
    y: Math.floor((apps.size - height) / 2)
    width: Math.round(apps.size * 0.81)
    height: width
    radius: Math.round(width * 0.14)
    color: "transparent"
    border.color: Commons.Color.accent
    border.width: 1

    // The tiles' margin inside the square must be even to split into two equal whole-pixel
    // sides: so the tile size is the whole number nearest 18% of the width that leaves an
    // even margin (the two gaps are even together anyway).
    readonly property int gap: Math.round(width * 0.07)
    readonly property int tile: {
      var exact = width * 0.18
      var t = Math.round(exact)
      if ((width - 3 * t) % 2 === 0) return t
      return Math.abs(t - 1 - exact) < Math.abs(t + 1 - exact) ? t - 1 : t + 1
    }
    readonly property int start: (width - (tile * 3 + gap * 2)) / 2

    Repeater {
      model: 9
      delegate: Rectangle {
        required property int index
        x: frame.start + (index % 3) * (frame.tile + frame.gap)
        y: frame.start + Math.floor(index / 3) * (frame.tile + frame.gap)
        width: frame.tile
        height: frame.tile
        radius: Math.max(1, Math.min(2, Math.round(frame.tile * 0.15)))
        color: Commons.Color.accent
      }
    }
  }
}
