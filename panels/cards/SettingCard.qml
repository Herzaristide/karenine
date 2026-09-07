pragma ComponentBehavior: Bound
import QtQuick
import "../../services"

// Paramètre : la carte ne pointe pas vers un réglage, elle le pilote. Les
// commandes affichées dépendent du `control` déclaré par la source, donc
// ajouter un réglage d'un type déjà connu ne touche pas à ce fichier.
CardFrame {
    id: card

    required property var item

    readonly property string control: card.item.payload.control

    tone: card.item.tone
    title: card.item.title

    // Le sous-titre de la source est un instantané, pris au moment de la
    // recherche. Pour le volume — le seul réglage que la carte fait bouger elle-
    // même — on le relie à l'état réel, sinon le pourcentage resterait figé
    // pendant que les boutons, eux, réagissent.
    subtitle: card.control === "volume"
              ? (Audio.muted ? "coupé" : Audio.percent + " %")
              : card.item.subtitle

    // Rien à « ouvrir » sur un réglage piloté sur place : ce sont les commandes
    // qui agissent.
    tapEnabled: card.control === "toggle" || card.control === "action"
    onPrimaryActivated: Search.activate(card.item, "open")

    // Le sondage de wpctl ne tourne que tant qu'une carte volume est affichée.
    Component.onCompleted:   if (card.control === "volume") Audio.active = true
    Component.onDestruction: if (card.control === "volume") Audio.active = false

    // Curseur stylisé : trois barres, la hauteur suit le niveau.
    Item {
        anchors.centerIn: parent
        width: 20
        height: 20

        Repeater {
            model: 3

            Rectangle {
                required property int index

                width: 3
                radius: 1.5
                x: index * 8
                height: 7 + index * 6
                anchors.bottom: parent.bottom
                color: card.tone
                opacity: 0.85
            }
        }
    }

    actionContent: [
        ActionPill {
            visible: card.control === "volume"
            label: "−"
            tone: card.tone
            onTriggered: Search.activate(card.item, "down")
        },
        ActionPill {
            visible: card.control === "volume"
            label: Audio.muted ? "son" : "muet"
            tone: Audio.muted ? Theme.colorDanger : card.tone
            onTriggered: Search.activate(card.item, "mute")
        },
        ActionPill {
            visible: card.control === "volume"
            label: "+"
            tone: card.tone
            onTriggered: Search.activate(card.item, "up")
        },
        ActionPill {
            visible: card.control === "toggle"
            label: "basculer"
            tone: card.tone
            onTriggered: Search.activate(card.item, "toggle")
        },
        ActionPill {
            visible: card.control === "action"
            label: "ouvrir"
            tone: card.tone
            onTriggered: Search.activate(card.item, "open")
        },
        ActionPill {
            visible: card.control === "shot"
            label: "région"
            tone: card.tone
            onTriggered: Search.activate(card.item, "region")
        },
        ActionPill {
            visible: card.control === "shot"
            label: "écran"
            tone: card.tone
            onTriggered: Search.activate(card.item, "full")
        }
    ]
}
