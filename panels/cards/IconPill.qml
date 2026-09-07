import QtQuick
import "../../services"

// Bouton d'action iconique, sans contour : l'icône de l'application réellement
// résolue, posée sur une pastille qui éclaircit la surface de la carte.
Item {
    id: pill

    property string iconSource: ""
    property color tone: Theme.textSecondary

    // De quoi dessiner un glyphe quand aucune application n'est en jeu.
    default property alias content: slot.data

    signal triggered()

    implicitWidth: 27
    implicitHeight: 27

    scale: pillTap.pressed ? 0.86 : (pillHover.hovered ? 1.08 : 1.0)

    Behavior on scale {
        NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
    }

    Rectangle {
        anchors.fill: parent
        radius: 9
        color: Theme.darkMode
               ? Qt.rgba(1, 1, 1, pillHover.hovered ? 0.20 : 0.10)
               : Qt.rgba(1, 1, 1, pillHover.hovered ? 0.85 : 0.62)

        Behavior on color { ColorAnimation { duration: 150 } }
    }

    Rectangle {
        anchors.fill: parent
        radius: 9
        color: pill.tone
        opacity: pillHover.hovered ? 0.22 : 0.0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }

    Image {
        anchors.centerIn: parent
        width: 17
        height: 17
        source: pill.iconSource
        visible: pill.iconSource.length > 0
        sourceSize.width: 17
        sourceSize.height: 17
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    Item {
        id: slot
        anchors.fill: parent
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
