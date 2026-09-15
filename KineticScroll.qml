import QtQuick

Item {
  id: root

  property real viewportSize: 0
  property real contentSize: 0

  property real minPosition: 0
  property real maxPosition: Math.max(0, root.contentSize - root.viewportSize)

  property real restPosition: 0

  property real snapStride: 0

  signal snapped(int index)

  signal settled()

  property bool announceSettle: false

  property real dragScale: 1
  property real notchPixels: 110

  property real momentumTau: 0.85
  property real maxVelocity: 18000
  property real minVelocity: 25

  property real bandTau: 0.13
  property real glideTau: 0.12

  property real snapProjection: 0.2

  property real position: 0

  readonly property bool overflows: root.maxPosition - root.minPosition > 0.5
  readonly property bool snaps: root.snapStride > 0.5

  readonly property int lastSnapIndex: root.snaps
    ? Math.max(0, Math.round((root.maxPosition - root.minPosition) / root.snapStride))
    : 0

  property bool dragging: false

  readonly property bool moving: root.dragging || runner.running

  property bool interactive: false

  property bool frozen: false

  function clamp(p) { return Math.max(root.minPosition, Math.min(root.maxPosition, p)) }

  function edgeFor(p) {
    if (p < root.minPosition) return root.minPosition
    if (p > root.maxPosition) return root.maxPosition
    return undefined
  }

  function snapIndexFor(p) {
    if (!root.snaps) return 0
    var i = Math.round((p - root.minPosition) / root.snapStride)
    return Math.max(0, Math.min(root.lastSnapIndex, i))
  }

  function snapPositionFor(index) {
    return root.clamp(root.minPosition + index * root.snapStride)
  }

  function reset() {
    runner.mode = ""
    runner.running = false
    root.announceSettle = false
    idle.stop()
    root.velocity = 0
    root.samples = []
    root.notchAccum = 0
    root.dragging = false
    root.interactive = false
    settleTimer.restart()
    root.position = root.clamp(root.restPosition)
  }

  function stop() {
    root.velocity = 0
    root.announceSettle = false
    runner.mode = ""
    runner.running = false
  }

  function settleNow() {
    var announce = root.announceSettle
    root.stop()
    if (announce) root.settled()
  }

  function dragBy(delta) {
    if (root.frozen || delta === 0) return

    root.stop()
    root.announceSettle = true
    root.dragging = true
    root.interactive = true

    var d = delta * root.dragScale
    var over = root.edgeFor(root.position)

    if (over !== undefined && (root.position - over < 0) === (d < 0)) {
      d *= root.bandResistance(root.position - over)
    }

    root.position += d
    root.track(d)
    idle.restart()
  }

  function endDrag() {
    idle.stop()
    root.dragging = false
    if (root.frozen) { root.samples = []; return }

    root.velocity = root.measureVelocity()
    root.samples = []
    if (root.snaps) {
      var i = root.snapIndexFor(root.position + root.velocity * root.snapProjection)
      root.glideTo(root.snapPositionFor(i))
      root.snapped(i)
      return
    }
    runner.mode = "momentum"
    runner.running = true
  }

  function stepBy(notches) {
    if (root.frozen || !root.overflows || notches === 0) return
    root.interactive = true
    root.announceSettle = true

    if (root.snaps) {

      root.notchAccum += notches
      var whole = root.notchAccum > 0
        ? Math.floor(root.notchAccum)
        : Math.ceil(root.notchAccum)
      if (whole === 0) return
      root.notchAccum -= whole
      var from = runner.mode === "glide" ? runner.target : root.position
      var i = Math.max(0, Math.min(root.lastSnapIndex, root.snapIndexFor(from) + whole))
      root.glideTo(root.snapPositionFor(i))
      root.snapped(i)
      return
    }

    var base = runner.mode === "glide" ? runner.target : root.position
    root.glideTo(base + notches * root.notchPixels)
  }

  function glideTo(target, quiet) {
    if (root.frozen) return
    if (quiet) root.announceSettle = false
    var t = root.clamp(target)
    root.velocity = 0
    if (Math.abs(t - root.position) < 0.5) {
      root.position = t
      root.settleNow()
      return
    }
    runner.target = t
    runner.mode = "glide"
    runner.running = true
  }

  property real velocity: 0
  property real notchAccum: 0

  property var samples: []
  readonly property int velocityWindow: 90

  function bandResistance(over) {
    var reach = Math.max(1, root.viewportSize * 0.1375)
    return Math.max(0.03, 1 - Math.abs(over) / reach)
  }

  function track(d) {
    var now = Date.now()
    var s = root.samples
    s.push({ t: now, d: d })
    while (s.length > 0 && now - s[0].t > root.velocityWindow) s.shift()
  }

  function measureVelocity() {
    var s = root.samples
    if (s.length < 2) return 0
    var span = Date.now() - s[0].t
    if (span < 8) return 0

    var sum = 0
    for (var i = 1; i < s.length; i++) sum += s[i].d
    var v = sum * 1000 / span
    return Math.max(-root.maxVelocity, Math.min(root.maxVelocity, v))
  }

  Timer {
    id: idle
    interval: 140
    onTriggered: root.endDrag()
  }

  Timer {
    id: settleTimer
    interval: 150
    onTriggered: root.interactive = true
  }

  FrameAnimation {
    id: runner
    running: false

    property string mode: ""
    property real target: 0

    onTriggered: {

      var dt = Math.min(0.05, runner.frameTime)

      if (runner.mode === "glide") {
        var kg = 1 - Math.exp(-dt / root.glideTau)
        root.position += (runner.target - root.position) * kg
        if (Math.abs(runner.target - root.position) < 0.5) {
          root.position = runner.target
          root.settleNow()
        }
        return
      }

      var edge = root.edgeFor(root.position)
      if (edge !== undefined) {

        var w = 1 / root.bandTau
        root.velocity += (-(w * w) * (root.position - edge) - 2 * w * root.velocity) * dt
        root.position += root.velocity * dt
        if (Math.abs(root.position - edge) < 0.5 && Math.abs(root.velocity) < root.minVelocity) {
          root.position = edge
          root.settleNow()
        }
        return
      }

      if (Math.abs(root.velocity) < root.minVelocity) {
        root.settleNow()
        return
      }

      root.position += root.velocity * dt
      var km = 1 - Math.exp(-dt / root.momentumTau)
      root.velocity -= root.velocity * km

      if (root.edgeFor(root.position) !== undefined) root.velocity *= 0.25
    }
  }

  onRestPositionChanged: {
    if (root.frozen || root.dragging) return
    if (root.interactive) root.glideTo(root.restPosition, true)
    else root.position = root.clamp(root.restPosition)
  }

  function reclamp() {
    if (root.frozen || root.dragging || runner.running) return
    root.position = root.clamp(root.interactive ? root.position : root.restPosition)
  }

  onMinPositionChanged: root.reclamp()
  onMaxPositionChanged: root.reclamp()

  onFrozenChanged: if (root.frozen) root.stop()

  Component.onCompleted: root.position = root.clamp(root.restPosition)
}
