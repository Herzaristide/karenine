pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les demandes faites à l'utilisateur, telles qu'anna les tient
// (anna/src/prompts.rs) : la passphrase d'une clé SSH, un mot de passe git
// ou sudo, une confirmation… panels/PromptHost.qml les montre, une à la
// fois, la plus ancienne d'abord, et renvoie la réponse ici.
//
// Tant que ce suivi est branché, anna sait qu'un shell peut répondre ; sans
// lui, les demandes partent vers le dialogue standard (ksshaskpass…).
//
// Les réponses (des mots de passe) partent sur une connexion à elles et ne
// sont gardées nulle part.
Singleton {
    id: prompts

    // [{ id, kind, source, title, text, detail, fields, actions, deadline }]
    property var pending: []
    readonly property var current: prompts.pending.length > 0 ? prompts.pending[0] : null

    // `action` : l'id d'un bouton, ou "cancel" ; `values` : { clé: valeur }.
    function reply(id, action, values) {
        prompts._send({ cmd: "prompt_reply", id: id, action: action, values: values || {} });
        // Sans attendre anna : la carte suivante s'affiche tout de suite.
        prompts.pending = prompts.pending.filter((p) => p.id !== id);
    }

    function cancel(id) {
        prompts.reply(id, "cancel", {});
    }

    // ── Le suivi ─────────────────────────────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var r = JSON.parse(line);
                    if (r && r.prompts)
                        prompts.pending = r.prompts;
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"prompt_watch"}\n');
            else
                prompts.pending = [];
        }
    }

    // (Re)connexion tant que le daemon est absent, comme Recorder.qml.
    Timer {
        interval: 3000
        running: !watchSock.connected
        repeat: true
        onTriggered: watchSock.connected = true
    }
    Component.onCompleted: watchSock.connected = true

    // ── Les réponses ─────────────────────────────────────────────────
    property var _queue: []

    function _send(obj) {
        prompts._queue = prompts._queue.concat([JSON.stringify(obj)]);
        if (!reqSock.connected)
            reqSock.connected = true;
    }

    function _next() {
        prompts._queue = prompts._queue.slice(1);
        reqSock.connected = false;
        if (prompts._queue.length > 0)
            Qt.callLater(function () { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (_line) => prompts._next()
        }
        onConnectedChanged: {
            if (connected && prompts._queue.length > 0)
                write(prompts._queue[0] + "\n");
        }
    }
}
