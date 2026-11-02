import QtQuick
import QtQuick.Layouts
import "../services"

// Le compte Google (services/Google.qml) : donner l'identifiant OAuth, se
// connecter, se déconnecter. Dans les réglages, et dans l'onglet Agenda tant
// qu'aucun compte n'est connecté.
//
//   pas d'identifiant   Crée un identifiant… (le mode d'emploi)
//                       [ ID client, ou chemin du JSON ] [ secret ] (Enregistrer)
//   pas de compte       (Se connecter avec Google)          (Changer l'identifiant)
//   en attente          Autorise karenine dans le navigateur…  (Rouvrir) (Annuler)
//   connecté            a@gmail.com                            (Déconnecter)
ColumnLayout {
    id: account

    spacing: 8

    // L'identifiant, à (re)donner : pas encore là, ou on le change.
    property bool editing: false
    readonly property bool askClient: Google.known && Google.problem === "" && !Google.connected
                                      && !Google.pending && (!Google.configured || account.editing)

    Component.onCompleted: Google.refresh()

    Connections {
        target: Google
        function onConfiguredChanged() { if (Google.configured) account.editing = false; }
    }

    // Un champ des réglages.
    component Field: Rectangle {
        id: field
        property alias text: input.text
        property string placeholder: ""
        property bool secret: false
        signal accepted()

        Layout.fillWidth: true
        Layout.preferredHeight: 34
        radius: Theme.radiusSmall
        color: Qt.alpha(Theme.textPrimary, input.activeFocus ? 0.09 : 0.05)
        border.color: input.activeFocus ? Qt.alpha(Theme.glow(0), 0.5) : Theme.dividerColor
        border.width: 1

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textPrimary
            echoMode: field.secret ? TextInput.Password : TextInput.Normal
            selectByMouse: true
            activeFocusOnTab: true
            clip: true
            onAccepted: field.accepted()
        }

        Text {
            anchors.fill: input
            verticalAlignment: Text.AlignVCenter
            visible: input.text === ""
            text: field.placeholder
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.placeholderColor
            elide: Text.ElideRight
        }
    }

    function saveClient() {
        if (clientId.text.trim() !== "")
            Google.setClient(clientId.text, clientSecret.text);
    }

    // ── L'identifiant OAuth ──────────────────────────────────────
    Text {
        Layout.fillWidth: true
        visible: account.askClient
        text: I18n.tr("google.clientHint")
        textFormat: Text.StyledText
        linkColor: Theme.glow(0)
        onLinkActivated: (link) => Qt.openUrlExternally(link)
        font.family: "Inter"
        font.pixelSize: 11
        color: Theme.textSecondary
        wrapMode: Text.Wrap
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: account.askClient

        Field {
            id: clientId
            Layout.preferredWidth: 3
            placeholder: I18n.tr("google.clientId")
            onAccepted: account.saveClient()
        }
        Field {
            id: clientSecret
            Layout.preferredWidth: 2
            secret: true
            placeholder: I18n.tr("google.clientSecret")
            onAccepted: account.saveClient()
        }
        GlassButton {
            accent: true
            text: I18n.tr("google.save")
            onClicked: account.saveClient()
        }
        GlassButton {
            visible: Google.configured
            text: I18n.tr("common.cancel")
            onClicked: account.editing = false
        }
    }

    // ── Pas de compte ────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: Google.known && Google.configured && !Google.connected && !Google.pending
                 && !account.editing && Google.problem === ""

        GlassButton {
            accent: true
            text: I18n.tr("google.connect")
            onClicked: Google.connect()
        }
        Item { Layout.fillWidth: true }
        GlassButton {
            text: I18n.tr("google.changeClient")
            onClicked: account.editing = true
        }
    }

    // ── En attente du navigateur ─────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: Google.pending

        Text {
            Layout.fillWidth: true
            text: I18n.tr("google.pending")
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textPrimary
            wrapMode: Text.Wrap
        }
        GlassButton {
            visible: Google.loginUrl !== ""
            text: I18n.tr("google.reopen")
            onClicked: Google.reopen()
        }
        GlassButton {
            text: I18n.tr("common.cancel")
            onClicked: Google.cancel()
        }
    }

    // ── Connecté ─────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: Google.connected

        Text {
            Layout.fillWidth: true
            text: Google.email
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: Theme.textPrimary
            elide: Text.ElideRight
        }

        GlassButton {
            danger: true
            text: I18n.tr("google.disconnect")
            onClicked: Google.disconnect()
        }
    }

    // ── Ce qui se passe ──────────────────────────────────────────
    Text {
        Layout.fillWidth: true
        visible: text !== ""
        text: Google.problem !== "" ? Google.problem
            : Google.clientError !== "" && account.askClient ? Google.clientError
            : Google.loginState === "error" ? Google.loginError
            : Google.connected ? I18n.tr("google.connectedHint")
            : Google.known && Google.configured && !Google.pending && !account.editing ? I18n.tr("google.hint")
            : ""
        font.family: "Inter"
        font.pixelSize: 11
        color: Google.problem !== "" || Google.loginState === "error" || (Google.clientError !== "" && account.askClient)
               ? Theme.colorDanger : Theme.textDim
        wrapMode: Text.Wrap
    }
}
