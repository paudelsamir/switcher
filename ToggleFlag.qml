import QtQuick
import Quickshell.Io

Item {
  id: root

  required property string flagName

  signal settled()

  property bool enabled: false
  property bool loaded: false
  property bool busy: false

  readonly property string error: toggleError || probeError
  property string probeError: ""
  property string toggleError: ""

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)

    try { url = decodeURIComponent(url) } catch (e) {}
    return url.replace(/\/+$/, "")
  }

  readonly property var toggleCommand: ["bash", root.pluginDir + "/bin/switcher-toggle", root.flagName]

  function refresh() {
    if (!statusProbe.running) statusProbe.start()
  }

  function apply(target) {
    if (busy) return
    busy = true
    toggleError = ""

    enabled = target
    toggleProcess.start(target ? "on" : "off")
  }

  function toggle() {
    apply(!enabled)
  }

  QtObject {
    id: probeState
    property string out: ""
    property string err: ""
    property int code: -1
    property bool exited: false
    property bool outDone: false
    property bool errDone: false
    readonly property bool ready: exited && outDone && errDone
  }

  Process {
    id: statusProbe
    command: root.toggleCommand.concat(["status"])

    function start() {
      probeState.out = ""
      probeState.err = ""
      probeState.code = -1
      probeState.exited = false
      probeState.outDone = false
      probeState.errDone = false
      running = true
    }

    function settle() {
      if (!probeState.ready) return
      var out = probeState.out.trim()
      var err = probeState.err.trim()
      if (probeState.code === 0) {
        root.enabled = out === "on"
        root.probeError = ""
      } else {

        root.probeError = err || ("switcher-toggle " + root.flagName + " status exited " + probeState.code)
      }
      root.loaded = true
    }

    onExited: function(exitCode) {
      probeState.code = exitCode
      probeState.exited = true
      settle()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { probeState.out = String(text); probeState.outDone = true; statusProbe.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { probeState.err = String(text); probeState.errDone = true; statusProbe.settle() }
    }
  }

  QtObject {
    id: toggleState
    property string out: ""
    property string err: ""
    property int code: -1
    property bool exited: false
    property bool outDone: false
    property bool errDone: false
    readonly property bool ready: exited && outDone && errDone
  }

  Process {
    id: toggleProcess

    function start(action) {
      command = root.toggleCommand.concat([action])
      toggleState.out = ""
      toggleState.err = ""
      toggleState.code = -1
      toggleState.exited = false
      toggleState.outDone = false
      toggleState.errDone = false
      running = true
    }

    function settle() {
      if (!toggleState.ready) return
      var out = toggleState.out.trim()
      var err = toggleState.err.trim()
      root.busy = false
      if (toggleState.code === 0) {
        root.enabled = out === "on"
        root.toggleError = ""
        root.loaded = true
      } else {
        root.toggleError = err || ("switcher-toggle " + root.flagName + " exited " + toggleState.code)

        root.refresh()
      }

      root.settled()
    }

    onExited: function(exitCode) {
      toggleState.code = exitCode
      toggleState.exited = true
      settle()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { toggleState.out = String(text); toggleState.outDone = true; toggleProcess.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { toggleState.err = String(text); toggleState.errDone = true; toggleProcess.settle() }
    }
  }

  Component.onCompleted: refresh()
}
