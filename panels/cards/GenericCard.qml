import QtQuick
import "../../services"

// Carte de repli : c'est elle qui s'affiche pour un type de résultat dont la
// carte dédiée n'a pas encore été écrite. Une nouvelle source rend donc quelque
// chose d'utilisable dès sa première ligne de code.
CardFrame {
    id: card

    property var item: null

    tone: card.item ? card.item.tone : Theme.accentColor
    title: card.item ? card.item.title : ""
    subtitle: card.item ? card.item.subtitle : ""

    onPrimaryActivated: if (card.item) Search.activate(card.item, "open")

    Rectangle {
        anchors.centerIn: parent
        width: 16
        height: 16
        radius: 5
        color: "transparent"
        border.width: 1.4
        border.color: card.tone
    }

    actionContent: [
        ActionPill {
            label: "ouvrir"
            tone: card.tone
            onTriggered: if (card.item) Search.activate(card.item, "open")
        }
    ]
}
