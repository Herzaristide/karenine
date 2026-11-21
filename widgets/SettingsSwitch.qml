import QtQuick
import "../services"

// Un interrupteur des réglages : l'accent quand il est mis, le bouton qui
// glisse sur un ressort.
Rectangle {
    id: sw

    property bool checked: false
    signal toggled()

    implicitWidth: 40
    implicitHeight: 22
    radius: height / 2
    color: sw.checked ? Theme.accentColor : Qt.alpha(Theme.textPrimary, 0.16)
    Behavior on color { ColorAnimation { duration: 200 } }

    Rectangle {
        y: 3
        x: sw.checked ? sw.width - width - 3 : 3
        width: 16
        height: 16
        radius: 8
        color: sw.checked ? Theme.bgDeep : Theme.textPrimary
        Behavior on x { SpringAnimation { spring: 6; damping: 0.4; epsilon: 0.2 } }
        Behavior on color { ColorAnimation { duration: 200 } }
    }

    MouseArea {
        anchors.fill: parent
        anchors.margins: -6
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled()
    }
}
