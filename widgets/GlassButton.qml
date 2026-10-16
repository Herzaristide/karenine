import QtQuick
import "../services"

// Le bouton des widgets, dans le style de la barre de conversation : une
// pilule translucide posée sur le verre ; « accent » (le bouton principal, ou
// un état allumé) la teinte comme l'indicateur du micro et la pastille des
// onglets. Un léger tassement au clic, sans rebond.
Rectangle {
    id: btn

    property string text: ""
    property bool accent: false
    property int fontSize: 12
    signal clicked()

    implicitWidth: label.implicitWidth + 28
    implicitHeight: 34
    radius: height / 2

    color: btn.accent ? Qt.alpha(Theme.glow(0), btn.hovered ? 0.26 : 0.18)
                      : Qt.alpha(Theme.textPrimary, btn.hovered ? 0.1 : 0.06)
    border.width: 1
    border.color: btn.accent ? Qt.alpha(Theme.glow(0), 0.42) : Qt.alpha(Theme.textPrimary, 0.1)
    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }

    readonly property bool hovered: ma.containsMouse
    scale: ma.pressed ? 0.96 : 1
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Text {
        id: label
        anchors.centerIn: parent
        text: btn.text
        font.family: "Inter"
        font.pixelSize: btn.fontSize
        font.weight: Font.Medium
        color: btn.accent || btn.hovered ? Theme.textPrimary : Theme.textSecondary
        Behavior on color { ColorAnimation { duration: 160 } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
