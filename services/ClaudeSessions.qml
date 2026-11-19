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

    // [{ id, project, cwd, branch, title, state, activity, ask, pid, updated }]
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
