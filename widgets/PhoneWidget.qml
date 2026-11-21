pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Le téléphone appairé avec KDE Connect, en bas de l'onglet « Système »
// (anna/src/phone.rs, relu toutes les 2 s). Sa carte, large et basse :
// l'état, le réseau mobile, la batterie, et ce qu'on peut lui demander ;
// « Écran » l'affiche dans une fenêtre (scrcpy, par adb : en USB, sinon par
// Tailscale). Les fichiers lui partent depuis l'Explorer (la sélection,
// bouton téléphone). Ses notifications arrivent comme les autres, par le
// serveur de notifications du shell (services/Notifications.qml).
//
//   ╭ ● Pixel 9a  Connecté  ·  5G ▂▄▆█        (Écran) (Faire sonner) (Presse-papier) ╮
//   ╰ Envoyé                                            ━━━━━━━━━━━━━━━━━━━━  82 % ⚡ ╯
//
// Un téléphone qui demande à s'appairer montre la clé de vérification (la
// même que sur son écran) et propose d'accepter ou de refuser. Plusieurs
// appareils : un clic sur le nom passe au suivant.
Item {
    id: root

    // L'état et les actions : services/Phone.qml, partagé avec la barre.
    readonly property var phone: Phone.phone
    readonly property var phones: Phone.phones
    readonly property bool connected: Phone.connected

    // ── Petits éléments ──────────────────────────────────────────
    // 0 à 4 barres, comme sur le téléphone.
    component SignalBars: Row {
        id: bars
        property int level: -1
        spacing: 2
        visible: bars.level >= 0
        Repeater {
            model: 4
            Rectangle {
                required property int index
                anchors.bottom: parent.bottom
                width: 3
                height: 4 + index * 2.5
                radius: 1
                color: index < bars.level ? Theme.textPrimary : Qt.alpha(Theme.textPrimary, 0.18)
            }
        }
    }

    // ── La carte du téléphone ────────────────────────────────────
    Rectangle {
        id: card
        visible: root.phone !== null
        width: root.width
        height: parent.height
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, 0.05)

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 10
            anchors.topMargin: 10
            anchors.bottomMargin: 10
            spacing: 6

            // Le nom, l'état, le réseau ; à droite, ce qu'on peut lui demander.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    implicitWidth: 8
                    implicitHeight: 8
                    radius: 4
                    color: !root.phone ? "transparent"
                         : !root.phone.paired ? Theme.colorWarning
                         : root.phone.reachable ? Theme.colorSuccess : Theme.colorDanger
                    Behavior on color { ColorAnimation { duration: 300 } }
                }
                Text {
                    Layout.maximumWidth: 220
                    text: root.phone ? root.phone.name + (root.phones.length > 1 ? "  ›" : "") : ""
                    font.family: "Inter"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: Theme.textPrimary
                    elide: Text.ElideRight
                    MouseArea {
                        anchors.fill: parent
                        enabled: root.phones.length > 1
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Phone.cycle()
                    }
                }
                Text {
                    text: root.phone ? Phone.stateText(root.phone) : ""
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textDim
                }
                Text {
                    visible: root.connected && root.phone.network !== ""
                    text: root.connected ? "·  " + root.phone.network : ""
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textDim
                }
                SignalBars {
                    Layout.alignment: Qt.AlignVCenter
                    level: root.connected ? root.phone.signal : -1
                }
                Item { Layout.fillWidth: true }

                // Demande d'appairage : accepter ou refuser.
                GlassButton {
                    visible: root.phone !== null && !root.phone.paired
                    implicitHeight: 28
                    fontSize: 11
                    accent: true
                    text: I18n.tr("phone.accept")
                    onClicked: Phone.act("accept", "", I18n.tr("phone.paired"))
                }
                GlassButton {
                    visible: root.phone !== null && !root.phone.paired
                    implicitHeight: 28
                    fontSize: 11
                    text: I18n.tr("phone.reject")
                    onClicked: Phone.act("reject", "", "")
                }

                GlassButton {
                    visible: root.connected
                    implicitHeight: 28
                    fontSize: 11
                    accent: true
                    text: I18n.tr("phone.screen")
                    onClicked: Phone.act("screen", "", I18n.tr("phone.openingScreen"))
                }
                GlassButton {
                    visible: root.connected
                    implicitHeight: 28
                    fontSize: 11
                    text: I18n.tr("phone.ring")
                    onClicked: Phone.act("ring", "", I18n.tr("phone.ringing"))
                }
                GlassButton {
                    visible: root.connected
                    implicitHeight: 28
                    fontSize: 11
                    text: I18n.tr("phone.clipboard")
                    onClicked: Phone.act("clipboard", "", I18n.tr("phone.clipboardSent"))
                }
            }

            // Le retour d'une action, ou ce qu'il faut faire ; la batterie.
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    text: Phone.feedback !== "" ? Phone.feedback
                        : root.phone !== null && !root.phone.paired
                          ? (root.phone.verification_key
                             ? I18n.tr("phone.checkKey", { key: root.phone.verification_key })
                             : I18n.tr("phone.acceptHint"))
                        : root.connected ? ""
                        : root.phone && root.phone.paired ? I18n.tr("phone.reachHint")
                        : ""
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Phone.feedback !== "" ? Theme.textSecondary : Theme.textDim
                    elide: Text.ElideRight
                }

                Rectangle {
                    visible: root.connected && root.phone.battery >= 0
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 5
                    Layout.alignment: Qt.AlignVCenter
                    radius: 2.5
                    color: Qt.alpha(Theme.textPrimary, 0.1)
                    Rectangle {
                        width: parent.width * (root.connected ? Math.max(0, Math.min(100, root.phone.battery)) / 100 : 0)
                        height: parent.height
                        radius: parent.radius
                        color: root.connected && root.phone.battery <= 15 && !root.phone.charging
                               ? Theme.colorDanger : Theme.colorSuccess
                        Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                    }
                }
                Text {
                    visible: root.connected && root.phone.battery >= 0
                    text: root.connected ? I18n.tr("common.percent", { n: root.phone.battery }) : ""
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    font.features: { "tnum": 1 }
                    color: root.connected && root.phone.battery <= 15 && !root.phone.charging
                           ? Theme.colorDanger : Theme.textPrimary
                }
                // L'éclair, le temps de la charge, du vert de la jauge.
                NixIcon {
                    visible: root.connected && root.phone.charging
                    Layout.alignment: Qt.AlignVCenter
                    iconSize: 12
                    source: "../assets/icons/bolt.svg"
                    color: Theme.colorSuccess
                }
            }
        }
    }

    // Rien à montrer : KDE Connect arrêté, ou aucun téléphone appairé.
    Text {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 520)
        visible: Phone.loaded && root.phone === null
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: !Phone.snapshot.running
              ? I18n.tr("phone.noDaemon")
              : I18n.tr("phone.nonePaired")
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }
}
