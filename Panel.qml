import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "paudelsamir.switcher"
  ipcTarget: "paudelsamir.switcher"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.65)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string modeToggleHint:
    modeFlag.enabled
      ? "Disable the Niri-style tiling workflow and all its settings"
      : "Enable Niri-style tiling with scrollable workspaces and gestures"

  readonly property string overviewToggleHint:
    overviewFlag.enabled
      ? "Hide the zoomed-out overview (Super+` or Super+Alt+O)"
      : "Zoom out across workspaces with Super+` or Super+Alt+O"

  readonly property string alttabToggleHint:
    alttabFlag.enabled
      ? "Disable window switching (Alt+Tab)"
      : "Switch windows with Alt+Tab back and forth"

  readonly property string workspaceToggleHint:
    workspaceFlag.enabled
      ? "Stop Super+Tab from cycling workspaces"
      : "Cycle workspaces with Super+Tab and Super+Shift+Tab"

  readonly property string statusText: modeFlag.error !== "" ? "Switcher is unavailable"
    : !modeFlag.loaded ? "Checking status…"
    : (modeFlag.enabled ? "Switcher is on" : "Switcher is off")

  readonly property bool widgetHidden: root.setting("widgetHidden", false)

  function setWidgetHidden(v) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry.widgetHidden = v
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  implicitWidth: root.widgetHidden ? 0 : button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    modeFlag.refresh()
    overviewFlag.refresh()
    alttabFlag.refresh()
    workspaceFlag.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  ToggleFlag {
    id: modeFlag
    flagName: "mode"
    onSettled: {
      overviewFlag.refresh()
      alttabFlag.refresh()
      workspaceFlag.refresh()
    }
  }

  ToggleFlag {
    id: overviewFlag
    flagName: "overview"
  }

  ToggleFlag {
    id: alttabFlag
    flagName: "alttab"
  }

  ToggleFlag {
    id: workspaceFlag
    flagName: "workspace"
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return !modeFlag.loaded ? "unknown" : (modeFlag.enabled ? "on" : "off") }
    function enable(): string { modeFlag.apply(true); return "on" }
    function disable(): string { modeFlag.apply(false); return "off" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    visible: !root.widgetHidden
    bar: root.bar
    iconComponent: Component {
      Image {
        anchors.fill: parent
        source: Qt.resolvedUrl("assets/niri-icon.png")
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        opacity: modeFlag.enabled ? 1.0 : 0.55
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) modeFlag.toggle()
      else if (buttonCode === Qt.MiddleButton) {
        modeFlag.refresh(); overviewFlag.refresh(); alttabFlag.refresh(); workspaceFlag.refresh()
      }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: modeFlag.toggle()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "o" || t === "O") modeFlag.toggle()
        else if ((t === "v" || t === "V") && modeFlag.enabled) overviewFlag.toggle()
        else if ((t === "a" || t === "A") && modeFlag.enabled) alttabFlag.toggle()
        else if ((t === "w" || t === "W") && modeFlag.enabled) workspaceFlag.toggle()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: "Switcher"
          meta: root.statusText
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        PanelSeparator { foreground: root.foreground }

        Toggle {
          id: modeToggle
          width: parent.width
          label: "Switcher"
          checked: modeFlag.enabled
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: modeFlag.toggle()
          onHovered: function(isHovered) { modeToggle.isHovering = isHovered }

          property bool isHovering: false

          PanelToolTip {
            visible: modeToggle.isHovering
            text: root.modeToggleHint
            fontFamily: root.fontFamily
          }
        }

        Text {
          width: parent.width
          visible: modeFlag.error !== ""
          text: modeFlag.error
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: modeFlag.enabled

          Toggle {
            id: overviewToggle
            width: parent.width
            label: "Overview"
            checked: overviewFlag.enabled
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: overviewFlag.toggle()
            onHovered: function(isHovered) { overviewToggle.isHovering = isHovered }

            property bool isHovering: false

            PanelToolTip {
              visible: overviewToggle.isHovering
              text: root.overviewToggleHint
              fontFamily: root.fontFamily
            }
          }

          Text {
            width: parent.width
            visible: overviewFlag.error !== ""
            text: overviewFlag.error
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Toggle {
            id: alttabToggle
            width: parent.width
            label: "Alt-Tab"
            checked: alttabFlag.enabled
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: alttabFlag.toggle()
            onHovered: function(isHovered) { alttabToggle.isHovering = isHovered }

            property bool isHovering: false

            PanelToolTip {
              visible: alttabToggle.isHovering
              text: root.alttabToggleHint
              fontFamily: root.fontFamily
            }
          }

          Text {
            width: parent.width
            visible: alttabFlag.error !== ""
            text: alttabFlag.error
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Toggle {
            id: workspaceToggle
            width: parent.width
            label: "Super+Tab"
            checked: workspaceFlag.enabled
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: workspaceFlag.toggle()
            onHovered: function(isHovered) { workspaceToggle.isHovering = isHovered }

            property bool isHovering: false

            PanelToolTip {
              visible: workspaceToggle.isHovering
              text: root.workspaceToggleHint
              fontFamily: root.fontFamily
            }
          }

          Text {
            width: parent.width
            visible: workspaceFlag.error !== ""
            text: workspaceFlag.error
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: root.dim
          opacity: hideHover.hovered ? 0.9 : 0.55
          text: root.widgetHidden ? "Show widget" : "Hide widget"
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setWidgetHidden(!root.widgetHidden)
          }
          HoverHandler { id: hideHover }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.RichText
          text: '<a href="https://github.com/paudelsamir/switcher#keyboard-shortcuts">Switcher controls</a>'
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          opacity: docsHover.hovered ? 0.9 : 0.55
          onLinkActivated: function(link) { Qt.openUrlExternally(link) }
          MouseArea { anchors.fill: parent; acceptedButtons: Qt.NoButton; cursorShape: Qt.PointingHandCursor }
          HoverHandler { id: docsHover }
        }
      }
    }
  }
}