import QtQuick
import qs.Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real colH: root.iconSize * 0.86
  readonly property real gap: Math.max(1, root.iconSize * 0.09)
  readonly property real sideW: root.iconSize * 0.2
  readonly property real midW: Math.max(1, root.iconSize - sideW * 2 - gap * 2)
  readonly property real rad: Math.max(1, root.iconSize * 0.12)

  Column1 {
    x: 0
    width: root.sideW
    opacity: 0.35
  }

  Column1 {
    x: root.sideW + root.gap
    width: root.midW
  }

  Column1 {
    x: root.iconSize - root.sideW
    width: root.sideW
    opacity: 0.35
  }

  component Column1: Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    height: root.colH
    radius: root.rad
    color: root.color
  }
}
