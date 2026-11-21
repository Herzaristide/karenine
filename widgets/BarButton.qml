import QtQuick
import "../services"

// Un bouton de la barre du bas : une icône de assets/ui sur le socle commun
// (BarPill : survol, accent, appui, éclat), qui change en fondu enchaîné
// (BarIcon). `badge` met un nombre en pastille dans le coin, qui
// éclot et sursaute à chaque changement ; `dot` un simple point (quelque
// chose attend).
BarPill {
    id: btn

    property string icon
    property color tint: Theme.iconColor
    property int badge: 0
    property bool dot: false
    property int size: 34

    implicitWidth: btn.size
    implicitHeight: btn.size
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    BarIcon {
        anchors.centerIn: parent
        icon: btn.icon
        color: btn.on ? Theme.accentColor : btn.tint
        iconOpacity: btn.on || btn.hovered ? 1 : 0.8
    }

    // ── Le nombre, en pastille dans le coin ; rien à zéro ──
    Rectangle {
        id: badgeBox
        readonly property bool shown: btn.badge > 0
        x: btn.width - width - 2
        y: 2
        width: Math.max(height, badgeText.implicitWidth + 8)
        height: 15
        radius: height / 2
        color: Theme.accentColor
        opacity: shown ? 1 : 0
        scale: shown ? bump : 0.3
        visible: opacity > 0
        transformOrigin: Item.Center
        property real bump: 1
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 2 } }
        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // Un nouveau nombre : un petit sursaut.
        SequentialAnimation {
            id: bumpAnim
            NumberAnimation { target: badgeBox; property: "bump"; to: 1.25; duration: 110; easing.type: Easing.OutCubic }
            NumberAnimation { target: badgeBox; property: "bump"; to: 1; duration: 320; easing.type: Easing.OutBack; easing.overshoot: 2 }
        }

        Text {
            id: badgeText
            anchors.centerIn: parent
            // Garde le dernier nombre pendant qu'elle s'efface.
            property int last: 0
            text: last > 99 ? "99+" : last
            font.family: "Inter"
            font.pixelSize: 9
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
            color: Theme.bgDeep
        }
    }
    onBadgeChanged: {
        if (btn.badge > 0) {
            if (badgeText.last > 0 && btn.badge !== badgeText.last)
                bumpAnim.restart();
            badgeText.last = btn.badge;
        }
    }
    Component.onCompleted: badgeText.last = btn.badge

    Rectangle {
        readonly property bool shown: btn.dot && btn.badge === 0
        x: btn.width - width - 4
        y: 4
        width: 8
        height: 8
        radius: 4
        color: Theme.accentColor
        border.width: 2
        border.color: Theme.bgDeep
        opacity: shown ? 1 : 0
        scale: shown ? 1 : 0.2
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Behavior on scale { NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 2.2 } }
    }
}
