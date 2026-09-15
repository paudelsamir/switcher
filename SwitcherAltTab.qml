import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "AltTabIcon.js" as AltTabIcon

Item {
  id: root

  property var overview: null

  property bool active: false
  property bool leaving: false

  readonly property bool surfaceLive: root.active || root.leaving

  readonly property real captureBudget: 12
  readonly property int captureCooldownMs: 1500
  property real captureTokens: 0

  Timer {
    id: captureTick
    interval: 80
    repeat: true
    running: root.surfaceLive
    onTriggered: root.captureTock()
  }

  function captureNext() {
    var now = Date.now()
    var blank = null
    var stale = null, staleAge = -1
    for (var i = 0; i < cards.count; i++) {
      var c = cards.itemAt(i)
      if (!c || !c.requestCapture || !c.near) continue
      if (!c.hasPicture) { if (!blank) blank = c; continue }
      var age = now - c.lastCaptureMs
      if (age >= root.captureCooldownMs && age > staleAge) { staleAge = age; stale = c }
    }
    return blank || stale
  }

  function captureTock() {
    if (!root.surfaceLive || root.leaving) return
    root.captureTokens = Math.min(1, root.captureTokens + root.captureBudget * (captureTick.interval / 1000))
    if (root.captureTokens < 1) return
    var c = root.captureNext()
    if (!c) return
    root.captureTokens -= 1
    c.requestCapture()
  }

  property string scope: "all"
  property int selected: 0

  property string persistedScope: "all"

  readonly property string selectedIcon: {
    var e = root.currentEntry()
    return (e && e.cls) ? AltTabIcon.resolve(e.cls, e.title) : ""
  }

  readonly property string selectedIconSource: {
    return ""
  }

  property var iconOverrides: [
    { cls: "org.omarchy.agent", source: Qt.resolvedUrl("assets/opencode-logo.png"), name: "opencode" }
  ]

  property var classCache: ({})

  function resolveEntryIcon(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var themed = Quickshell.iconPath(value, true)
    if (themed.length > 0) return themed
    return ""
  }

  function resolveClass(cls) {
    var clsName = String(cls || "")
    if (clsName === "") return { source: "", name: "" }
    if (clsName in root.classCache) return root.classCache[clsName]
    var needle = clsName.toLowerCase()
    var hit = { source: "", name: "" }
    for (var o = 0; o < root.iconOverrides.length; o++) {
      var ov = root.iconOverrides[o]
      if (String(ov.cls).toLowerCase() === needle) {
        hit = { source: "", name: ov.name || root.friendlyClass(clsName) }
        break
      }
    }
    if (hit.source === "") {
      var values = (typeof DesktopEntries !== "undefined" && DesktopEntries.applications)
        ? DesktopEntries.applications.values : []
      outer: for (var i = 0; i < values.length; i++) {
        var entry = values[i]
        if (!entry || !entry.icon) continue
        var sc = String(entry.startupClass || "").toLowerCase()
        var name = String(entry.name || "").toLowerCase()
        var id = String(entry.id || "").toLowerCase()
        var idBase = (id.length > 8 && id.slice(-8) === ".desktop") ? id.slice(0, -8) : id
        var execBase = ""
        var exec = String(entry.execString || "").trim()
        if (exec) {
          execBase = exec.split(/\s+/)[0].split("/").pop().toLowerCase()
          if (execBase.slice(-3) === ".sh") execBase = execBase.slice(0, -3)
        }
        if (sc === needle || name === needle || id === needle
          || idBase === needle || execBase === needle) {
          hit = { source: "", name: entry.name || clsName }
          break outer
        }
      }
    }
    if (hit.name === "") hit.name = root.friendlyClass(clsName)
    root.classCache[clsName] = hit
    return hit
  }

  function iconSourceFor(cls) {
    return root.resolveClass(cls).source
  }

  function appNameFor(cls) {
    return root.resolveClass(cls).name
  }

  function friendlyClass(cls) {
    var base = String(cls || "").split(".").pop()
    return base && base !== String(cls || "") ? base : String(cls || "")
  }
  readonly property string selectedTitle: {
    var e = root.currentEntry()
    if (!e) return ""
    var live = (e.toplevel && e.toplevel.wayland && e.toplevel.wayland.title)
      ? e.toplevel.wayland.title : ""
    return live ? String(live) : e.title
  }

  readonly property string selectedClass: {
    var e = root.currentEntry()
    return (e && e.cls) ? e.cls : ""
  }

  readonly property string selectedApp: {
    var e = root.currentEntry()
    return (e && e.cls) ? root.appNameFor(e.cls) : ""
  }

  property var entries: []

  property int sessionWorkspaceId: -1
  property int sessionMonitorId: -1

  property real exitOpacity: 1
  property bool grabsKeyboard: false

  property var mru: []

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.noteFocus(Hyprland.activeToplevel) }
  }

  Component.onCompleted: {
    root.targetScreen = root.pickScreen()
    root.noteFocus(Hyprland.activeToplevel)
  }

  function addressOf(toplevel) {
    var ipc = toplevel && toplevel.lastIpcObject
    return (ipc && ipc.address) ? String(ipc.address) : ""
  }

  function noteFocus(toplevel) {
    var address = root.addressOf(toplevel)
    if (address === "") return
    if (root.mru.length > 0 && root.mru[0] === address) return
    var next = [address]
    for (var i = 0; i < root.mru.length; i++) {
      if (root.mru[i] !== address) next.push(root.mru[i])
    }

    root.mru = next
  }

  function snapshot() {
    var values = (Hyprland.toplevels && Hyprland.toplevels.values) ? Hyprland.toplevels.values : []
    var out = []
    for (var i = 0; i < values.length; i++) {
      var toplevel = values[i]
      var ipc = toplevel ? toplevel.lastIpcObject : null
      if (!ipc || !ipc.address) continue
      var size = ipc.size
      var w = (size && size.length >= 2) ? Number(size[0]) : 0
      var h = (size && size.length >= 2) ? Number(size[1]) : 0
      var aspect = (isFinite(w) && isFinite(h) && w > 0 && h > 0) ? (w / h) : (16 / 9)
      var address = String(ipc.address)
      var rank = root.mru.indexOf(address)
      var history = Number(ipc.focusHistoryID)
      out.push({
        toplevel: toplevel,
        address: address,
        title: String(ipc.title || ""),
        cls: String(ipc.class || ""),
        workspaceId: ipc.workspace ? Number(ipc.workspace.id) : 0,
        monitorId: Number(ipc.monitor),

        aspect: Math.max(0.4, Math.min(3.2, aspect)),

        order: rank >= 0 ? rank : root.mru.length + (isFinite(history) ? history : 9999)
      })
    }
    out.sort(function(a, b) { return a.order - b.order })
    return out
  }

  function entryAlive(entry) {
    return !!(entry && entry.toplevel && entry.toplevel.wayland)
  }

  function filtered(list, scope) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (!root.entryAlive(entry)) continue
      if (scope === "workspace" && entry.workspaceId !== root.sessionWorkspaceId) continue
      if (scope === "output" && entry.monitorId !== root.sessionMonitorId) continue
      out.push(entry)
    }
    return out
  }

  readonly property var visibleEntries: root.filtered(root.entries, root.scope)
  readonly property int count: root.visibleEntries.length

  function currentEntry() {
    var list = root.visibleEntries
    if (list.length === 0) return null
    return list[Math.max(0, Math.min(list.length - 1, root.selected))]
  }

  function step(dir) {
    if (!root.active) { root.begin(dir); return }
    if (root.count === 0) return
    var delta = (dir === "prev") ? -1 : 1
    root.selected = ((root.selected + delta) % root.count + root.count) % root.count
  }

  function begin(dir) {
    if (root.overview && root.overview.opened) return

    Hyprland.refreshToplevels()

    var workspace = Hyprland.focusedWorkspace
    var monitor = Hyprland.focusedMonitor
    root.sessionWorkspaceId = workspace ? Number(workspace.id) : -1
    root.sessionMonitorId = monitor ? Number(monitor.id) : -1

    root.scope = root.persistedScope
    root.entries = root.snapshot()

    var list = root.filtered(root.entries, root.scope)

    if (list.length === 0) { root.entries = []; root.notifyClosed(); return }

    root.selected = (dir === "prev") ? (list.length - 1) : (list.length > 1 ? 1 : 0)

    root.targetScreen = root.pickScreen()
    exitFade.stop()
    root.exitOpacity = 1
    root.grabsKeyboard = true

    root.active = true
    root.leaving = false
    strip.settleNow()
  }

  function move(delta) {
    if (!root.active || root.count === 0) return
    root.selected = ((root.selected + delta) % root.count + root.count) % root.count
  }

  function setScope(next) {
    if (!root.active || next === root.scope) return
    var before = root.currentEntry()
    var list = root.filtered(root.entries, next)
    root.scope = next
    root.persistedScope = next
    if (list.length === 0) { root.selected = 0; return }
    var index = -1
    if (before) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].address === before.address) { index = i; break }
      }
    }
    root.selected = index >= 0 ? index : Math.max(0, Math.min(list.length - 1, root.selected))
  }

  function commit(entry) {
    if (!root.active) return
    var target = entry || root.currentEntry()
    root.notifyClosed()
    if (!target) { root.dismiss(); return }
    root.beginHandOff("hl.dsp.focus({ window = 'address:" + target.address + "' })")
  }

  function dismiss() {
    if (!root.surfaceLive) return
    root.notifyClosed()
    root.leaving = true
    root.active = false
    root.grabsKeyboard = false
    exitFade.restart()
  }

  function finish() {
    root.leaving = false
    root.exitOpacity = 1
    root.entries = []
    root.selected = 0
  }

  NumberAnimation {
    id: exitFade
    target: root
    property: "exitOpacity"
    from: 1
    to: 0
    duration: 110
    easing.type: Easing.OutQuad
    onFinished: root.finish()
  }

  property string pendingDispatch: ""

  function beginHandOff(arg) {
    root.leaving = true
    root.active = false
    root.grabsKeyboard = false
    root.pendingDispatch = arg
    restoreFallback.restart()
  }

  Connections {
    target: Hyprland
    enabled: root.pendingDispatch !== ""
    function onRawEvent(event) {
      if (event.name === "activewindow" || event.name === "activewindowv2"
        || event.name === "workspace" || event.name === "workspacev2") {
        root.runPendingDispatch()
      }
    }
  }

  Timer {
    id: restoreFallback
    interval: 90
    onTriggered: root.runPendingDispatch()
  }

  function runPendingDispatch() {
    if (root.pendingDispatch === "") return
    var arg = root.pendingDispatch
    root.pendingDispatch = ""
    restoreFallback.stop()
    root.hyprSend("dispatch " + arg)
    exitFade.restart()
  }

  property string hyprRequest: ""

  Socket {
    id: hyprIpc
    path: Hyprland.requestSocketPath
    onConnectionStateChanged: {
      if (!hyprIpc.connected) return
      hyprIpc.write(root.hyprRequest)
      hyprIpc.flush()
    }
  }

  function hyprSend(request) {
    root.hyprRequest = request
    if (hyprIpc.connected) hyprIpc.connected = false
    hyprIpc.connected = true
  }

  function notifyClosed() {
    root.hyprSend("dispatch switcher_alttab_closed()")
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var data = String(event.data || "")
      if (data.indexOf("switcher:alttab ") !== 0) return
      var parts = data.split(" ")
      switch (parts[1]) {
      case "step":
        root.step(parts[2])
        break
      case "commit":
        root.commit(null)
        break
      }
    }
  }

  property var targetScreen: null

  function pickScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name) : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    return root.targetScreen
  }

  PanelWindow {
    id: panel

    visible: true
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "switcher-alttab"

    WlrLayershell.layer: root.surfaceLive ? WlrLayer.Overlay : WlrLayer.Background

    WlrLayershell.keyboardFocus: (root.surfaceLive && root.grabsKeyboard)
      ? WlrKeyboardFocus.Exclusive
      : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    property Region noInput: Region {}
    mask: root.surfaceLive ? null : panel.noInput

    readonly property real tileHeight: Math.max(Style.space(96), Math.round(panel.height * 0.24))
    readonly property real selectedTileHeight: Math.round(panel.tileHeight * 1.24)
    readonly property real cardPadding: Style.space(10)
    readonly property real tileGap: Style.space(26)
    readonly property real titleGap: Style.space(16)
    readonly property real titleHeight: Math.round(Style.font.subtitle * 1.5)

    readonly property real cardIconSize: Math.round(Style.font.body * 2.5)
    readonly property real iconTopGap: Style.space(8)
    readonly property real iconTrail: Style.space(4)
    readonly property real iconSpace: panel.iconTopGap + panel.cardIconSize + panel.iconTrail

    readonly property real bandHeight: panel.selectedTileHeight + 2 * panel.cardPadding
    readonly property real stripHeight: panel.bandHeight + panel.titleGap
      + panel.titleHeight + panel.iconSpace

    readonly property real minCardWidth: Style.space(120)

    function cardWidthAt(index) {
      var list = root.visibleEntries
      var entry = list[index]
      if (!entry) return 0
      var h = (index === root.selected) ? panel.selectedTileHeight : panel.tileHeight
      return Math.max(panel.minCardWidth, Math.round(h * entry.aspect) + 2 * panel.cardPadding)
    }

    function cardXAt(index) {
      var x = 0
      for (var i = 0; i < index; i++) x += panel.cardWidthAt(i) + panel.tileGap
      return x
    }

    readonly property real stripWidth: {
      var n = root.count
      if (n === 0) return 0
      return panel.cardXAt(n - 1) + panel.cardWidthAt(n - 1)
    }

    Rectangle {
      anchors.fill: parent
      visible: root.surfaceLive

      color: Util.alpha(Qt.darker(Color.background, 2.4), 0.8)
      opacity: root.exitOpacity
    }

    MouseArea {
      anchors.fill: parent
      visible: root.surfaceLive
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      visible: root.surfaceLive
      focus: root.active
      opacity: root.exitOpacity

      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.dismiss()
          break
        case Qt.Key_A:
          root.setScope("all")
          break
        case Qt.Key_W:
          root.setScope("workspace")
          break
        case Qt.Key_O:
          root.setScope("output")
          break
        case Qt.Key_Left:
          root.move(-1)
          break
        case Qt.Key_Right:
          root.move(1)
          break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
          root.commit(null)
          break
        default:
          return
        }
        event.accepted = true
      }

      Keys.onReleased: function(event) {
        if (!root.active || event.isAutoRepeat) return
        if (event.key !== Qt.Key_Alt) return
        root.commit(null)
        event.accepted = true
      }

      Rectangle {
        id: scopePill
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.055)
        width: scopeRow.implicitWidth + Style.space(28)
        height: scopeRow.implicitHeight + Style.space(14)
        radius: Style.cornerRadius
        color: Util.alpha(Color.background, 0.92)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(Color.foreground, 0.28)

        Row {
          id: scopeRow
          anchors.centerIn: parent
          spacing: Style.space(12)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Scope:"
            color: Qt.darker(Color.foreground, 1.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
          }

          Repeater {
            model: [
              { key: "all", label: "All" },
              { key: "workspace", label: "Workspace" },
              { key: "output", label: "Output" }
            ]

            Row {
              required property var modelData
              readonly property bool current: root.scope === modelData.key
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                text: parent.modelData.label.charAt(0)
                color: parent.current ? Color.foreground : Qt.darker(Color.foreground, 1.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.underline: true
                font.bold: parent.current
              }

              Text {
                text: parent.modelData.label.substring(1)
                color: parent.current ? Color.foreground : Qt.darker(Color.foreground, 1.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: parent.current
              }
            }
          }
        }
      }

      Item {
        id: viewport
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: panel.stripHeight
        clip: true

        Item {
          id: strip
          y: 0
          width: panel.stripWidth
          height: panel.stripHeight
          x: root.count === 0 ? 0 : strip.restX

          property real restX: 0

          readonly property real revealMargin: panel.tileGap * 1.6

          function settleNow() {
            slide.enabled = false
            strip.restX = panel.tileGap
            strip.reveal()
            slide.enabled = true
          }

          function reveal() {
            var n = root.count
            if (n === 0) { strip.restX = 0; return }
            var viewportWidth = viewport.width
            var content = panel.stripWidth

            if (content <= viewportWidth) {
              strip.restX = Math.round((viewportWidth - content) / 2)
              return
            }
            var index = Math.max(0, Math.min(n - 1, root.selected))
            var left = panel.cardXAt(index)
            var right = left + panel.cardWidthAt(index)
            var margin = Math.min(strip.revealMargin, (viewportWidth - panel.cardWidthAt(index)) / 2)
            var x = strip.restX
            if (left + x < margin) x = margin - left
            else if (right + x > viewportWidth - margin) x = viewportWidth - margin - right

            var minX = viewportWidth - content - panel.tileGap
            var maxX = panel.tileGap
            strip.restX = Math.round(Math.max(minX, Math.min(maxX, x)))
          }

          Behavior on x {
            id: slide
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
          }

          Repeater {
            id: cards
            model: root.visibleEntries

            Item {
              id: card
              required property var modelData
              required property int index

              readonly property bool current: card.index === root.selected
              readonly property real tileHeight: card.current
                ? panel.selectedTileHeight
                : panel.tileHeight
              readonly property real tileWidth: Math.round(card.tileHeight * card.modelData.aspect)

              readonly property string iconSource: ""
              readonly property string iconGlyph: (card.modelData && card.modelData.cls)
                ? AltTabIcon.resolve(card.modelData.cls, card.modelData.title) : ""

              readonly property bool near: {
                var left = card.x + strip.x
                var slack = panel.tileHeight * 2
                return left + card.width > -slack && left < viewport.width + slack
              }

              visible: card.near

              property real lastCaptureMs: 0
              readonly property bool hasPicture: shotView.hasContent
              function requestCapture() {
                if (!shotView.live) shotView.captureFrame()
                card.lastCaptureMs = Date.now()
              }

              x: panel.cardXAt(card.index)
              y: 0
              width: panel.cardWidthAt(card.index)
              height: panel.stripHeight

              Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

              Rectangle {
                id: plate
                anchors.horizontalCenter: parent.horizontalCenter

                y: panel.bandHeight - plate.height
                width: card.tileWidth + 2 * panel.cardPadding
                height: card.tileHeight + 2 * panel.cardPadding
                radius: Style.cornerRadius

                color: card.current ? Util.alpha(Color.foreground, 0.16) : "transparent"
                border.width: card.current ? Math.max(1, Style.space(1)) : 0
                border.color: Util.alpha(Color.accent, 0.75)

                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                Rectangle {
                  id: shot
                  anchors.centerIn: parent
                  width: card.tileWidth
                  height: card.tileHeight
                  radius: Style.cornerRadius
                  color: Color.background
                  clip: true
                  opacity: card.current ? 1.0 : 0.72

                  Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                  Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                  Item {
                    id: captureBox
                    anchors.fill: parent

                    layer.enabled: true
                    layer.smooth: true
                    layer.mipmap: true

                    ScreencopyView {
                      id: shotView
                      anchors.fill: parent
                      captureSource: card.modelData.toplevel.wayland

                      live: root.surfaceLive && card.near
                      paintCursor: false
                    }

                    Rectangle {
                      anchors.fill: parent
                      visible: !shotView.hasContent
                      color: Util.alpha(Color.background, 0.92)

                      Text {
                        anchors.centerIn: parent
                        width: parent.width - Style.space(20)
                        text: card.modelData.title || "Preview unavailable"
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.subtitle
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                      }
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor

                  onClicked: root.commit(card.modelData)
                }

                Rectangle {
                  id: wsTag
                  anchors.left: shot.left
                  anchors.top: shot.top
                  anchors.margins: Math.max(2, Style.space(2))
                  width: wsTagText.implicitWidth + Style.space(8)
                  height: wsTagText.implicitHeight + Style.space(4)
                  radius: Style.cornerRadius
                  visible: card.modelData.workspaceId > 0

                  color: Util.alpha(Color.background, 0.85)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(Color.accent, 0.85)

                  Text {
                    id: wsTagText
                    anchors.centerIn: parent
                    text: String(card.modelData.workspaceId)
                    color: Color.accent
                    font.family: Style.font.family
                    font.bold: true
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                y: panel.bandHeight + panel.titleGap + panel.titleHeight + panel.iconTopGap
                spacing: 0

                Image {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: card.iconSource !== ""
                  source: card.iconSource
                  width: panel.cardIconSize
                  height: panel.cardIconSize
                  sourceSize.width: panel.cardIconSize * 2
                  sourceSize.height: panel.cardIconSize * 2
                  smooth: true
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: card.iconSource === ""
                  text: card.iconGlyph
                  color: card.current ? Color.foreground : Qt.darker(Color.foreground, 1.5)
                  font.family: Style.font.icon
                  font.pixelSize: panel.cardIconSize
                }
              }

              Text {
                y: panel.bandHeight + panel.titleGap
                width: parent.width
                height: panel.titleHeight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight

                text: (card.modelData.toplevel && card.modelData.toplevel.wayland
                  && card.modelData.toplevel.wayland.title)
                  ? card.modelData.toplevel.wayland.title
                  : card.modelData.title
                color: card.current ? Color.foreground : Qt.darker(Color.foreground, 1.6)
                font.family: Style.font.family
                font.pixelSize: card.current ? Style.font.subtitle : Style.font.body
              }
            }
          }
        }
      }

      Text {
        anchors.centerIn: viewport
        visible: root.count === 0
        text: root.scope === "workspace" ? "No windows on this workspace"
          : root.scope === "output" ? "No windows on this monitor"
          : "No windows"
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
      }

      Rectangle {
        id: selectionBadge
        visible: root.count > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.round(parent.height * 0.045)
        width: badgeRow.implicitWidth + Style.space(40)
        height: badgeRow.implicitHeight + Style.space(22)
        radius: Style.cornerRadius
        color: Util.alpha(Color.background, 0.92)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(Color.foreground, 0.28)

        readonly property real maxTitleWidth: Math.max(120,
          Math.round(parent.parent.width * 0.5) - Style.space(40))

        Row {
          id: badgeRow
          anchors.centerIn: parent
          spacing: Style.space(18)

          Image {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.selectedIconSource !== ""
            source: root.selectedIconSource
            sourceSize.width: Style.font.displayLarge * 2
            sourceSize.height: Style.font.displayLarge * 2
            width: Style.font.displayLarge
            height: Style.font.displayLarge
            smooth: true
            asynchronous: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.selectedIconSource === ""
            text: root.selectedIcon
            color: Color.foreground
            font.family: Style.font.icon
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.selectedApp
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
            maximumLineCount: 1
            width: Math.min(implicitWidth, selectionBadge.maxTitleWidth)
          }
        }
      }
    }
  }

  onSelectedChanged: strip.reveal()
  onCountChanged: strip.reveal()

  Timer {
    interval: 20000
    running: root.active
    onTriggered: root.dismiss()
  }
}
