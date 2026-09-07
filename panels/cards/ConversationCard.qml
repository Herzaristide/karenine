import QtQuick
import "../../services"

// Conversation Claude. Les sessions de Claude Desktop s'ouvrent dans l'app par
// claude://code/continue ; celles de Claude Code (CLI) n'ont pas d'équivalent
// côté app, donc on les reprend dans un terminal.
CardFrame {
    id: card

    required property var item

    readonly property bool isDesktop: card.item.payload.kind === "desktop"

    tone: card.item.tone
    title: card.item.title
    subtitle: card.item.subtitle
              + (card.item.meta.length > 0 ? "  ·  " + card.item.meta : "")

    onPrimaryActivated: Search.activate(card.item, card.isDesktop ? "open" : "resume")

    // Bulle de conversation.
    Item {
        anchors.centerIn: parent
        width: 20
        height: 20

        Rectangle {
            anchors.fill: parent
            anchors.bottomMargin: 5
            radius: 5
            color: card.tone
            opacity: 0.85
        }

        Rectangle {
            x: 4
            y: parent.height - 8
            width: 6
            height: 6
            rotation: 45
            color: card.tone
            opacity: 0.85
        }
    }

    actionContent: [
        ActionPill {
            label: card.isDesktop ? "claude" : "reprendre"
            tone: card.tone
            onTriggered: Search.activate(card.item, card.isDesktop ? "open" : "resume")
        },
        ActionPill {
            label: "id"
            tone: card.tone
            onTriggered: Search.activate(card.item, "copy")
        }
    ]
}
