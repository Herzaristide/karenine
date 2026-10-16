pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"

// Les serveurs suivis par anna, dans les réglages : la liste, de quoi en
// retirer un, et de quoi en ajouter. L'onglet « Serveurs » (ServersWidget)
// n'affiche que leurs relevés. Ceux de ~/.ssh/config y sont d'office ; les
// autres vivent dans ~/.config/anna/servers.json (aussi : `anna servers add
// <nom> [hôte]`). Retirer un serveur du ssh config le masque seulement.
ColumnLayout {
    id: root

    spacing: 6

    // [{ name, host }]
    property var servers: []
    property string errorText: ""

    // ── Une commande, une réponse : la liste à jour, ou l'erreur ─
    property string pending: ""

    function send(cmd) {
        root.pending = JSON.stringify(cmd) + "\n";
        cmdSock.connected = false;
        cmdSock.connected = true;
    }

    Socket {
        id: cmdSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var r = JSON.parse(line);
                    if (Array.isArray(r)) {
                        root.servers = r;
                        root.errorText = "";
                        nameField.text = "";
                        hostField.text = "";
                    } else if (r && r.ok === false) {
                        root.errorText = r.error;
                    }
                } catch (e) { /* ligne partielle */ }
                cmdSock.connected = false;
            }
        }
        onConnectedChanged: {
            if (connected && root.pending !== "") {
                write(root.pending);
                root.pending = "";
            }
        }
    }

    // Relue à chaque ouverture : elle a pu changer depuis la ligne de commande.
    onVisibleChanged: if (visible) root.send({ cmd: "servers_list" })
    Component.onCompleted: root.send({ cmd: "servers_list" })

    function add() {
        var name = nameField.text.trim();
        if (name === "")
            return;
        root.send({ cmd: "servers_add", name: name, host: hostField.text.trim() || name });
    }

    component Field: Rectangle {
        id: field
        property alias text: input.text
        property string placeholder
        signal accepted()

        Layout.fillWidth: true
        implicitHeight: 32
        radius: height / 2
        color: Qt.alpha(Theme.textPrimary, input.activeFocus ? 0.09 : 0.06)
        border.width: 1
        border.color: input.activeFocus ? Qt.alpha(Theme.glow(0), 0.45) : Qt.alpha(Theme.textPrimary, 0.1)
        Behavior on border.color { ColorAnimation { duration: 160 } }

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            verticalAlignment: TextInput.AlignVCenter
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textPrimary
            selectByMouse: true
            clip: true
            onAccepted: field.accepted()
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            text: field.placeholder
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textDim
        }
    }

    Text {
        Layout.bottomMargin: 4
        text: "Serveurs"
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.accentMuted
    }

    // ── Les serveurs suivis ──────────────────────────────────────
    Repeater {
        model: root.servers

        delegate: Rectangle {
            id: row
            required property var modelData

            Layout.fillWidth: true
            Layout.preferredHeight: 46
            radius: 14
            color: Qt.alpha(Theme.textPrimary, 0.05)
            border.color: Qt.alpha(Theme.textPrimary, 0.08)
            border.width: 1

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.right: removeBtn.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: row.modelData.name
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: row.modelData.from_ssh ? "depuis ~/.ssh/config" : row.modelData.host
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textSecondary
                    elide: Text.ElideRight
                }
            }

            Text {
                id: removeBtn
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "×"
                font.pixelSize: 15
                color: removeMa.containsMouse ? Theme.textPrimary : Theme.textDim
                MouseArea {
                    id: removeMa
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.send({ cmd: "servers_remove", name: row.modelData.name })
                }
            }
        }
    }

    // ── Ajouter ──────────────────────────────────────────────────
    Field {
        id: nameField
        Layout.topMargin: root.servers.length > 0 ? 4 : 0
        placeholder: "nom (ex. gary)"
        onAccepted: hostField.forceActiveFocus()
    }
    Field {
        id: hostField
        placeholder: "hôte ssh (vide : le nom)"
        onAccepted: root.add()
    }
    Text {
        Layout.fillWidth: true
        visible: root.errorText !== ""
        text: root.errorText
        font.family: "Inter"
        font.pixelSize: 10
        color: Theme.colorDanger
        elide: Text.ElideRight
    }
    GlassButton {
        Layout.fillWidth: true
        implicitHeight: 30
        accent: true
        text: "Ajouter un serveur"
        onClicked: root.add()
    }
}
