import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  property bool opened: false

  readonly property bool surfaceLive: root.opened || root.leaving

  property int selectedWorkspaceId: -1
  property int selectedApp: 0

  property var rowSelections: ({})

  property string backgroundImagePath: ""

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try { url = decodeURIComponent(url) } catch (e) {}
    return url.replace(/\/+$/, "")
  }

  function open(payloadJson) {

    var focused = Hyprland.focusedWorkspace

    var startWorkspace = -1
    var keyboardSwitchMode = false
    if (payloadJson) {
      try {
        var payload = JSON.parse(payloadJson)
        if (payload && payload.workspaceId) startWorkspace = Number(payload.workspaceId)
        keyboardSwitchMode = !!(payload && payload.keyboardSwitchMode)
      } catch (e) {}
    }
    root.keyboardSwitchMode = keyboardSwitchMode
    root.selectedWorkspaceId = startWorkspace > 0
      ? startWorkspace
      : (root.hasWindows(focused) ? focused.id : root.emptyWorkspaceId)

    root.selectedApp = root.defaultAppIndexForWorkspace(root.selectedWorkspaceId)
    root.refreshGeometry()
    bgProbe.restart()

    exitFade.stop()
    switchHold.stop()
    handOffTimer.stop()
    root.thawGeometry()
    root.clearZoom()

    root.zoomProgress = 1
    root.zoomReady = false
    root.zoomOpenAt = Date.now()

    root.probeGeometry()
    root.grabsKeyboard = true
    root.exitOpacity = 1

    root.opened = true
    root.leaving = false
    root.gestureAxis = ""
    root.captureContextReady = false
    captureWarmup.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    root.rowSelections = ({})
    vScroll.reset()
    root.viewReset()

    root.captureTarget(root.selectedRow, root.selectedApp)

    if (root.switcherDebug) root.dbg("open focusedWs=" + (focused ? focused.id : "?")
      + " selectedWsId=" + root.selectedWorkspaceId
      + " selectedRow=" + root.selectedRow
      + " selectedApp=" + root.selectedApp
      + " rows=" + JSON.stringify(root.workspaceRows.map(function(r) { return r.id }))
      + " frozenRows=" + (root.frozenRows ? "YES" : "no"))
  }

  function close() {
    if (!root.opened || root.leaving) return

    if (!root.activateSelection()) root.dismiss()
  }

  function dismiss() {
    if (!root.opened || root.leaving) return
    root.freezeGeometry()

    root.leaving = true
    root.opened = false
    root.grabsKeyboard = false
    exitFade.restart()
  }

  function finish() {
    exitFade.stop()
    switchHold.stop()
    handOffTimer.stop()
    root.opened = false
    root.leaving = false
    root.captureContextReady = false
    captureWarmup.stop()
    root.grabsKeyboard = true
    root.exitOpacity = 1
    root.gestureAxis = ""

    root.gestureMode = ""
    root.gestureAimed = false
    root.gestureTravelOrigin = 0
    root.gestureRestoreArg = ""
    root.switchCommitPending = false
    root.keyboardSwitchMode = false

    root.hyprSend("dispatch switcher_overview_closed()")
    geometryRefresh.stop()
    root.clearZoom()
    root.thawGeometry()
    root.rowSelections = ({})
    vScroll.reset()
    root.viewReset()
  }

  function toggle() { if (root.opened) root.close(); else root.open() }
  function ping() { return "ok" }

  signal viewReset()
  signal viewFrozen()

  property bool leaving: false

  property bool grabsKeyboard: true

  property real exitOpacity: 1

  NumberAnimation {
    id: exitFade
    target: root
    property: "exitOpacity"
    from: 1
    to: 0
    duration: 110
    easing.type: Easing.InQuad
    onFinished: root.finish()
  }

  function refreshGeometry() {
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
  }

  readonly property var geometryEvents: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen", "pin", "moveworkspace", "monitoradded",
    "monitorremoved", "configreloaded"
  ]

  Connections {
    target: Hyprland
    enabled: root.opened
    function onRawEvent(event) {
      if (root.geometryEvents.indexOf(event.name) !== -1) geometryRefresh.restart()
    }
  }

  Timer {
    id: geometryRefresh
    interval: 50
    onTriggered: root.refreshGeometry()
  }

  Process {
    id: bgPathProc
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: root.backgroundImagePath = String(text || "").trim()
    }
  }

  Timer {
    id: bgProbe
    interval: 320
    onTriggered: bgPathProc.running = true
  }

  Component.onCompleted: bgPathProc.running = true

  readonly property real rowHeight: Math.max(Style.space(120), panel.height * 0.5)

  readonly property real rowSpacing: Math.round(root.rowHeight * 0.104)

  readonly property real nearMargin: root.rowHeight

  readonly property real renderMargin: root.rowStride * 1.6

  readonly property real rowStride: root.rowHeight + root.rowSpacing

  readonly property real captureBudget: 6

  readonly property int captureCooldownMs: 500

  readonly property int capturePrefetchMs: 3000

  property bool captureContextReady: false

  Timer {
    id: captureWarmup
    interval: 350
    onTriggered: root.captureContextReady = true
  }

  Timer {
    id: captureTick
    interval: 100
    repeat: true
    running: root.opened && !root.leaving
    onTriggered: root.captureTock()
  }

  property real captureTokens: 0

  function captureQuiet() {
    if (!root.opened || root.leaving || root.diving) return false
    if (!root.captureContextReady) return false
    if (zoomRamp.running) return false
    if (root.gestureMode !== "") return false
    if (vScroll.moving) return false

    var rows = root.workspaceRows
    for (var i = 0; i < rows.length; i++) {
      var row = rowRepeater.itemAt(i)
      if (row && row.renderNear && row.hScroll && row.hScroll.moving) return false
    }
    return true
  }

  function captureNext() {
    var now = Date.now()
    var rows = root.workspaceRows
    var blank = null
    var stale = null, staleAge = -1
    var far = null, farAge = -1

    for (var i = 0; i < rows.length; i++) {
      var row = rowRepeater.itemAt(i)
      if (!row) continue
      var near = row.renderNear && row.nearViewport
      var apps = row.sortedToplevels
      var n = apps ? apps.length : 0
      for (var j = 0; j < n; j++) {
        var t = row.thumbItemAt(j)
        if (!t || !t.requestCapture) continue
        var age = now - t.lastCaptureMs
        if (near && t.nearRow) {

          if (!t.hasPicture) { if (!blank) blank = t; continue }
          if (age >= root.captureCooldownMs && age > staleAge) { staleAge = age; stale = t }
        } else if (age >= root.capturePrefetchMs && age > farAge) {
          farAge = age; far = t
        }
      }
    }
    return blank || stale || far
  }

  function captureTock() {
    if (!root.captureQuiet()) return
    root.captureTokens = Math.min(1, root.captureTokens + root.captureBudget * (captureTick.interval / 1000))
    if (root.captureTokens < 1) return
    var t = root.captureNext()
    if (!t) return
    root.captureTokens -= 1
    t.requestCapture()
  }

  function captureTarget(rowIndex, appIndex) {
    var row = rowRepeater.itemAt(rowIndex)
    if (!row) return
    var t = row.thumbItemAt(appIndex)
    if (t && t.requestCapture) t.requestCapture()
  }

  readonly property var windowedRows: {
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (ws && ws.toplevels && ws.toplevels.values.length > 0) rows.push(ws)
    }
    rows.sort(function(a, b) { return a.id - b.id })
    return rows
  }

  readonly property int emptyWorkspaceId: {
    var used = {}
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) used[rows[i].id] = true
    var id = 1
    while (used[id]) id++
    return id
  }

  readonly property var emptyRowMonitor: {
    var rows = root.windowedRows
    var last = rows.length > 0 ? rows[rows.length - 1] : null
    return (last && last.monitor) ? last.monitor : Hyprland.focusedMonitor
  }

  readonly property var workspaceRows: {

    if (root.frozenRows) return root.frozenRows
    var rows = root.windowedRows.slice()
    var focused = Hyprland.focusedWorkspace
    if (rows.length === 0 || (focused && !root.hasWindows(focused))) {
      rows.push({
        id: root.emptyWorkspaceId,
        switcherEmpty: true,
        monitor: root.emptyRowMonitor,
        toplevels: { values: [] }
      })
    }
    return rows
  }

  function isEmptyRowModel(row) { return !!(row && row.switcherEmpty) }

  function hasWindows(ws) {
    if (!ws) return false
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) if (rows[i].id === ws.id) return true
    return false
  }

  readonly property int selectedRow: {
    for (var i = 0; i < root.workspaceRows.length; i++) {
      if (root.workspaceRows[i].id === root.selectedWorkspaceId) return i
    }
    return 0
  }

  readonly property var selectedToplevels: {
    var ws = root.workspaceRows[root.selectedRow]
    return ws ? root.sortToplevelsBySpatialOrder(root.toplevelsFor(ws)) : []
  }

  function defaultAppIndexForWorkspace(id) {
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id !== id) continue
      return root.focusedIndexFor(root.sortToplevelsBySpatialOrder(rows[i].toplevels.values))
    }
    return 0
  }

  function noteSelectedApp(index) {
    root.selectedApp = index

    var next = {}
    for (var k in root.rowSelections) next[k] = root.rowSelections[k]
    next[root.selectedWorkspaceId] = index
    root.rowSelections = next
  }

  function rowSelectionFor(id) {
    var v = root.rowSelections[id]
    return v === undefined ? -1 : v
  }

  onSelectedWorkspaceIdChanged: {
    var remembered = root.rowSelectionFor(root.selectedWorkspaceId)
    root.selectedApp = remembered >= 0
      ? remembered
      : root.defaultAppIndexForWorkspace(root.selectedWorkspaceId)
  }

  function moveRow(delta) {
    var rows = root.workspaceRows
    if (rows.length === 0) return
    var next = Math.max(0, Math.min(rows.length - 1, root.selectedRow + delta))
    if (next === root.selectedRow) return
    vScroll.interactive = true
    root.selectedWorkspaceId = rows[next].id
  }

  function moveApp(delta) {
    var apps = root.selectedToplevels
    if (apps.length === 0) return
    root.noteSelectedApp(Math.max(0, Math.min(apps.length - 1, root.selectedApp + delta)))
  }

  function activateSelection() {
    var row = root.workspaceRows[root.selectedRow]
    if (root.isEmptyRowModel(row)) {
      root.activateWorkspace(row.id)
      return true
    }
    var apps = root.selectedToplevels
    if (apps.length === 0) return false
    var i = Math.max(0, Math.min(apps.length - 1, root.selectedApp))
    root.activateToplevel(apps[i], root.selectedRow, i)
    return true
  }

  property bool switchCommitPending: false
  property bool keyboardSwitchMode: false

  function switchWorkspace(dir) {
    dir = Number(dir)
    root.dbg("switchWorkspace dir=" + dir + " opened=" + root.opened + " leaving=" + root.leaving)
    if (!(dir === 1 || dir === -1)) return
    if (root.leaving || root.pendingActivation) return
    if (root.opened) {
      root.walk(dir)
      return
    }
    var target = root.switchTargetFor(dir)
    if (target <= 0) return

    root.switchCommitPending = false
    root.open(JSON.stringify({ workspaceId: target, keyboardSwitchMode: true }))
  }

  function walk(dir) {
    var rows = root.workspaceRows
    if (rows.length < 2) return
    var n = root.selectedRow
    for (var hop = 1; hop <= rows.length; hop++) {
      var i = ((n + hop * dir) % rows.length + rows.length) % rows.length
      if (root.isEmptyRowModel(rows[i])) continue
      vScroll.interactive = true
      root.selectedWorkspaceId = rows[i].id
      return
    }
  }

  function switchCommit() {
    if (root.leaving || root.pendingActivation) return
    if (!root.opened || zoomRamp.running) {
      root.switchCommitPending = true
      return
    }
    root.switchDive()
  }

  function openRampDone() {
    if (!root.switchCommitPending) return
    root.switchCommitPending = false
    if (root.opened && !root.leaving && !root.pendingActivation) root.switchDive()
  }

  function switchState() {
    return (root.opened ? "opened" : "closed")
      + (root.leaving ? "+leaving" : "")
      + (root.switchCommitPending ? "+pending" : "")
      + (zoomRamp.running ? "+ramping" : "")
      + " selWs=" + root.selectedWorkspaceId
      + " selRow=" + root.selectedRow
  }

  function altTabIconSource(cls) {
    if (!altTab) return "no-altTab"
    var got = String(cls || "")
    var ovs = altTab.iconOverrides
    var first = (ovs && ovs.length > 0) ? String(ovs[0].source) : "(none)"
    var resolved = ""
    var app = ""
    if (got === "") got = altTab.selectedClass
    if (got !== "") {
      resolved = altTab.iconSourceFor(got)
      app = altTab.appNameFor(got)
    }
    return JSON.stringify({ arg: String(cls || ""), got: got,
      overrides: ovs ? ovs.length : -1, first: first, resolved: resolved, app: app })
  }

  property var workspaceHistory: []

  function noteWorkspaceFocus(wsId) {
    if (!(wsId > 0)) return
    if (root.workspaceHistory.length > 0 && root.workspaceHistory[0] === wsId) return
    var next = [wsId]
    for (var i = 0; i < root.workspaceHistory.length; i++) {
      if (root.workspaceHistory[i] !== wsId) next.push(root.workspaceHistory[i])
    }
    root.workspaceHistory = next
  }

  function switchTargetFor(dir) {
    var focused = Hyprland.focusedWorkspace
    var current = focused ? Number(focused.id) : -1

    if (current > 0 && root.hasWindows(focused)) root.noteWorkspaceFocus(current)

    var rows = root.windowedRows
    var windowed = {}
    for (var k = 0; k < rows.length; k++) windowed[rows[k].id] = true
    var hist = root.workspaceHistory
    var target = -1
    if (dir === 1) {
      for (var i = 0; i < hist.length; i++) {
        if (hist[i] === current || !windowed[hist[i]]) continue
        target = hist[i]
        break
      }
    } else {
      for (var m = hist.length - 1; m >= 0; m--) {
        if (hist[m] === current || !windowed[hist[m]]) continue
        target = hist[m]
        break
      }
    }
    if (target > 0) return target

    if (rows.length === 0) return -1
    var from = 0
    for (var j = 0; j < rows.length; j++) {
      if (rows[j].id === current) { from = j; break }
    }
    var next = ((from + dir) % rows.length + rows.length) % rows.length
    if (next === from && rows.length < 2) return -1
    return rows[next].id
  }

  function switchDive() {
    root.switchCommitPending = false
    if (!root.opened || root.leaving) return
    root.activateSelection()
  }

  property real zoomProgress: 0
  property real zoomScale: 1
  property real zoomThumbX: 0
  property real zoomThumbY: 0
  property real zoomRealX: 0
  property real zoomRealY: 0
  property bool zoomReady: true
  property var pendingActivation: null

  property real zoomOpenAt: 0
  readonly property int zoomWaitMs: 220

  readonly property int geometryWaitMs: 80

  property bool geometryLanded: true

  function probeGeometry() {
    root.geometryLanded = false
    root.hyprSend("j/activewindow", "open")
  }

  function geometryIsCurrent(win) {
    var top = Hyprland.activeToplevel

    if (!win || !win.address || !top) return true
    var ipc = top.lastIpcObject
    if (!ipc || !ipc.address || String(ipc.address) !== String(win.address)) return false
    var real = root.rectFromIpc(win)
    var cached = root.liveRectFor(top)
    if (!real || !cached) return true
    return Math.abs(cached.x - real.x) < 0.5 && Math.abs(cached.y - real.y) < 0.5
      && Math.abs(cached.w - real.w) < 0.5 && Math.abs(cached.h - real.h) < 0.5
  }

  function openProbeLanded(reply) {
    if (!root.opened || root.geometryLanded) return
    var current = root.geometryIsCurrent(root.parseWindow(reply))

    if (current || Date.now() - root.zoomOpenAt >= root.geometryWaitMs) {
      root.geometryLanded = true
      root.dbg("geometry " + (current ? "landed" : "GAVE UP") + " after "
        + Math.round(Date.now() - root.zoomOpenAt) + "ms")
      return
    }
    geometryProbeRetry.restart()
  }

  Timer {
    id: geometryProbeRetry
    interval: 8
    onTriggered: if (root.opened && !root.geometryLanded) root.probeGeometry()
  }

  readonly property var panelReserved: {
    var mon = panel.screen ? Hyprland.monitorFor(panel.screen) : null
    var ipc = mon ? mon.lastIpcObject : undefined
    var r = ipc ? ipc.reserved : undefined
    return (r && r.length === 4) ? r : [0, 0, 0, 0]
  }
  readonly property real surfaceLeft: Number(root.panelReserved[0]) || 0
  readonly property real surfaceTop: Number(root.panelReserved[1]) || 0

  property int diveRow: -1
  property int diveApp: -1

  property real diveShiftPx: 0

  property bool awaitingLanding: false

  readonly property int diveMs: 300

  readonly property int openMs: 260

  property bool switcherDebug: false
  property real dbgClickMs: 0
  function dbg(msg) { if (root.switcherDebug) console.warn("SWITCHER " + msg) }
  function dbgCounts() {
    var rows = root.workspaceRows.length
    var wins = 0
    for (var i = 0; i < rows; i++) {
      var r = root.workspaceRows[i]
      if (r && r.toplevels) wins += r.toplevels.values.length
    }
    return "rows=" + rows + " windows=" + wins
  }

  readonly property real zoomFactor: 1 + root.zoomProgress * (root.zoomScale - 1)

  readonly property real diveShiftPhase: root.zoomFactor > 0
    ? root.zoomProgress * root.zoomScale / root.zoomFactor
    : root.zoomProgress

  readonly property real diveShiftNow: root.diveShiftPx * root.diveShiftPhase

  readonly property real backdropRise: 0.1

  readonly property bool diving: root.pendingActivation !== null

  readonly property real backdropOpacity: !root.zoomReady
    ? 0
    : root.diving
      ? 1 - root.zoomProgress * root.zoomProgress
      : Math.min(1, (1 - root.zoomProgress) / root.backdropRise)

  function zoomOffset(thumbPos, realPos) {
    return thumbPos + (realPos - thumbPos) * root.zoomProgress
      - root.zoomFactor * thumbPos
  }

  function captureZoom(rowIndex, appIndex) {
    var row = rowRepeater.itemAt(rowIndex)
    if (!row) { root.dbg("captureZoom: no row delegate at " + rowIndex); return false }
    var item = row.thumbItemAt(appIndex)
    if (!item || item.width <= 0 || item.height <= 0) {
      root.dbg("captureZoom: no thumb at " + appIndex
        + " (item=" + (item ? item.width + "x" + item.height : "null") + ")")
      return false
    }
    var r = root.rectFor(item.modelData)
    if (!r) { root.dbg("captureZoom: no rect for thumb " + appIndex); return false }
    var p = item.mapToItem(zoomLayer, 0, 0)
    root.zoomThumbX = p.x
    root.zoomThumbY = p.y

    root.zoomRealX = r.x - row.monX - root.surfaceLeft
    root.zoomRealY = r.y - row.monY - root.surfaceTop
    root.zoomScale = r.w / item.width
    return true
  }

  function zoomTargetPainted() {
    var row = rowRepeater.itemAt(root.selectedRow)
    if (!row) return false
    var item = row.thumbItemAt(root.selectedApp)
    return !!item && item.hasPicture
  }

  function clearZoom() {
    zoomRamp.halt()
    diveDeadline.stop()
    aimRetry.stop()
    geometryProbeRetry.stop()
    root.geometryLanded = true
    root.aimRetries = 0
    root.pendingDispatch = ""
    restoreFallback.stop()
    root.pendingActivation = null
    root.diveRow = -1
    root.diveApp = -1
    root.diveShiftPx = 0
    root.awaitingLanding = false
    root.zoomProgress = 0
    root.zoomScale = 1
    root.zoomThumbX = 0
    root.zoomThumbY = 0
    root.zoomRealX = 0
    root.zoomRealY = 0
    root.zoomReady = true
  }

  function activateToplevel(toplevel, rowIndex, appIndex) {
    if (!toplevel) return
    if (root.pendingActivation || root.leaving) return
    root.dbgClickMs = Date.now()
    var arg = root.focusArg(toplevel)
    var tArg = Date.now()

    var captured = root.captureZoom(rowIndex, appIndex)
    var tCapture = Date.now()
    if (!arg || !captured) {
      root.focusToplevel(toplevel)
      return
    }

    root.captureTarget(rowIndex, appIndex)
    root.freezeGeometry()
    var tFreeze = Date.now()
    root.dbg("phases focusArg=" + (tArg - root.dbgClickMs) + "ms capture="
      + (tCapture - tArg) + "ms freeze=" + (tFreeze - tCapture) + "ms")
    root.dbg("click " + root.dbgCounts()
      + " thumb=(" + Math.round(root.zoomThumbX) + "," + Math.round(root.zoomThumbY) + ")"
      + " capturedReal=(" + Math.round(root.zoomRealX) + "," + Math.round(root.zoomRealY) + ")"
      + " scale=" + root.zoomScale.toFixed(3))
    root.pendingActivation = toplevel
    root.aimRetries = 0
    root.diveRow = rowIndex
    root.diveApp = appIndex
    root.awaitingLanding = true
    root.beginHandOff(arg)
    diveDeadline.restart()
  }

  property string hyprRequest: ""
  property string hyprReply: ""
  property bool hyprPending: false

  property string hyprReplyTo: "dive"

  Socket {
    id: hyprIpc
    path: Hyprland.requestSocketPath

    parser: SplitParser {
      splitMarker: ""
      onRead: function(data) {
        root.dbg("socket chunk " + data.length + " bytes at "
          + (Date.now() - root.dbgClickMs) + "ms")
        root.hyprReply += data
      }
    }
    onConnectionStateChanged: {
      if (hyprIpc.connected) {
        root.hyprReply = ""
        hyprIpc.write(root.hyprRequest)
        hyprIpc.flush()
        root.dbg("socket connected+written at " + (Date.now() - root.dbgClickMs) + "ms")
        return
      }
      if (!root.hyprPending) return
      root.hyprPending = false
      root.dbg("socket reply at " + (Date.now() - root.dbgClickMs) + "ms, "
        + root.hyprReply.length + " bytes for " + root.hyprReplyTo)
      if (root.hyprReplyTo === "open") root.openProbeLanded(root.hyprReply)
      else root.beginDive(root.hyprReply)
    }
    onError: function(err) { root.dbg("socket error " + err) }
  }

  function hyprSend(request, replyTo) {
    root.hyprReplyTo = replyTo || "dive"
    if (root.hyprReplyTo === "dive") {

      geometryProbeRetry.stop()
      root.geometryLanded = true
    }
    root.dbg("hyprSend at " + (Date.now() - root.dbgClickMs) + "ms REQ="
      + JSON.stringify(request))
    root.hyprRequest = request
    root.hyprPending = true
    if (hyprIpc.connected) hyprIpc.connected = false
    hyprIpc.connected = true
  }

  function dispatchAndAim(pre, arg) {
    root.hyprSend("[[BATCH]]" + root.dispatchChain(pre.concat([arg])) + ";j/activewindow")
  }

  function dispatchChain(args) {
    return args.map(function(a) { return "dispatch " + a }).join(";")
  }

  function aimIsStale(win) {
    if (!win || !win.address) return false
    var ipc = root.pendingActivation ? root.pendingActivation.lastIpcObject : undefined
    if (!ipc || !ipc.address) return false
    return String(win.address) !== String(ipc.address)
  }

  property int aimRetries: 0

  Timer {
    id: aimRetry
    interval: 8
    onTriggered: root.hyprSend("j/activewindow")
  }

  function beginDive(reply) {
    if (!root.awaitingLanding) return
    var win = root.parseWindow(reply)
    root.dbg("reply after " + Math.round(Date.now() - root.dbgClickMs) + "ms"
      + " retries=" + root.aimRetries
      + " deadline=" + (diveDeadline.running ? "no" : "YES-FIRED")
      + " parsed=" + (win ? "yes" : "NO")
      + " raw=" + JSON.stringify((reply || "").slice(0, 60)))

    if (root.aimIsStale(win) && diveDeadline.running) {
      root.aimRetries++
      aimRetry.restart()
      return
    }
    root.awaitingLanding = false
    diveDeadline.stop()
    aimRetry.stop()
    root.aimZoom(win)
    root.dbg("aimed shift=" + root.diveShiftPx.toFixed(1)
      + " real=(" + Math.round(root.zoomRealX) + "," + Math.round(root.zoomRealY) + ")"
      + " scale=" + root.zoomScale.toFixed(3))

    if (root.gestureDiving) { root.gestureDiveAimed(); return }
    zoomRamp.run(0, 1, root.diveMs, root.finishActivation)
  }

  function parseWindow(reply) {
    var text = reply || ""
    var start = text.indexOf("{")
    if (start < 0) return null
    try { return JSON.parse(text.slice(start)) } catch (e) { return null }
  }

  function aimZoom(win) {
    if (!win || !win.address) return
    var ipc = root.pendingActivation ? root.pendingActivation.lastIpcObject : undefined

    if (!ipc || String(win.address) !== String(ipc.address)) return
    var row = rowRepeater.itemAt(root.diveRow)
    if (!row) return
    var item = row.thumbItemAt(root.diveApp)
    if (!item || item.width <= 0) return
    var r = root.rectFromIpc(win)
    if (!r) return

    var pre = root.rectFor(root.pendingActivation)
    root.diveShiftPx = (pre ? (pre.x - r.x) * row.geomScale : 0) - row.stripOffset

    root.zoomThumbX -= root.diveShiftPx

    root.zoomRealX = r.x - row.monX - root.surfaceLeft
    root.zoomRealY = r.y - row.monY - root.surfaceTop
    root.zoomScale = r.w / item.width
  }

  function finishActivation() { handOffTimer.restart() }

  Timer {
    id: diveDeadline
    interval: 300
    onTriggered: {
      root.dbg("DEADLINE fired at " + (Date.now() - root.dbgClickMs) + "ms")
      root.beginDive("")
    }
  }

  FrameAnimation {
    id: zoomOpener
    running: root.opened && !root.zoomReady
    onTriggered: {

      if (root.switcherDebug) root.dbg("zoomOpener frame: selectedRow=" + root.selectedRow
        + " selectedApp=" + root.selectedApp
        + " rows=" + JSON.stringify(root.workspaceRows.map(function(r) { return r.id }))
        + " gestureActive=" + root.gestureActive)
      if (root.captureZoom(root.selectedRow, root.selectedApp)) {

        if (!(root.geometryLanded && root.zoomTargetPainted())
            && Date.now() - root.zoomOpenAt < root.zoomWaitMs) return
        root.dbg("zoomOpener captured thumb=("
          + Math.round(root.zoomThumbX) + "," + Math.round(root.zoomThumbY)
          + ") real=(" + Math.round(root.zoomRealX) + "," + Math.round(root.zoomRealY)
          + ") scale=" + root.zoomScale.toFixed(3))
        root.zoomReady = true

        if (root.gestureActive) return

        zoomRamp.run(1, 0, root.openMs, root.openRampDone,
          zoomRamp.maxStep)
      } else {
        root.dbg("zoomOpener CAPTURE FAILED -- no zoom this open")

        root.gestureMode = ""
        root.clearZoom()

        Qt.callLater(root.openRampDone)
      }
    }
  }

  FrameAnimation {
    id: zoomRamp
    running: false
    property real fromValue: 0
    property real toValue: 0
    property real durationMs: 260
    property real t: 0
    property var whenDone: null

    readonly property real maxStep: 1 / 6

    property var dbgTimes: []
    property int dbgFrames: 0
    property real dbgMaxFrame: 0
    property real dbgStart: 0

    function run(a, b, ms, done, head) {
      zoomRamp.dbgFrames = 0
      zoomRamp.dbgTimes = []
      zoomRamp.dbgMaxFrame = 0
      zoomRamp.dbgStart = Date.now()
      zoomRamp.fromValue = a
      zoomRamp.toValue = b
      zoomRamp.durationMs = Math.max(1, ms)
      zoomRamp.whenDone = done || null
      zoomRamp.t = head || 0
      root.zoomProgress = a + (b - a) * zoomRamp.eased(zoomRamp.t)
      zoomRamp.restart()
    }

    function halt() {
      zoomRamp.whenDone = null
      zoomRamp.stop()
    }

    function eased(x) {
      if (zoomRamp.toValue < zoomRamp.fromValue) return 1 - Math.pow(1 - x, 3)
      return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2
    }

    onTriggered: {
      if (root.switcherDebug) {
        zoomRamp.dbgFrames++
        if (zoomRamp.frameTime * 1000 > zoomRamp.dbgMaxFrame)
          zoomRamp.dbgMaxFrame = zoomRamp.frameTime * 1000
        zoomRamp.dbgTimes.push(Math.round(zoomRamp.frameTime * 1000))
      }

      var step = Math.min(zoomRamp.frameTime * 1000 / zoomRamp.durationMs,
                          zoomRamp.maxStep)
      zoomRamp.t = Math.min(1, zoomRamp.t + step)
      root.zoomProgress = zoomRamp.fromValue
        + (zoomRamp.toValue - zoomRamp.fromValue) * zoomRamp.eased(zoomRamp.t)
      if (zoomRamp.t < 1) return
      root.dbg((zoomRamp.toValue > zoomRamp.fromValue ? "dive" : "open")
        + " ramp done: " + zoomRamp.dbgFrames + " frames over "
        + Math.round(Date.now() - zoomRamp.dbgStart) + "ms"
        + " (asked " + Math.round(zoomRamp.durationMs) + "ms)"
        + " worst frame " + zoomRamp.dbgMaxFrame.toFixed(1) + "ms"
        + " avg " + ((Date.now() - zoomRamp.dbgStart) / Math.max(1, zoomRamp.dbgFrames)).toFixed(1) + "ms"
        + " frames=[" + zoomRamp.dbgTimes.join(",") + "]")
      zoomRamp.stop()
      var done = zoomRamp.whenDone
      zoomRamp.whenDone = null
      if (done) done()
    }
  }

  property string gestureMode: ""
  readonly property bool gestureActive: root.gestureMode === "open"
  readonly property bool gestureDiving: root.gestureMode === "dive"

  readonly property real gestureDistance: Math.max(Style.space(180), panel.height * 0.3)

  readonly property real gestureCommitRatio: 0.32
  readonly property real gestureFlickSpeed: 0.4

  readonly property int gestureIdleMs: 50

  property bool gestureAimed: false
  property real gestureTravelOrigin: 0

  property string gestureRestoreArg: ""

  property real gestureVelocity: 0
  property real gestureLastTravel: 0
  property real gestureLastTime: 0

  function gestureBegin() {
    if (root.gestureMode !== "") return

    if (root.leaving || root.pendingActivation) return

    if (root.opened) return

    root.gestureMode = "open"
    root.gestureVelocity = 0
    root.gestureLastTravel = 0
    root.gestureLastTime = 0
    root.open()

    root.grabsKeyboard = false
  }

  function gestureAt(travel, timeMs) {
    if (!root.gestureActive) return
    if (root.gestureLastTime > 0 && timeMs > root.gestureLastTime) {

      root.gestureVelocity = 0.5 * root.gestureVelocity
        + 0.5 * (travel - root.gestureLastTravel) / (timeMs - root.gestureLastTime)
    }
    root.gestureLastTravel = travel
    root.gestureLastTime = timeMs

    root.zoomProgress = 1 - Math.max(0, Math.min(1, travel / root.gestureDistance))
  }

  function gestureFinish(cancelled, timeMs) {

    var mode = root.gestureMode
    if (mode !== "open") return
    root.gestureMode = ""

    var resting = root.gestureLastTime > 0 && timeMs > 0
      && (timeMs - root.gestureLastTime) > root.gestureIdleMs
    var speed = resting ? 0 : root.gestureVelocity

    var shown = 1 - root.zoomProgress
    var commit = !cancelled
      && (shown >= root.gestureCommitRatio || speed >= root.gestureFlickSpeed)

    if (commit) {
      root.grabsKeyboard = true
      zoomRamp.run(root.zoomProgress, 0,
        Math.round(root.openMs * Math.max(0.15, root.zoomProgress)), null)
    } else {

      zoomRamp.run(root.zoomProgress, 1,
        Math.round(root.openMs * Math.max(0.15, 1 - root.zoomProgress)),
        root.finish)
    }
  }

  function gestureDiveBegin() {
    if (root.gestureMode !== "") return
    if (!root.opened || root.leaving || root.pendingActivation) return

    zoomRamp.halt()
    root.zoomProgress = 0

    var row = root.workspaceRows[root.selectedRow]
    var apps = root.selectedToplevels
    var index = Math.max(0, Math.min(apps.length - 1, root.selectedApp))
    var toplevel = apps.length > 0 ? apps[index] : null
    var arg = root.isEmptyRowModel(row)
      ? (row ? "hl.dsp.focus({ workspace = '" + row.id + "' })" : "")
      : root.focusArg(toplevel)

    root.dbg("diveBegin row=" + root.selectedRow
      + " wsId=" + (row ? row.id : "?")
      + " empty=" + root.isEmptyRowModel(row)
      + " apps=" + apps.length + " index=" + index
      + " arg=" + JSON.stringify(arg))

    if (!arg) { root.dbg("diveBegin ABORT: no focus arg"); return }

    if (root.isEmptyRowModel(row) || !toplevel) {
      root.dbg("diveBegin LEAVE: empty row or no toplevel")
      root.gestureMode = "leave"
      return
    }

    if (!root.captureZoom(root.selectedRow, index)) {
      root.dbg("diveBegin LEAVE: captureZoom failed")

      root.gestureMode = "leave"
      return
    }
    root.freezeGeometry()

    root.dbg("diveBegin captured thumb=(" + Math.round(root.zoomThumbX)
      + "," + Math.round(root.zoomThumbY) + ") real=(" + Math.round(root.zoomRealX)
      + "," + Math.round(root.zoomRealY) + ") scale=" + root.zoomScale.toFixed(3)
      + " -- expected thumbY near 247 for the centred row")
    root.gestureMode = "dive"
    root.gestureAimed = false
    root.gestureTravelOrigin = 0
    root.gestureVelocity = 0
    root.gestureLastTravel = 0
    root.gestureLastTime = 0
    root.gestureRestoreArg = root.focusArg(Hyprland.activeToplevel)
    root.dbgClickMs = Date.now()

    root.pendingActivation = toplevel
    root.aimRetries = 0
    root.diveRow = root.selectedRow
    root.diveApp = index
    root.awaitingLanding = true

    root.grabsKeyboard = false
    root.pendingDispatch = arg
    restoreFallback.restart()
    diveDeadline.restart()
  }

  function gestureDiveAt(travel, timeMs) {
    if (root.gestureMode !== "dive") return
    if (root.gestureLastTime > 0 && timeMs > root.gestureLastTime) {
      root.gestureVelocity = 0.5 * root.gestureVelocity
        + 0.5 * (travel - root.gestureLastTravel) / (timeMs - root.gestureLastTime)
    }
    root.gestureLastTravel = travel
    root.gestureLastTime = timeMs

    if (!root.gestureAimed) return
    root.zoomProgress = Math.max(0, Math.min(1,
      (travel - root.gestureTravelOrigin) / root.gestureDistance))
  }

  function gestureDiveAimed() {
    root.gestureAimed = true
    root.gestureTravelOrigin = root.gestureLastTravel
    root.dbg("dive gesture aimed after "
      + Math.round(Date.now() - root.dbgClickMs) + "ms, origin "
      + Math.round(root.gestureTravelOrigin) + "px")
  }

  function gestureDiveFinish(cancelled, timeMs) {
    root.dbg("diveFinish cancelled=" + cancelled + " mode=" + JSON.stringify(root.gestureMode)
      + " aimed=" + root.gestureAimed + " progress=" + root.zoomProgress.toFixed(3)
      + " vel=" + root.gestureVelocity.toFixed(3))

    var mode = root.gestureMode
    if (mode !== "dive" && mode !== "leave") return
    root.gestureMode = ""

    if (mode === "leave") {

      if (!cancelled) root.activateSelection()
      return
    }

    var resting = root.gestureLastTime > 0 && timeMs > 0
      && (timeMs - root.gestureLastTime) > root.gestureIdleMs
    var speed = resting ? 0 : root.gestureVelocity

    var stroke = root.gestureDistance > 0
      ? root.gestureLastTravel / root.gestureDistance
      : 0

    var commit = !cancelled
      && (root.zoomProgress >= root.gestureCommitRatio
        || stroke >= root.gestureCommitRatio
        || speed >= root.gestureFlickSpeed)

    if (!root.gestureAimed) {

      if (commit) {

        root.leaving = true
        root.opened = false
        return
      }
      root.gestureDiveRestore()
      return
    }

    if (commit) {
      root.leaving = true
      root.opened = false
      zoomRamp.run(root.zoomProgress, 1,
        Math.round(root.diveMs * Math.max(0.15, 1 - root.zoomProgress)),
        root.finishActivation)
      return
    }

    zoomRamp.run(root.zoomProgress, 0,
      Math.round(root.diveMs * Math.max(0.15, root.zoomProgress)),
      root.gestureDiveRestore)
  }

  function gestureDiveRestore() {
    var back = root.gestureRestoreArg
    root.gestureRestoreArg = ""
    root.gestureAimed = false
    root.gestureTravelOrigin = 0

    root.awaitingLanding = false
    diveDeadline.stop()
    aimRetry.stop()
    root.pendingActivation = null
    root.diveRow = -1
    root.diveApp = -1
    root.diveShiftPx = 0
    root.zoomProgress = 0
    root.zoomScale = 1
    root.zoomThumbX = 0
    root.zoomThumbY = 0
    root.zoomRealX = 0
    root.zoomRealY = 0
    root.thawGeometry()

    if (root.pendingDispatch !== "") {

      root.pendingDispatch = ""
      restoreFallback.stop()
    } else if (back !== "") {
      root.hyprSend("dispatch " + back)
    }

    root.grabsKeyboard = true
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var data = String(event.data || "")
      if (data.indexOf("switcher:overview-") !== 0) return
      var parts = data.split(" ")
      root.dbg("RAW EVENT data=" + data + " opened=" + root.opened + " grab=" + root.grabsKeyboard + " t=" + Date.now())
      switch (parts[0]) {
      case "switcher:overview-begin":
        root.gestureBegin()
        break
      case "switcher:overview-at":
        root.gestureAt(Number(parts[1]), Number(parts[2]))
        break
      case "switcher:overview-end":
        root.gestureFinish(parts[1] === "1", Number(parts[2]))
        break
      case "switcher:overview-down-begin":
        root.gestureDiveBegin()
        break
      case "switcher:overview-down-at":
        root.gestureDiveAt(Number(parts[1]), Number(parts[2]))
        break
      case "switcher:overview-down-end":
        root.gestureDiveFinish(parts[1] === "1", Number(parts[2]))
        break
      case "switcher:overview-switch":

        root.switchWorkspace(parts[1] === "prev" ? -1 : 1)
        break
      case "switcher:overview-switch-commit":
        root.switchCommit()
        break
      }
    }
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      var toplevel = Hyprland.activeToplevel
      var ipc = toplevel ? toplevel.lastIpcObject : null
      if (ipc && ipc.workspace) root.noteWorkspaceFocus(Number(ipc.workspace.id))
    }
  }

  function isTouchpadWheel(wheel) {
    return wheel.phase !== Qt.NoScrollPhase
      || wheel.pixelDelta.x !== 0
      || wheel.pixelDelta.y !== 0
  }

  property string gestureAxis: ""

  function axisFor(dx, dy) {
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return ""
    return Math.abs(dx) > Math.abs(dy) ? "x" : "y"
  }

  function selectedRowScroll() {
    var row = rowRepeater.itemAt(root.selectedRow)
    return row ? row.hScroll : null
  }

  Timer {
    id: gestureIdle
    interval: 160
    onTriggered: root.gestureAxis = ""
  }

  function focusHistoryIdFor(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : undefined
    if (root.frozenFocus && ipc && ipc.address) {
      var frozen = root.frozenFocus[ipc.address]
      if (frozen !== undefined) return frozen
    }
    var raw = ipc ? ipc.focusHistoryID : undefined
    var n = Number(raw)
    return isFinite(n) ? n : Number.MAX_SAFE_INTEGER
  }

  function focusedIndexFor(values) {
    var bestIndex = 0
    var bestScore = Infinity
    for (var i = 0; i < values.length; i++) {
      var score = root.focusHistoryIdFor(values[i])
      if (score < bestScore) { bestScore = score; bestIndex = i }
    }
    return bestIndex
  }

  function spatialXFor(toplevel) {
    var r = root.rectFor(toplevel)
    return r ? r.x : Number.MAX_SAFE_INTEGER
  }

  function sortToplevelsBySpatialOrder(values) {
    var n = values ? values.length : 0
    if (n < 2) return values ? values.slice() : []
    var keyed = new Array(n)
    for (var i = 0; i < n; i++) keyed[i] = { t: values[i], x: root.spatialXFor(values[i]) }
    keyed.sort(function(a, b) { return a.x - b.x })
    var out = new Array(n)
    for (var j = 0; j < n; j++) out[j] = keyed[j].t
    return out
  }

  function rectFor(toplevel) {
    if (root.frozenRects) {
      var ipc = toplevel ? toplevel.lastIpcObject : undefined
      var frozen = (ipc && ipc.address) ? root.frozenRects[ipc.address] : undefined
      if (frozen) return frozen
    }
    return root.liveRectFor(toplevel)
  }

  function liveRectFor(toplevel) {
    return root.rectFromIpc(toplevel ? toplevel.lastIpcObject : undefined)
  }

  function rectFromIpc(ipc) {
    var at = ipc ? ipc.at : undefined
    var size = ipc ? ipc.size : undefined
    if (!at || !size || at.length < 2 || size.length < 2) return null
    var x = Number(at[0]), y = Number(at[1])
    var w = Number(size[0]), h = Number(size[1])
    if (!isFinite(x) || !isFinite(y) || !isFinite(w) || !isFinite(h)) return null
    if (w <= 0 || h <= 0) return null
    return { x: x, y: y, w: w, h: h }
  }

  property var frozenRects: null
  property var frozenRows: null
  property var frozenFocus: null

  property var frozenToplevels: null

  readonly property bool viewIsFrozen: root.frozenRects !== null

  function freezeToplevels(rows) {
    var out = ({})
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row) continue
      out[row.id] = (row.toplevels ? row.toplevels.values.slice() : [])
    }
    return out
  }

  function toplevelsFor(row) {
    if (!row) return []
    if (root.frozenToplevels) {
      var frozen = root.frozenToplevels[row.id]
      if (frozen) return frozen
    }
    return row.toplevels ? row.toplevels.values : []
  }

  function freezeGeometry() {
    if (root.frozenRects) return
    geometryRefresh.stop()
    var frozen = ({})
    var focus = ({})
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) {
      var vals = rows[i].toplevels.values
      for (var j = 0; j < vals.length; j++) {
        var ipc = vals[j] ? vals[j].lastIpcObject : undefined
        if (!ipc || !ipc.address) continue
        var r = root.liveRectFor(vals[j])
        if (r) frozen[ipc.address] = r
        var h = Number(ipc.focusHistoryID)
        if (isFinite(h)) focus[ipc.address] = h
      }
    }

    root.frozenFocus = focus
    root.frozenRects = frozen
    root.frozenToplevels = root.freezeToplevels(root.workspaceRows)
    root.frozenRows = root.workspaceRows.slice()

    vScroll.stop()
    root.viewFrozen()
  }

  function thawGeometry() {
    root.frozenRects = null
    root.frozenRows = null
    root.frozenToplevels = null
    root.frozenFocus = null
  }

  function beginHandOff(dispatchArg) {
    root.freezeGeometry()

    root.leaving = true
    root.opened = false

    root.grabsKeyboard = false
    root.pendingDispatch = dispatchArg
    restoreFallback.restart()
  }

  property string pendingDispatch: ""

  Connections {
    target: Hyprland
    enabled: root.pendingDispatch !== ""
    function onRawEvent(event) {
      if (event.name === "activewindow" || event.name === "activewindowv2"
        || event.name === "workspace" || event.name === "workspacev2") {
        root.dbg("restore via event " + event.name + " at "
          + (Date.now() - root.dbgClickMs) + "ms")
        root.runPendingDispatch()
      }
    }
  }

  Timer {
    id: restoreFallback
    interval: 90
    onTriggered: {
      root.dbg("restoreFallback fired at " + (Date.now() - root.dbgClickMs) + "ms")
      root.runPendingDispatch()
    }
  }

  function runPendingDispatch() {
    if (root.pendingDispatch === "") return
    var arg = root.pendingDispatch
    root.pendingDispatch = ""
    restoreFallback.stop()

    var pre = root.commitFocusArgs()
    root.rowSelections = ({})
    root.dbg("dispatch after restore at " + (Date.now() - root.dbgClickMs) + "ms"
      + (pre.length > 0 ? " with " + pre.length + " row commit(s)" : ""))

    if (root.awaitingLanding) {

      diveDeadline.restart()
      root.dispatchAndAim(pre, arg)
    } else {
      root.hyprSend(pre.length > 0
        ? "[[BATCH]]" + root.dispatchChain(pre.concat([arg]))
        : "dispatch " + arg)
      switchHold.restart()
    }
  }

  function handOff(dispatchArg) {
    if (root.leaving) return
    root.beginHandOff(dispatchArg)
  }

  Timer {
    id: switchHold
    interval: 190
    onTriggered: exitFade.restart()
  }

  Timer {
    id: handOffTimer
    interval: 100
    onTriggered: root.finish()
  }

  function focusArg(hyprlandToplevel) {
    var ipc = hyprlandToplevel && hyprlandToplevel.lastIpcObject
    var address = ipc ? ipc.address : undefined
    return address ? "hl.dsp.focus({ window = 'address:" + address + "' })" : ""
  }

  function commitFocusArgs() {
    var args = []
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) {
      var want = root.rowSelectionFor(rows[i].id)
      if (want < 0) continue
      var apps = root.sortToplevelsBySpatialOrder(rows[i].toplevels.values)
      if (apps.length === 0) continue

      if (rows[i].id === root.selectedWorkspaceId) continue
      if (root.pendingActivation && apps.indexOf(root.pendingActivation) >= 0) continue
      want = Math.max(0, Math.min(apps.length - 1, want))
      if (want === root.focusedIndexFor(apps)) continue
      var arg = root.focusArg(apps[want])
      if (arg) args.push(arg)
    }
    return args
  }

  function focusToplevel(hyprlandToplevel) {
    var arg = root.focusArg(hyprlandToplevel)

    if (!arg) { root.dismiss(); return }
    root.handOff(arg)
  }

  function activateWorkspace(id) {
    if (root.pendingActivation) return
    root.handOff("hl.dsp.focus({ workspace = '" + id + "' })")
  }

  PanelWindow {
    id: panel

    visible: true
    anchors { top: true; bottom: true; left: true; right: true }

    color: Util.alpha(Qt.lighter(Color.background, 1.75),
      root.surfaceLive ? root.backdropOpacity * root.exitOpacity : 0)
    WlrLayershell.namespace: "switcher-overview"

    WlrLayershell.layer: root.surfaceLive ? WlrLayer.Overlay : WlrLayer.Background

    WlrLayershell.keyboardFocus: (root.surfaceLive && root.grabsKeyboard)
      ? WlrKeyboardFocus.Exclusive
      : WlrKeyboardFocus.None

    exclusionMode: ExclusionMode.Normal

    property Region noInput: Region {}
    mask: root.surfaceLive ? null : panel.noInput

    onHeightChanged: Hyprland.refreshMonitors()
    onWidthChanged: Hyprland.refreshMonitors()

    updatesEnabled: true

    MouseArea {
      anchors.fill: parent
      visible: root.surfaceLive
      onClicked: root.dismiss()
    }

    Item {
      anchors.fill: parent
      visible: root.surfaceLive && root.backgroundImagePath !== ""
      opacity: root.backdropOpacity * root.exitOpacity

      layer.enabled: true
      layer.effect: MultiEffect {
        blurEnabled: true
        blur: 0.5
        blurMax: 12

        brightness: -0.3
      }

      Image {
        anchors.fill: parent
        source: root.backgroundImagePath ? Util.fileUrl(root.backgroundImagePath) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        sourceSize.width: Math.round(parent.width * Screen.devicePixelRatio)
      }

      Image {
        anchors.fill: parent
        fillMode: Image.Tile
        asynchronous: true
        opacity: 0.09
        source: Qt.resolvedUrl("assets/noise.png")
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      visible: root.surfaceLive

      focus: root.opened

      opacity: root.exitOpacity

      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.dismiss()
          break
        case Qt.Key_Up:
          root.moveRow(-1)
          break
        case Qt.Key_Down:
          root.moveRow(1)
          break
        case Qt.Key_Left:
          root.moveApp(-1)
          break
        case Qt.Key_Right:
          root.moveApp(1)
          break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
          root.activateSelection()
          break
        default:
          return
        }
        event.accepted = true
      }

      Keys.onReleased: function(event) {
        if (!root.opened || event.isAutoRepeat) return
        if (event.key !== Qt.Key_Super_L && event.key !== Qt.Key_Super_R) return
        if (root.keyboardSwitchMode) return
        root.switchCommit()
        event.accepted = true
      }

      Item {
        id: viewport
        anchors.fill: parent

        readonly property real dpr: Screen.devicePixelRatio

        clip: true

        function centerPositionFor(index) {
          return index * root.rowStride + root.rowHeight / 2 - viewport.height / 2
        }

        readonly property real columnOffset: -vScroll.position

        KineticScroll {
          id: vScroll

          viewportSize: viewport.height
          minPosition: viewport.centerPositionFor(0)
          maxPosition: viewport.centerPositionFor(Math.max(0, root.workspaceRows.length - 1))
          snapStride: root.rowStride
          restPosition: viewport.centerPositionFor(root.selectedRow)
          frozen: root.viewIsFrozen

          dragScale: 2.5

          onSnapped: function(index) {
            var rows = root.workspaceRows
            if (index >= 0 && index < rows.length) root.selectedWorkspaceId = rows[index].id
          }
        }

        Item {
          id: zoomLayer
          width: viewport.width
          height: viewport.height
          transformOrigin: Item.TopLeft
          scale: root.zoomFactor
          x: root.zoomOffset(root.zoomThumbX, root.zoomRealX)
          y: root.zoomOffset(root.zoomThumbY, root.zoomRealY)
          opacity: root.zoomReady ? 1 : 0

        Item {
          id: column
          width: viewport.width
          height: root.workspaceRows.length * root.rowStride
          y: viewport.columnOffset

          Repeater {
            id: rowRepeater
            model: root.workspaceRows

            delegate: Item {
              id: rowItem
              required property var modelData
              required property int index
              width: column.width
              height: root.rowHeight
              y: rowItem.index * root.rowStride

              property alias hScroll: rowScroll

              readonly property var sortedToplevels: root.sortToplevelsBySpatialOrder(root.toplevelsFor(rowItem.modelData))
              readonly property int focusedIndex: root.focusedIndexFor(rowItem.sortedToplevels)

              readonly property bool current: rowItem.index === root.selectedRow

              readonly property bool isEmptyRow: root.isEmptyRowModel(rowItem.modelData)

              readonly property int selectedIndex: {
                var n = rowItem.sortedToplevels.length
                if (rowItem.current)
                  return Math.max(0, Math.min(n - 1, root.selectedApp))
                var remembered = rowItem.modelData
                  ? root.rowSelectionFor(rowItem.modelData.id)
                  : -1
                if (remembered < 0) return rowItem.focusedIndex
                return Math.max(0, Math.min(n - 1, remembered))
              }

              readonly property real diveShift: rowItem.index === root.diveRow
                ? root.diveShiftNow
                : 0

              readonly property real stripOffset: rowScroll.position - rowViewport.restXBase

              readonly property real viewportY: rowItem.index * root.rowStride + viewport.columnOffset

              readonly property bool nearViewport: root.surfaceLive
                && rowItem.viewportY + root.rowHeight > -root.nearMargin
                && rowItem.viewportY < viewport.height + root.nearMargin

              readonly property bool renderNear:
                rowItem.viewportY + root.rowHeight > -root.renderMargin
                && rowItem.viewportY < viewport.height + root.renderMargin

              visible: rowItem.renderNear

              readonly property var monitor: rowItem.modelData.monitor

              readonly property real monScale: {
                var mon = rowItem.monitor
                if (!mon) return 1
                var s = Number(mon.scale)
                if (!isFinite(s) || s <= 0) {
                  var ipc = mon.lastIpcObject
                  s = ipc ? Number(ipc.scale) : NaN
                }
                return (isFinite(s) && s > 0) ? s : 1
              }
              readonly property real monX: rowItem.monitor ? rowItem.monitor.x : 0
              readonly property real monY: rowItem.monitor ? rowItem.monitor.y : 0
              readonly property real monW: (rowItem.monitor && rowItem.monitor.width > 0)
                ? rowItem.monitor.width / rowItem.monScale : 0
              readonly property real monH: (rowItem.monitor && rowItem.monitor.height > 0)
                ? rowItem.monitor.height / rowItem.monScale : 0

              readonly property real geomScale: rowItem.monH > 0 ? root.rowHeight / rowItem.monH : 0

              readonly property real monWidthPx: rowItem.monW * rowItem.geomScale

              readonly property var strip: {
                var left = rowItem.monX
                var right = rowItem.monX + rowItem.monW
                var vals = rowItem.sortedToplevels
                for (var i = 0; i < vals.length; i++) {
                  var r = root.rectFor(vals[i])
                  if (!r) continue
                  if (r.x < left) left = r.x
                  if (r.x + r.w > right) right = r.x + r.w
                }
                return { left: left, right: right }
              }

              readonly property var winSpan: {
                var left = NaN
                var right = NaN
                var vals = rowItem.sortedToplevels
                for (var i = 0; i < vals.length; i++) {
                  var r = root.rectFor(vals[i])
                  if (!r) r = { x: rowItem.monX, w: rowItem.monW }
                  if (isNaN(left) || r.x < left) left = r.x
                  if (isNaN(right) || r.x + r.w > right) right = r.x + r.w
                }
                if (isNaN(left)) return { left: rowItem.strip.left, right: rowItem.strip.right }
                return { left: left, right: right }
              }

              function rectInRow(toplevel) {
                var r = root.rectFor(toplevel)
                if (!r) r = { x: rowItem.monX, y: rowItem.monY, w: rowItem.monW, h: rowItem.monH }
                return {
                  x: (r.x - rowItem.strip.left) * rowItem.geomScale,
                  y: (r.y - rowItem.monY) * rowItem.geomScale,
                  w: r.w * rowItem.geomScale,
                  h: r.h * rowItem.geomScale
                }
              }

              function framedIndex() {
                var vals = rowItem.sortedToplevels
                if (vals.length === 0) return -1
                var left = rowScroll.position + rowViewport.monLeft
                var right = left + rowItem.monWidthPx
                var middle = (left + right) / 2

                var cur = rowItem.selectedIndex
                if (cur >= 0 && cur < vals.length) {
                  var c = rowItem.rectInRow(vals[cur])
                  var cMid = c.x + c.w / 2
                  if (cMid >= left && cMid <= right) return cur
                }

                var best = 0
                var bestDist = Infinity
                for (var i = 0; i < vals.length; i++) {
                  var r = rowItem.rectInRow(vals[i])
                  var d = Math.abs(r.x + r.w / 2 - middle)
                  if (d < bestDist) { bestDist = d; best = i }
                }
                return best
              }

              function thumbItemAt(i) { return thumbRepeater.itemAt(i) }

              Connections {
                target: root
                function onViewReset() { rowScroll.reset() }

                function onViewFrozen() { rowScroll.stop() }
              }

              Item {
                id: monitorRect
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0
                width: rowItem.monWidthPx
                height: root.rowHeight
                layer.enabled: true
                layer.effect: MultiEffect {
                  shadowEnabled: true
                  shadowColor: Qt.rgba(0, 0, 0, 0.6)
                  shadowBlur: 0.5
                  shadowOpacity: 0.7
                  shadowHorizontalOffset: 0
                  shadowVerticalOffset: 6
                }

                Image {
                  anchors.fill: parent
                  source: root.backgroundImagePath ? Util.fileUrl(root.backgroundImagePath) : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  smooth: true
                  visible: root.backgroundImagePath !== ""

                  sourceSize.height: Math.round(root.rowHeight * viewport.dpr)
                }
              }

              Item {
                id: rowViewport
                anchors.fill: parent
                clip: true

                readonly property real contentWidth:
                  (rowItem.strip.right - rowItem.strip.left) * rowItem.geomScale

                readonly property real monLeft: (rowViewport.width - rowItem.monWidthPx) / 2

                readonly property real winLeft:
                  (rowItem.winSpan.left - rowItem.strip.left) * rowItem.geomScale
                readonly property real winRight:
                  (rowItem.winSpan.right - rowItem.strip.left) * rowItem.geomScale

                readonly property real restXBase:
                  (rowItem.monX - rowItem.strip.left) * rowItem.geomScale
                    - rowViewport.monLeft

                readonly property real restX: {
                  var pos = rowViewport.restXBase
                  var vals = rowItem.sortedToplevels
                  var i = rowItem.selectedIndex
                  if (i < 0 || i >= vals.length) return pos
                  var r = rowItem.rectInRow(vals[i])
                  var left = pos + rowViewport.monLeft
                  if (r.x < left) return r.x - rowViewport.monLeft
                  if (r.x + r.w > left + rowItem.monWidthPx)
                    return r.x + r.w - rowViewport.monLeft - rowItem.monWidthPx
                  return pos
                }

                KineticScroll {
                  id: rowScroll
                  viewportSize: rowItem.monWidthPx

                  minPosition: Math.min(rowViewport.winLeft - rowViewport.monLeft,
                                        rowViewport.restX)
                  maxPosition: Math.max(rowViewport.winRight - rowViewport.monLeft
                                          - rowItem.monWidthPx,
                                        rowViewport.restX)

                  restPosition: rowViewport.restX
                  frozen: root.viewIsFrozen
                  notchPixels: root.rowHeight * 0.6

                  momentumTau: 0.45

                  dragScale: 2.5

                  onSettled: {
                    if (!rowItem.current || root.viewIsFrozen || !root.opened) return
                    var i = rowItem.framedIndex()

                    if (i >= 0) root.noteSelectedApp(i)
                  }
                }

                Item {
                  id: rowContent

                  x: -rowScroll.position - rowItem.diveShift
                  width: rowViewport.contentWidth
                  height: rowViewport.height

                  Repeater {
                    id: thumbRepeater
                    model: rowItem.sortedToplevels

                    Rectangle {
                      id: thumb
                      required property var modelData
                      required property int index

                      readonly property var geom: rowItem.rectInRow(thumb.modelData)
                      x: thumb.geom.x
                      y: thumb.geom.y

                      readonly property bool ringed: thumb.index === rowItem.selectedIndex
                        || hoverArea.containsMouse

                      readonly property bool active: thumb.ringed
                        && (rowItem.current || hoverArea.containsMouse)

                      width: thumb.geom.w
                      height: thumb.geom.h
                      radius: Style.cornerRadius

                      color: thumb.hasPicture ? "transparent" : Color.background

                      readonly property real ringWidth: Style.space(2)

                      readonly property bool hasPicture: capture.hasContent

                      property real lastCaptureMs: 0

                      function requestCapture() {
                        if (!root.captureContextReady) return
                        capture.captureFrame()
                        thumb.lastCaptureMs = Date.now()
                      }

                      readonly property bool nearRow: {
                        var left = thumb.geom.x + rowContent.x
                        var slack = rowItem.monWidthPx * 0.5
                        return left + thumb.geom.w > -slack
                          && left < rowViewport.width + slack
                      }

                      Item {
                        id: captureBox

                        anchors.fill: parent

                        readonly property real superSample: {
                          var src = capture.sourceSize
                          var devW = captureBox.width * viewport.dpr
                          if (!capture.hasContent || !(src.width > 0) || !(devW > 0)) return 1
                          return Math.max(1, Math.min(2, src.width / devW))
                        }

                        layer.enabled: true
                        layer.smooth: true
                        layer.mipmap: true
                        layer.textureSize: Qt.size(
                          Math.max(1, Math.round(captureBox.width * viewport.dpr * captureBox.superSample)),
                          Math.max(1, Math.round(captureBox.height * viewport.dpr * captureBox.superSample)))

                        ScreencopyView {
                          id: capture
                          anchors.fill: parent
                          captureSource: thumb.modelData.wayland

                          live: false
                          paintCursor: false

                          Component.onCompleted: {}

                          Connections {
                            target: root
                            function onViewReset() {
                              if (root.opened && root.captureContextReady && !capture.hasContent)
                                thumb.requestCapture()
                            }
                          }

                          onHasContentChanged: if (capture.hasContent) captureRevive.tries = 0
                        }
                      }

                      Timer {
                        id: captureRevive
                        property int tries: 0
                        interval: 300
                        repeat: true
                        running: root.opened && !capture.hasContent
                          && root.captureContextReady
                          && rowItem.nearViewport && thumb.nearRow
                          && captureRevive.tries < 12
                        onTriggered: {
                          var src = thumb.modelData ? thumb.modelData.wayland : null
                          if (!src) return
                          captureRevive.tries++
                          capture.captureSource = null
                          capture.captureSource = src

                          thumb.lastCaptureMs = Date.now()
                        }
                      }

                      Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: thumb.radius
                        border.width: thumb.ringed ? thumb.ringWidth : 0
                        border.color: thumb.active
                          ? Color.accent
                          : Util.alpha(Color.foreground, 0.4)
                      }

                      MouseArea {
                        id: hoverArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateToplevel(thumb.modelData, rowItem.index, thumb.index)
                      }
                    }
                  }
                }

              }

              MouseArea {
                id: emptyTarget
                anchors.fill: monitorRect
                visible: rowItem.isEmptyRow
                enabled: rowItem.isEmptyRow
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activateWorkspace(rowItem.modelData.id)

                Rectangle {
                  anchors.fill: parent
                  color: "transparent"
                  border.width: emptyTarget.containsMouse ? Style.space(2) : 0
                  border.color: rowItem.current
                    ? Color.accent
                    : Util.alpha(Color.foreground, 0.4)
                }
              }

              Rectangle {
                id: wsBadge
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: Style.space(10)
                anchors.topMargin: Style.space(10)
                width: wsBadgeText.implicitWidth + Style.space(18)
                height: wsBadgeText.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: Util.alpha(Color.background, 0.85)
                border.width: Math.max(1, Style.space(1))
                border.color: rowItem.current
                  ? Util.alpha(Color.accent, 0.75)
                  : Util.alpha(Color.foreground, 0.25)
                opacity: Math.max(0, 1 - root.zoomProgress * 3)

                Text {
                  id: wsBadgeText
                  anchors.centerIn: parent
                  text: String(rowItem.modelData.id)
                  color: rowItem.current ? Color.accent : Color.foreground
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Math.round(root.rowHeight * 0.13)
                }
              }
            }
          }
        }
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          hoverEnabled: false
          onWheel: function(wheel) {
            if (!root.isTouchpadWheel(wheel)) {
              if (Math.abs(wheel.angleDelta.y) < Math.abs(wheel.angleDelta.x)) {
                var hWheel = root.selectedRowScroll()
                if (hWheel) hWheel.stepBy(-wheel.angleDelta.x / 120)
                wheel.accepted = true
                return
              }
              vScroll.stepBy(-wheel.angleDelta.y / 120)
              wheel.accepted = true
              return
            }

            if (wheel.phase === Qt.ScrollBegin) root.gestureAxis = ""
            if (root.gestureAxis === "") {
              root.gestureAxis = root.axisFor(wheel.pixelDelta.x, wheel.pixelDelta.y)
            }
            gestureIdle.restart()

            if (root.gestureAxis === "x") {
              var hDrag = root.selectedRowScroll()
              if (wheel.phase === Qt.ScrollEnd) {
                root.gestureAxis = ""
                gestureIdle.stop()
                if (hDrag) hDrag.endDrag()
              } else if (hDrag) {

                hDrag.dragBy(wheel.pixelDelta.x)
              }
              wheel.accepted = true
              return
            }

            if (wheel.phase === Qt.ScrollEnd) {
              root.gestureAxis = ""
              gestureIdle.stop()
              vScroll.endDrag()
            } else {

              vScroll.dragBy(wheel.pixelDelta.y)
            }
            wheel.accepted = true
          }
        }
      }
    }
  }

  SwitcherAltTab {
    id: altTab
    overview: root
  }

  Component.onDestruction: {
    if (!root.pluginRegistry || !root.manifest || !root.manifest.id
        || root.pluginRegistry.isEnabled(root.manifest.id)) return
    Quickshell.execDetached([

      "bash", "-c",
      'state="${XDG_STATE_HOME:-$HOME/.local/state}"; '
      + 'rm -f -- "$state/omarchy/toggles/hypr/switcher-mode.lua" '
      + '"$state/omarchy/toggles/hypr/switcher-overview.lua" '
      + '"$state/omarchy/toggles/hypr/switcher-alttab.lua"; '
      + 'hyprctl reload >/dev/null 2>&1'
    ])
  }
}
