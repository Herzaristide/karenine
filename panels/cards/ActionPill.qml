import QtQuick
import "../../services"

// Action nommée, sans contour : une pastille qui éclaircit la surface de la
// carte, et son libellé.
Item {
    id: pill

    property string label: ""
    property color tone: Theme.textSecondary

    signal triggered()

    implicitWidth: text.implicitWidth + 20
    implicitHeight: 23

    scale: pillTap.pressed ? 0.9 : 1.0
    Behavior on scale {
        NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.darkMode
               ? Qt.rgba(1, 1, 1, pillHover.hovered ? 0.20 : 0.10)
               : Qt.rgba(1, 1, 1, pillHover.hovered ? 0.85 : 0.62)

        Behavior on color { ColorAnimation { duration: 150 } }
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: pill.tone
        opacity: pillHover.hovered ? 0.22 : 0.0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }

    Text {
        id: text
        anchors.centerIn: parent
        text: pill.label
        color: pill.tone
        font.family: "JetBrains Mono"
        font.pixelSize: 10
    }

    HoverHandler {
        id: pillHover
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        id: pillTap
        onTapped: pill.triggered()
    }
}
