import QtQuick
import QtQuick.Effects

// A monochrome SVG icon tinted to the theme, the same treatment the NixOS
// flake gets in the LeftBar: the artwork ships white and is recolored here,
// so one file serves both light and dark.
Item {
    id: root

    property url source
    property color color: "#ffffff"
    property real iconSize: 18

    implicitWidth: iconSize
    implicitHeight: iconSize

    Image {
        id: img
        anchors.fill: parent
        source: root.source
        sourceSize.width: 64
        sourceSize.height: 64
        fillMode: Image.PreserveAspectFit
        smooth: true
        visible: false
    }

    MultiEffect {
        anchors.fill: img
        source: img
        colorization: 1.0
        colorizationColor: root.color
    }
}
