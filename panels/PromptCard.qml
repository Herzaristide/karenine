import QtQuick
import QtQuick.Layouts
import "../services"

// La carte d'une demande faite à l'utilisateur, commune à polkit
// (PolkitPrompt) et aux autres (PromptHost : ssh, git, sudo…) :
//
//   ╭──────────────────────────────────────╮
//   │ <titre>                     <source> │
//   │ <ce qui est demandé>                 │
//   │ <détail, en chasse fixe>             │
//   │ <les champs : le contenu de la carte>│
//   │ <message>                            │
//   │                       <les boutons>  │
//   ╰──────────────────────────────────────╯
//
// Les champs sont les enfants de la carte ; les boutons, ceux de `buttons`.
Rectangle {
    id: card

    property bool shown: false
    property string title
    property string source
    property string text
    property string detail
    // Sous les champs : le retour (« mot de passe incorrect »), le délai…
    property string message
    property bool messageIsError: false
    // Le bord en rouge (un mot de passe refusé).
    property bool failed: false

    default property alias content: fields.data
    property alias buttons: buttonRow.data

    signal cancelled()

    width: 420
    implicitHeight: col.implicitHeight + 40
    radius: Theme.radius
    color: Theme.bgDeep
    border.width: 1
    border.color: card.failed ? Theme.colorDanger : Theme.dividerColor

    opacity: card.shown ? 1 : 0
    scale: card.shown ? 1 : 0.96
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    // Les clics sur la carte ne vont pas au voile.
    MouseArea { anchors.fill: parent }

    Keys.onEscapePressed: card.cancelled()

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 20
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: card.title
                font.family: "Inter"
                font.pixelSize: 15
                font.weight: Font.DemiBold
                color: Theme.textPrimary
                elide: Text.ElideRight
            }
            // Qui demande (« git › ssh »).
            Text {
                visible: text !== ""
                text: card.source
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Theme.textDim
                Layout.maximumWidth: 180
                elide: Text.ElideLeft
            }
        }

        // Ce que l'application demande, dans ses mots.
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: card.text
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textSecondary
            wrapMode: Text.Wrap
        }

        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: card.detail
            font.family: "JetBrains Mono"
            font.pixelSize: 10
            color: Theme.textDim
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 4
            elide: Text.ElideMiddle
        }

        ColumnLayout {
            id: fields
            Layout.fillWidth: true
            Layout.topMargin: children.length > 0 ? 4 : 0
            spacing: 8
        }

        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: card.message
            color: card.messageIsError ? Theme.colorDanger : Theme.textDim
            font.family: "Inter"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        RowLayout {
            id: buttonRow
            Layout.alignment: Qt.AlignRight
            Layout.topMargin: 4
            spacing: 8
        }
    }
}
