pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// Le téléphone appairé avec KDE Connect (anna/src/phone.rs, relu toutes les
// 2 s) : une seule source pour la barre (sa batterie, son volet) et la carte
// de l'onglet « Système » (widgets/PhoneWidget.qml). Les actions passent une
// à la fois par le client d'anna ; « Écran » l'affiche dans une fenêtre
// (scrcpy, par adb : en USB, sinon par Tailscale).
Singleton {
    id: root

    // Le dernier relevé d'anna : { running, phones: [Phone…] }.
    property var snapshot: ({ running: true, phones: [] })
    // Reçu au moins une fois : avant, rien ne veut rien dire.
    property bool loaded: false
    // L'appareil montré, par son identifiant (gardé quand la liste change).
    property string selectedId: ""
    // Le retour de la dernière action (une erreur, ou « Envoyé »), effacé seul.
    property string feedback: ""
    // Ce retour est une erreur (le volet de la barre ne montre qu'elles).
    property bool failed: false

    readonly property var phones: root.snapshot.phones || []
    readonly property var phone: {
        for (var i = 0; i < root.phones.length; i++)
            if (root.phones[i].id === root.selectedId)
                return root.phones[i];
        return root.phones.length > 0 ? root.phones[0] : null;
    }
    readonly property bool connected: root.phone !== null && root.phone.paired && root.phone.reachable
    // La batterie, -1 si elle n'est pas connue (ou le téléphone pas là).
    readonly property int battery: root.connected ? root.phone.battery : -1
    readonly property bool charging: root.connected && root.phone.charging
    readonly property bool low: root.battery >= 0 && root.battery <= 15 && !root.charging

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

    // Se reconnecte si anna n'est pas là (ou redémarre).
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!watchSock.connected) watchSock.connected = true
    }

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
                root.say(r.ok ? actionProc.done : (r.error || I18n.tr("common.failedSentence")), !r.ok);
            } catch (e) {
                root.say(I18n.tr("anna.noAnswer"), true);
            }
            root.next();
        }
    }

    function say(text, failed) {
        root.feedback = text;
        root.failed = !!failed;
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

    function stateText(p) {
        if (!p.paired)
            return I18n.tr("phone.pairRequest");
        return p.reachable ? I18n.tr("phone.connected") : I18n.tr("phone.outOfReach");
    }

    // Ce qu'il faut faire, quand rien d'autre n'est à dire.
    readonly property string hint: root.phone === null ? ""
        : !root.phone.paired
          ? (root.phone.verification_key
             ? I18n.tr("phone.checkKey", { key: root.phone.verification_key })
             : I18n.tr("phone.acceptHint"))
        : root.connected ? ""
        : I18n.tr("phone.reachHint")
}
