import QtQuick
import QtQuick.Layouts
import "../services"

// Le compte Nextcloud (services/Cloud.qml) : le connecter, voir où en est la
// synchro des notes, le déconnecter. Dans les réglages, et dans l'onglet
// Agenda tant qu'aucun compte n'est connecté.
//
//   pas de compte    [ https://murena.io        ] (Connecter)
//   en attente       Autorise karenine dans le navigateur…  (Rouvrir) (Annuler)
//   connecté         a@murena.io · murena.io                (Déconnecter)
//                    Notes synchronisées il y a 2 min
ColumnLayout {
    id: account

    spacing: 8

    Component.onCompleted: Cloud.refresh()

    // « il y a 2 min », relu chaque minute.
    property int now: Math.floor(Date.now() / 1000)
    Timer {
        interval: 60000
        repeat: true
        running: account.visible && Cloud.connected
        onTriggered: {
            account.now = Math.floor(Date.now() / 1000);
            Cloud.refresh();
        }
    }

    function ago(secs) {
        var m = Math.max(0, Math.round((account.now - secs) / 60));
        return m < 1 ? I18n.tr("cloud.justNow") : I18n.trn("cloud.minutesAgo", m, { n: m });
    }

    // ── Pas de compte ────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: Cloud.known && !Cloud.connected && !Cloud.pending && Cloud.problem === ""

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            radius: Theme.radiusSmall
            color: Qt.alpha(Theme.textPrimary, serverInput.activeFocus ? 0.09 : 0.05)
            border.color: serverInput.activeFocus ? Qt.alpha(Theme.glow(0), 0.5) : Theme.dividerColor
            border.width: 1

            TextInput {
                id: serverInput
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textPrimary
                selectByMouse: true
                activeFocusOnTab: true
                clip: true
                onAccepted: Cloud.connect(serverInput.text)
            }

            Text {
                anchors.fill: serverInput
                verticalAlignment: Text.AlignVCenter
                visible: serverInput.text === ""
                text: Cloud.defaultServer
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.placeholderColor
                elide: Text.ElideRight
            }
        }

        GlassButton {
            accent: true
            text: I18n.tr("cloud.connect")
            onClicked: Cloud.connect(serverInput.text)
        }
    }

    // ── En attente du navigateur ─────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: Cloud.pending

        Text {
            Layout.fillWidth: true
            text: I18n.tr("cloud.pending")
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textPrimary
            wrapMode: Text.Wrap
        }
        GlassButton {
            visible: Cloud.loginUrl !== ""
            text: I18n.tr("cloud.reopen")
            onClicked: Cloud.reopen()
        }
        GlassButton {
            text: I18n.tr("common.cancel")
            onClicked: Cloud.cancel()
        }
    }

    // ── Connecté ─────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: Cloud.connected

        Column {
            Layout.fillWidth: true
            spacing: 2

            Text {
                width: parent.width
                text: Cloud.user
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textPrimary
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: Cloud.server.replace(/^https?:\/\//, "")
                font.family: "Inter"
                font.pixelSize: 10
                color: Theme.textSecondary
                elide: Text.ElideRight
            }
        }

        GlassButton {
            danger: true
            text: I18n.tr("cloud.disconnect")
            onClicked: Cloud.disconnect()
        }
    }

    // ── Ce qui se passe ──────────────────────────────────────────
    Text {
        Layout.fillWidth: true
        visible: text !== ""
        text: Cloud.problem !== "" ? Cloud.problem
            : Cloud.loginState === "error" ? Cloud.loginError
            : Cloud.connected ? (Cloud.notesError !== "" ? I18n.tr("cloud.notesFailed", { error: Cloud.notesError })
                               : Cloud.notesLast > 0 ? I18n.tr("cloud.notesSynced", { when: account.ago(Cloud.notesLast) })
                               : I18n.tr("cloud.notesSoon"))
            : Cloud.known && !Cloud.pending ? I18n.tr("cloud.hint")
            : ""
        font.family: "Inter"
        font.pixelSize: 11
        color: Cloud.problem !== "" || Cloud.loginState === "error" || (Cloud.connected && Cloud.notesError !== "")
               ? Theme.colorDanger : Theme.textDim
        wrapMode: Text.Wrap
    }
}
