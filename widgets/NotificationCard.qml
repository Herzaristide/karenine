pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Notifications
import "../services"

// Une notification, dans l'onglet « Notifications » : l'icône
// (ou l'image qu'elle porte), l'application et l'heure, le titre, le texte,
// puis ses actions et, si l'application le permet, un champ pour répondre
// (un SMS reçu par KDE Connect…).
//
//   ╭──────────────────────────────────────────╮
//   │ [ic]  Firefox  ·  14:02               ✕  │
//   │       Téléchargement terminé             │
//   │       rapport.pdf                        │
//   │       (Ouvrir) (Afficher le dossier)     │
//   ╰──────────────────────────────────────────╯
//
// Un clic dessus lance son action par défaut ; ✕ la ferme pour de bon.
Rectangle {
    id: card

    required property var notification

    // Ce que la carte affiche, lu une fois. Une notification fermée est
    // détruite avant sa carte : les liaisons la voient un instant nulle.
    readonly property var n: card.notification || null
    readonly property bool critical: card.n !== null && card.n.urgency === NotificationUrgency.Critical
    readonly property string header: card.n ? [card.n.appName, Notifications.time(card.n)].filter(t => t).join("  ·  ") : ""
    readonly property string summary: card.n ? card.n.summary : ""
    readonly property string body: card.n ? card.n.body : ""
    readonly property bool canReply: card.n !== null && card.n.hasInlineReply
    readonly property string replyPlaceholder: card.n ? card.n.inlineReplyPlaceholder : ""

    implicitHeight: content.implicitHeight + 20
    radius: 14
    color: Qt.alpha(Theme.textPrimary, hover.hovered ? 0.08 : 0.05)
    border.width: 1
    border.color: card.critical ? Qt.alpha(Theme.colorDanger, 0.6) : Qt.alpha(Theme.textPrimary, 0.08)
    Behavior on color { ColorAnimation { duration: 140 } }

    HoverHandler { id: hover }

    // Sous le contenu : les boutons, posés par-dessus, gardent leurs clics.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton)
                Notifications.dismiss(card.notification);
            else
                Notifications.activate(card.notification);
        }
    }

    RowLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 10
        spacing: 10

        // L'icône, ou l'image (un avatar, un aperçu de capture).
        Item {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: 36
            Layout.preferredHeight: 36
            visible: icon.source.toString() !== "" && icon.status !== Image.Error

            Image {
                id: icon
                anchors.fill: parent
                source: Notifications.iconOf(card.notification)
                sourceSize.width: 72
                sourceSize.height: 72
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    text: card.header
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }

                Text {
                    text: "✕"
                    font.pixelSize: 11
                    color: closeMa.containsMouse ? Theme.textPrimary : Theme.textDim

                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Notifications.dismiss(card.notification)
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: card.summary
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                color: Theme.textPrimary
            }

            // Le texte : un peu de balisage (gras, italique, liens), permis
            // par le serveur.
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: card.body
                textFormat: Text.StyledText
                wrapMode: Text.Wrap
                maximumLineCount: 6
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textSecondary
                linkColor: Theme.glow(0.05)
                onLinkActivated: (link) => Qt.openUrlExternally(link)
            }

            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 3
                visible: actions.count > 0
                spacing: 6

                Repeater {
                    id: actions
                    model: Notifications.actionsOf(card.notification)

                    GlassButton {
                        required property var modelData
                        implicitHeight: 24
                        fontSize: 10
                        text: modelData.text
                        onClicked: Notifications.invoke(card.notification, modelData)
                    }
                }
            }

            // Répondre sur place.
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 3
                visible: card.canReply
                implicitHeight: 28
                radius: 14
                color: Qt.alpha(Theme.textPrimary, 0.06)
                border.width: 1
                border.color: replyInput.activeFocus ? Qt.alpha(Theme.glow(0), 0.5) : Qt.alpha(Theme.textPrimary, 0.1)

                TextInput {
                    id: replyInput
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    clip: true
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textPrimary
                    selectByMouse: true
                    onAccepted: {
                        if (text.trim() === "")
                            return;
                        Notifications.reply(card.notification, text);
                        text = "";
                    }
                    Keys.onEscapePressed: focus = false

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: replyInput.text === "" && !replyInput.activeFocus
                        text: card.replyPlaceholder || I18n.tr("notifications.reply")
                        elide: Text.ElideRight
                        font: replyInput.font
                        color: Theme.textDim
                    }
                }
            }
        }
    }
}
