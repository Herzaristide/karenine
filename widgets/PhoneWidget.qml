pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

// L'onglet « Téléphone » : le téléphone appairé avec KDE Connect
// (anna/src/phone.rs, relu toutes les 2 s). À gauche, sa carte : batterie,
// réseau mobile, et ce qu'on peut lui demander ; un fichier déposé dessus
// lui est envoyé ; « Écran » l'affiche dans une fenêtre (scrcpy, par adb :
// en USB, sinon par Tailscale). À droite, ses notifications, la plus récente
// en haut.
//
//   ╭ ● Pixel 9a        82 % ⚡ ╮ ╭ WhatsApp · Marie             ✕ ╮
//   │ Connecté  ·  5G  ▂▄▆█    │ │ On se voit à 19 h ?            │
//   │ (Écran) (Faire sonner)    │ │ Gmail · Facture d'octobre    ✕ │
//   │ (Fichiers) (Presse-papier)│ │ …                              │
//   │ Dépose un fichier ici     │ │                                │
//   ╰───────────────────────────╯ ╰────────────────────────────────╯
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

    readonly property int cardW: 300

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
                root.say(r.ok ? actionProc.done : (r.error || "Échec."));
            } catch (e) {
                root.say("anna ne répond pas.");
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
            return "Demande à s'appairer";
        return p.reachable ? "Connecté" : "Hors de portée";
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
        width: root.cardW
        height: parent.height
        radius: 18
        color: drop.containsDrag ? Qt.alpha(Theme.glow(0), 0.14) : Qt.alpha(Theme.textPrimary, 0.05)
        border.width: 1
        border.color: drop.containsDrag ? Qt.alpha(Theme.glow(0), 0.5) : Qt.alpha(Theme.textPrimary, 0.08)
        Behavior on color { ColorAnimation { duration: 160 } }

        // Un fichier déposé (depuis Dolphin…) part vers le téléphone.
        DropArea {
            id: drop
            anchors.fill: parent
            enabled: root.connected
            onDropped: (event) => {
                for (var i = 0; i < event.urls.length; i++)
                    root.act("share", event.urls[i].toString(), "Envoyé.");
                event.accept();
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 6

            // Le nom, la batterie.
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
                    Layout.fillWidth: true
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
                    visible: root.connected && root.phone.battery >= 0
                    text: root.connected ? root.phone.battery + " %" + (root.phone.charging ? "  ⚡" : "") : ""
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: root.connected && root.phone.battery <= 15 && !root.phone.charging
                           ? Theme.colorDanger : Theme.textPrimary
                }
            }

            // L'état, le réseau mobile.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
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
            }

            // La batterie, en barre.
            Rectangle {
                Layout.fillWidth: true
                visible: root.connected && root.phone.battery >= 0
                Layout.preferredHeight: 5
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

            // Demande d'appairage : la clé, à comparer avec le téléphone.
            Text {
                Layout.fillWidth: true
                visible: root.phone !== null && !root.phone.paired
                text: root.phone && root.phone.verification_key
                      ? "Vérifie que le téléphone affiche la clé " + root.phone.verification_key + "."
                      : "Accepte pour relier ce téléphone à l'ordinateur."
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textSecondary
                wrapMode: Text.Wrap
            }

            Item { Layout.fillHeight: true }

            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: root.phone !== null && !root.phone.paired

                GlassButton {
                    implicitHeight: 28
                    fontSize: 11
                    accent: true
                    text: "Accepter"
                    onClicked: root.act("accept", "", "Appairé.")
                }
                GlassButton {
                    implicitHeight: 28
                    fontSize: 11
                    text: "Refuser"
                    onClicked: root.act("reject", "", "")
                }
            }

            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: root.connected

                GlassButton {
                    implicitHeight: 28
                    fontSize: 11
                    accent: true
                    text: "Écran"
                    onClicked: root.act("screen", "", "Ouverture de l'écran…")
                }
                GlassButton {
                    implicitHeight: 28
                    fontSize: 11
                    text: "Faire sonner"
                    onClicked: root.act("ring", "", "Le téléphone sonne.")
                }
                GlassButton {
                    implicitHeight: 28
                    fontSize: 11
                    text: "Fichiers"
                    onClicked: root.act("browse", "", "")
                }
                GlassButton {
                    implicitHeight: 28
                    fontSize: 11
                    text: "Presse-papier"
                    onClicked: root.act("clipboard", "", "Presse-papier envoyé.")
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.feedback !== "" ? root.feedback
                    : root.connected ? "Dépose un fichier ici pour l'envoyer."
                    : root.phone && root.phone.paired ? "Même réseau, et KDE Connect ouvert sur le téléphone."
                    : ""
                font.family: "Inter"
                font.pixelSize: 10
                color: root.feedback !== "" ? Theme.textSecondary : Theme.textDim
                elide: Text.ElideRight
            }
        }
    }

    // ── Les notifications ────────────────────────────────────────
    ListView {
        id: notes
        visible: root.connected
        x: root.cardW + 10
        width: root.width - x
        height: parent.height
        spacing: 6
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.connected ? root.phone.notifications : []

        delegate: Rectangle {
            id: note
            required property var modelData
            width: notes.width
            height: noteCol.implicitHeight + 16
            radius: 14
            color: Qt.alpha(Theme.textPrimary, 0.05)
            border.width: 1
            border.color: Qt.alpha(Theme.textPrimary, 0.08)

            ColumnLayout {
                id: noteCol
                anchors.left: parent.left
                anchors.right: dismiss.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 12
                anchors.rightMargin: 6
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: [note.modelData.app, note.modelData.title].filter(t => t).join("  ·  ")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    color: Theme.textPrimary
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: note.modelData.text
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textSecondary
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                }
            }

            GlassButton {
                id: dismiss
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                visible: note.modelData.dismissable
                implicitHeight: 24
                implicitWidth: 24
                fontSize: 11
                text: "✕"
                onClicked: root.act("dismiss", note.modelData.id, "")
            }
        }

        Text {
            anchors.centerIn: parent
            visible: notes.count === 0
            text: "Aucune notification."
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textSecondary
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
              ? "KDE Connect n'est pas lancé (kdeconnectd)."
              : "Aucun téléphone appairé. Installe KDE Connect sur le téléphone (F-Droid ou Play Store), "
                + "sur le même Wi-Fi, puis appaire-le avec cet ordinateur."
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }
}
