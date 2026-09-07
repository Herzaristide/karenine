import QtQuick
import "../../services"

// Web : un lien prêt à ouvrir, aucun appel réseau. Le bouton porte l'icône du
// navigateur réellement par défaut.
CardFrame {
    id: card

    required property var item

    tone: card.item.tone
    title: card.item.title
    subtitle: card.item.subtitle

    onPrimaryActivated: Search.activate(card.item, "open")

    // Globe, tracé sur la même grille que les autres glyphes.
    Item {
        anchors.centerIn: parent
        width: 20
        height: 20

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 1.4
            border.color: card.tone
        }

        Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: 1.4
            color: card.tone
        }

        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.5
            height: parent.height
            radius: width / 2
            color: "transparent"
            border.width: 1.4
            border.color: card.tone
        }
    }

    actionContent: [
        IconPill {
            iconSource: DefaultApps.browser ? DefaultApps.browser.icon : ""
            tone: card.tone
            onTriggered: Search.activate(card.item, "open")
        }
    ]
}
