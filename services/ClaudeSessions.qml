pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les sessions Claude Code, telles qu'anna les suit (anna/src/claude/
// sessions.rs) : celles qui tournent — qui attend une réponse, qui
// travaille et à quoi — puis les dernières terminées. Toujours suivi, même
// panneau fermé : la barre du bas marque d'un point le bouton du panneau
// quand une session attend.
Singleton {
    id: root

    // [{ id, project, cwd, branch, title, state, activity, ask, asks, pid, updated }]
    // state : "waiting", "busy", "idle" ; "ended" pour les récentes.
    property var live: []
    property var recent: []
    property bool loaded: false

    readonly property int waiting: root.live.filter(s => s.state === "waiting").length

    // Le terminal de la session au premier plan.
    function focus(session) {
        if (session && session.pid > 0)
            Quickshell.execDetached(["anna", "claude", "focus", String(session.pid)]);
    }

    // La rouvrir dans un terminal, dans son dossier.
    function resume(session) {
        if (session)
            DefaultApps.runInTerminal(session.cwd, ["claude", "--resume", session.id]);
    }

    // Les demandes auxquelles on vient de répondre ({ "session/demande": true }) :
    // cachées sans attendre le prochain relevé d'anna.
    property var answered: ({})

    function asksOf(session) {
        return (session.asks || []).filter(a => !root.answered[session.id + "/" + a.id]);
    }

    // Répondre à une demande d'une session pilotée (session.asks).
    function answer(session, ask, action, values) {
        var key = session.id + "/" + ask;
        root._mark(key, true);
        ClaudeChat.answerFor(session.id, ask, action, values, (r) => {
            // Refusée : la demande, si elle tient toujours, se montre à nouveau.
            if (!r.ok)
                root._mark(key, false);
        });
    }

    function _mark(key, on) {
        var a = Object.assign({}, root.answered);
        if (on)
            a[key] = true;
        else
            delete a[key];
        root.answered = a;
    }

    // Les sessions épinglées (leurs ids), en tête de liste en permanence ;
    // gardées d'un démarrage à l'autre.
    readonly property var pins: pinPrefs.ids || [] // qmllint disable unqualified

    function isPinned(session) {
        return !!session && root.pins.indexOf(session.id) >= 0;
    }

    function togglePin(session) {
        if (!session || !session.id)
            return;
        var ids = root.pins.filter(id => id !== session.id);
        if (ids.length === root.pins.length)
            ids.unshift(session.id);
        pinPrefs.ids = ids; // qmllint disable unqualified
    }

    FileView {
        path: Quickshell.dataPath("claude-pins.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()

        JsonAdapter { // qmllint disable unresolved-type
            id: pinPrefs
            property var ids: []
        }
    }

    // Une nouvelle session dans un terminal, dans ce dossier.
    function startInTerminal(cwd) {
        if (cwd)
            DefaultApps.runInTerminal(cwd, ["claude"]);
    }

    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg.claude !== undefined) {
                        root.live = msg.claude.live || [];
                        root.recent = msg.claude.recent || [];
                        root.loaded = true;
                    }
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"claude_watch"}\n');
        }
    }

    // anna redémarré, ou pas encore là : on se reconnecte.
    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!watchSock.connected) watchSock.connected = true
    }
}
