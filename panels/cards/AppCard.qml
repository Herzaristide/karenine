import QtQuick
import Quickshell
import "../../services"

// Application : son icône de thème, son nom, une seule action — la carte
// elle-même. Pas de bouton, il n'y aurait qu'à répéter le geste.
CardFrame {
    id: card

    required property var item

    tone: card.item.tone
    title: card.item.title
    subtitle: card.item.subtitle
    iconSource: {
        var e = card.item.payload.entry;
        return e && e.icon ? Quickshell.iconPath(e.icon, true) : "";
    }

    onPrimaryActivated: Search.activate(card.item, "open")

    // Repli quand le thème d'icônes ne connaît pas l'application.
    Rectangle {
        anchors.centerIn: parent
        width: 30
        height: 30
        radius: 8
        color: Qt.rgba(card.tone.r, card.tone.g, card.tone.b, 0.18)

        Text {
            anchors.centerIn: parent
            text: card.title.substring(0, 1).toUpperCase()
            color: card.tone
            font.family: "JetBrains Mono"
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }
    }
}
