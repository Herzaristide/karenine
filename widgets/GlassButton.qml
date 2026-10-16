import QtQuick
import "../services"

// Le bouton des widgets, dans le style de la barre de conversation : une
// pilule translucide posée sur le verre ; « accent » (le bouton principal, ou
// un état allumé) la teinte comme l'indicateur du micro et la pastille des
// onglets. Un léger tassement au clic, sans rebond. Au clavier, Tab y
// arrive, Entrée ou Espace l'actionne. Une icône (`icon`, un SVG blanc de
// assets/icons) peut précéder le texte, ou le remplacer : le bouton est alors
// rond.
Rectangle {
    id: btn

    property string text: ""
    property url icon
    property bool accent: false
    // Une action qui ne se rattrape pas (éteindre…) : teintée en rouge.
    property bool danger: false
    readonly property color tint: btn.danger ? Theme.colorDanger : Theme.glow(0)
    readonly property bool tinted: btn.accent || btn.danger
    property int fontSize: 12
    signal clicked()

    readonly property bool hasIcon: btn.icon.toString() !== ""
    readonly property bool iconOnly: btn.hasIcon && btn.text === ""
    readonly property color ink: btn.danger ? Theme.colorDanger
                               : btn.accent || btn.hovered ? Theme.textPrimary : Theme.textSecondary

    implicitHeight: 34
    implicitWidth: btn.iconOnly ? implicitHeight : content.implicitWidth + 28
    radius: height / 2

    color: btn.tinted ? Qt.alpha(btn.tint, btn.hovered ? 0.26 : 0.18)
                      : Qt.alpha(Theme.textPrimary, btn.hovered ? 0.1 : 0.06)
    border.width: 1
    border.color: btn.tinted ? Qt.alpha(btn.tint, 0.42) : Qt.alpha(Theme.textPrimary, 0.1)
    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }

    readonly property bool hovered: ma.containsMouse || btn.activeFocus
    scale: ma.pressed ? 0.96 : 1

    activeFocusOnTab: true
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            btn.clicked();
            event.accepted = true;
        }
    }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 6

        NixIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: btn.hasIcon
            source: btn.icon
            iconSize: Math.round(btn.height * 0.5)
            color: btn.ink
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: btn.text !== ""
            text: btn.text
            font.family: "Inter"
            font.pixelSize: btn.fontSize
            font.weight: Font.Medium
            color: btn.ink
            Behavior on color { ColorAnimation { duration: 160 } }
        }
    }

    FocusRing {}

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
