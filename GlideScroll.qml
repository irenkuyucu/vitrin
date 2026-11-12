import QtQuick

// Touchpad scrolling for a vertical Flickable. Qt moves a list exactly as far as the fingers
// travel and stops the moment they lift (the touchpad sends no momentum of its own), and
// Omarchy slows every touchpad down in the compositor, so scrolling feels heavy. This follows
// the fingers (scaled back up), then carries on from where they were, at the speed they had,
// slowing down smoothly. Mouse wheels are left to the Flickable. Put it over the view:
//
//   GlideScroll { anchors.fill: view; view: view }
MouseArea {
  id: layer
  required property Flickable view

  acceptedButtons: Qt.NoButton
  enabled: view.interactive

  // How far the content moves per pixel of finger movement: Omarchy's compositor scales
  // touchpad scrolling by 0.4 (input.touchpad.scroll_factor), and 2.5 undoes that.
  property real gain: 2.5
  // How the glide dies down: it covers (speed x glideTime) in all.
  property real glideTime: 0.3

  property var samples: []        // [{ t, d }]: the finger movement of the last ~100 ms
  property real lastEventAt: 0
  property bool gliding: false
  property real glideSpeed: 0     // px/s the glide starts with
  property real glideFrom: 0      // contentY when the fingers lifted

  function move(y) {
    var min = view.originY
    var max = view.originY + Math.max(0, view.contentHeight - view.height)
    view.contentY = Math.max(min, Math.min(max, y))
    return view.contentY === y
  }

  onEnabledChanged: if (!enabled) tick.stop()

  onWheel: function(e) {
    // A wheel notch is a multiple of 120 with no pixel delta: Qt's own scrolling handles it.
    // (Touchpad events can carry a fraction of a pixel: the angle still tells how far.)
    if (e.pixelDelta.y === 0 && e.angleDelta.y % 120 === 0) { e.accepted = false; return }
    if (Math.abs(e.pixelDelta.x) > Math.abs(e.pixelDelta.y)) { e.accepted = false; return }
    var d = (e.pixelDelta.y !== 0 ? e.pixelDelta.y : e.angleDelta.y / 12) * gain
    view.cancelFlick()
    gliding = false
    move(view.contentY - d)
    lastEventAt = Date.now()
    samples = samples.filter(function(s) { return lastEventAt - s.t < 100 }).concat([{ t: lastEventAt, d: d }])
    tick.start()
  }

  // Runs from the first event until the glide ends. While events keep coming the fingers are
  // down; 40 ms without one means they have lifted: glide on at the speed of their last ~80 ms,
  // as if the movement had never paused.
  Timer {
    id: tick
    interval: 16
    repeat: true
    onTriggered: {
      var since = (Date.now() - layer.lastEventAt) / 1000
      if (!layer.gliding) {
        if (since < 0.04) return
        var recent = layer.samples.filter(function(s) { return layer.lastEventAt - s.t < 80 })
        var sum = 0
        for (var i = 0; i < recent.length; i++) sum += recent[i].d
        var speed = sum / Math.max(0.016, (layer.lastEventAt - recent[0].t) / 1000)
        if (Math.abs(speed) < 80) { stop(); return }
        layer.glideSpeed = Math.max(-layer.view.maximumFlickVelocity, Math.min(layer.view.maximumFlickVelocity, speed))
        layer.glideFrom = layer.view.contentY
        layer.gliding = true
      }
      var y = layer.glideFrom - layer.glideSpeed * layer.glideTime * (1 - Math.exp(-since / layer.glideTime))
      if (!layer.move(y) || Math.abs(layer.glideSpeed) * Math.exp(-since / layer.glideTime) < 20) {
        layer.gliding = false
        stop()
      }
    }
  }
}
