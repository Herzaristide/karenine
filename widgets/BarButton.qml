import QtQuick
import "../services"

// Un bouton de la barre du bas : une icône de assets/ui, sans fond au
// repos ; le survol le révèle, et `on` (son volet ouvert) le teinte à
// l'accent. `badge` met un nombre en pastille dans le coin, `dot` un simple
// point (quelque chose attend).
Rectangle {
    id: btn

    property string icon
    property color tint: Theme.iconColor
    property bool on: false
    property int badge: 0
    property bool dot: false
    property int size: 34
    signal clicked(int button)

    implicitWidth: btn.size
    implicitHeight: btn.size
    radius: Theme.radiusSmall
    color: btn.on ? Theme.selectedFill : ma.containsMouse ? Theme.hoverOverlay : "transparent"
    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
    scale: ma.pressed ? 0.92 : 1
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    NixIcon {
        anchors.centerIn: parent
        iconSize: 18
        source: "../assets/ui/" + btn.icon
        color: btn.on ? Theme.accentColor : btn.tint
        opacity: btn.on || ma.containsMouse ? 1 : 0.8
        Behavior on color { ColorAnimation { duration: 180 } }
    }

    // Le nombre, en pastille dans le coin ; rien à zéro.
    Rectangle {
        visible: btn.badge > 0
        x: btn.width - width - 2
        y: 2
        width: Math.max(height, badgeText.implicitWidth + 8)
        height: 15
        radius: height / 2
        color: Theme.accentColor

        Text {
            id: badgeText
            anchors.centerIn: parent
            text: btn.badge > 99 ? "99+" : btn.badge
            font.family: "Inter"
            font.pixelSize: 9
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
            color: Theme.bgDeep
        }
    }

    Rectangle {
        visible: btn.dot && btn.badge === 0
        x: btn.width - width - 4
        y: 4
        width: 8
        height: 8
        radius: 4
        color: Theme.accentColor
        border.width: 2
        border.color: Theme.bgDeep
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => btn.clicked(mouse.button)
    }
}
