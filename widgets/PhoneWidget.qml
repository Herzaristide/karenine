pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
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

    // Le dernier relevé d'anna : { running, phones: [Phone…] }.
    property var snapshot: ({ running: true, phones: [] })
    // Reçu au moins une fois : avant, rien ne veut rien dire.
    property bool loaded: false
    // L'appareil montré, par son identifiant (gardé quand la liste change).
    property string selectedId: ""
    // Le retour de la dernière action (une erreur, ou « Envoyé »), effacé seul.
    property string feedback: ""

    readonly property var phones: root.snapshot.phones || []
    readonly property var phone: {
        for (var i = 0; i < root.phones.length; i++)
            if (root.phones[i].id === root.selectedId)
                return root.phones[i];
        return root.phones.length > 0 ? root.phones[0] : null;
    }
    readonly property bool connected: root.phone !== null && root.phone.paired && root.phone.reachable

    // ── Le relevé, en continu ────────────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg.phone !== undefined) {
                        root.snapshot = msg.phone;
                        root.loaded = true;
                    }
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"phone_watch"}\n');
        }
    }

    // Se connecte tant qu'il est affiché ; réessaie si anna n'est pas là.
    Timer {
        interval: 2000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!watchSock.connected) watchSock.connected = true
    }
    onVisibleChanged: if (!visible) watchSock.connected = false

    // ── Les actions ──────────────────────────────────────────────
    // Une à la fois, par le client d'anna ; les suivantes attendent.
    property var queue: []

    function act(action, arg, done) {
        if (!root.phone)
            return;
        var q = root.queue.slice();
        // L'écran se demande par le nom : scrcpy passe par adb, pas par KDE Connect.
        var target = action === "screen" ? root.phone.name : root.phone.id;
        q.push({ args: ["anna", "phone", action, target].concat(arg ? [arg] : []), done: done || "" });
        root.queue = q;
        root.next();
    }

    function next() {
        if (actionProc.running || root.queue.length === 0)
            return;
        var job = root.queue[0];
        root.queue = root.queue.slice(1);
        actionProc.done = job.done;
        actionProc.command = job.args;
        actionProc.running = true;
    }

    Process {
        id: actionProc
        property string done: ""
        stdout: StdioCollector { id: actionOut }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(actionOut.text);
                // L'écran : anna dit quoi lancer, le shell ouvre la fenêtre.
                if (r.ok && r.command)
                    Quickshell.execDetached(r.command);
                root.say(r.ok ? actionProc.done : (r.error || I18n.tr("common.failedSentence")));
            } catch (e) {
                root.say(I18n.tr("anna.noAnswer"));
            }
            root.next();
        }
    }

    function say(text) {
        root.feedback = text;
        if (text)
            feedbackTimer.restart();
    }

    Timer {
        id: feedbackTimer
        interval: 3500
        onTriggered: root.feedback = ""
    }

    // Au suivant, en boucle.
    function cycle() {
        if (root.phones.length < 2)
            return;
        var i = root.phones.indexOf(root.phone);
        root.selectedId = root.phones[(i + 1) % root.phones.length].id;
    }

    // ── Petits éléments ──────────────────────────────────────────
    function stateText(p) {
        if (!p.paired)
            return I18n.tr("phone.pairRequest");
        return p.reachable ? I18n.tr("phone.connected") : I18n.tr("phone.outOfReach");
    }

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
        radius: 18
        color: Qt.alpha(Theme.textPrimary, 0.05)
        border.width: 1
        border.color: Qt.alpha(Theme.textPrimary, 0.08)

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
                        onClicked: root.cycle()
                    }
                }
                Text {
                    text: root.phone ? root.stateText(root.phone) : ""
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
                    onClicked: root.act("accept", "", I18n.tr("phone.paired"))
                }
                GlassButton {
                    visible: root.phone !== null && !root.phone.paired
                    implicitHeight: 28
                    fontSize: 11
                    text: I18n.tr("phone.reject")
                    onClicked: root.act("reject", "", "")
                }

                GlassButton {
                    visible: root.connected
                    implicitHeight: 28
                    fontSize: 11
                    accent: true
                    text: I18n.tr("phone.screen")
                    onClicked: root.act("screen", "", I18n.tr("phone.openingScreen"))
                }
                GlassButton {
                    visible: root.connected
                    implicitHeight: 28
                    fontSize: 11
                    text: I18n.tr("phone.ring")
                    onClicked: root.act("ring", "", I18n.tr("phone.ringing"))
                }
                GlassButton {
                    visible: root.connected
                    implicitHeight: 28
                    fontSize: 11
                    text: I18n.tr("phone.clipboard")
                    onClicked: root.act("clipboard", "", I18n.tr("phone.clipboardSent"))
                }
            }

            // Le retour d'une action, ou ce qu'il faut faire ; la batterie.
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    text: root.feedback !== "" ? root.feedback
                        : root.phone !== null && !root.phone.paired
                          ? (root.phone.verification_key
                             ? I18n.tr("phone.checkKey", { key: root.phone.verification_key })
                             : I18n.tr("phone.acceptHint"))
                        : root.connected ? ""
                        : root.phone && root.phone.paired ? I18n.tr("phone.reachHint")
                        : ""
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: root.feedback !== "" ? Theme.textSecondary : Theme.textDim
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
                    text: root.connected ? I18n.tr("common.percent", { n: root.phone.battery }) + (root.phone.charging ? "  ⚡" : "") : ""
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    font.features: { "tnum": 1 }
                    color: root.connected && root.phone.battery <= 15 && !root.phone.charging
                           ? Theme.colorDanger : Theme.textPrimary
                }
            }
        }
    }

    // Rien à montrer : KDE Connect arrêté, ou aucun téléphone appairé.
    Text {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 520)
        visible: root.loaded && root.phone === null
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: !root.snapshot.running
              ? I18n.tr("phone.noDaemon")
              : I18n.tr("phone.nonePaired")
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }
}
