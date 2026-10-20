pragma ComponentBehavior: Bound
import QtQuick
import "../services"
import "../widgets"

// Une carte flottante de FloatingWidgets : un en-tête qu'on attrape pour la
// déplacer, une croix, et le widget lui-même. Le widget n'existe que tant que
// la carte est ouverte (Loader) : fermé, il ne fait plus tourner ses
// processus (sondes matérielles, lecteur, micro de l'accordeur…).
Rectangle {
    id: card

    required property string name
    // Le widget à montrer, et sa taille. Une hauteur de 0 suit celle que le
    // widget demande (implicitHeight).
    property Component content: null
    property int contentWidth: 300
    property int contentHeight: 0
    // La taille de l'écran : la surface vaut 0 × 0 tant qu'aucune carte
    // n'est ouverte, elle ne peut pas servir à placer la première.
    property real areaWidth: 1280
    property real areaHeight: 720

    // Passe au premier plan quand on la touche.
    signal raised()

    readonly property bool open: Widgets.opened[card.name] === true
    readonly property int pad: 12
    readonly property int headerH: 30

    visible: open || opacity > 0
    opacity: open ? 1 : 0
    scale: open ? 1 : 0.96
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }

    width: contentWidth + pad * 2
    height: headerH + (loader.item ? loader.height : 0) + pad

    color: Theme.bgDeep
    radius: Theme.radius
    border.width: 1
    border.color: Theme.dividerColor

    // Placée à chaque ouverture : là où on l'a laissée, dans l'écran.
    onOpenChanged: {
        if (!open)
            return;
        var p = Widgets.position(card.name, card.width, card.height,
                                 card.areaWidth, card.areaHeight);
        card.x = p.x;
        card.y = p.y;
        card.raised();
    }

    // Le clavier, une fois la carte cliquée (la surface le prend à la
    // demande) : Tab parcourt ses contrôles, Échap la ferme.
    Keys.onEscapePressed: Widgets.apply(card.name, "fermer")

    // Avale les clics hors en-tête, et ramène la carte devant.
    MouseArea {
        anchors.fill: parent
        onPressed: card.raised()
    }

    // ── En-tête : titre, poignée, croix ──────────────────────────
    Item {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: card.headerH

        MouseArea {
            id: dragArea
            anchors.fill: parent
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: card
            drag.threshold: 2
            drag.minimumX: 0
            drag.minimumY: 0
            drag.maximumX: card.areaWidth - card.width
            drag.maximumY: card.areaHeight - card.height
            onPressed: card.raised()
            onReleased: Widgets.move(card.name, card.x, card.y)
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: card.pad + 2
            anchors.verticalCenter: parent.verticalCenter
            text: (Widgets.titles[card.name] || card.name).toUpperCase()
            font.family: "JetBrains Mono"
            font.pixelSize: 10
            font.letterSpacing: 1.5
            color: Theme.accentMuted
        }

        Rectangle {
            id: closeBtn
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            height: 20
            radius: 6
            color: closeMa.containsMouse || closeBtn.activeFocus ? Theme.hoverOverlay : "transparent"

            activeFocusOnTab: true
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    Widgets.apply(card.name, "fermer");
                    event.accepted = true;
                }
            }
            FocusRing { gap: 1 }

            NixIcon {
                anchors.centerIn: parent
                iconSize: 11
                source: "../assets/icons/close.svg"
                color: closeMa.containsMouse || closeBtn.activeFocus ? Theme.textPrimary : Theme.textDim
            }

            MouseArea {
                id: closeMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Widgets.apply(card.name, "fermer")
            }
        }
    }

    Loader {
        id: loader
        x: card.pad
        y: card.headerH
        width: card.contentWidth
        height: card.contentHeight > 0 ? card.contentHeight
                                       : (item ? item.implicitHeight : 0) // qmllint disable missing-property
        active: card.visible
        sourceComponent: card.content
    }
}
