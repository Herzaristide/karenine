pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les enregistrements, tels qu'anna les tient (anna/src/recorder.rs) : le
// micro (onglet Musique) et l'écran (barre du haut). anna lance ffmpeg ou
// gpu-screen-recorder et les garde : un enregistrement survit à la barre qui
// se ferme, à l'onglet qu'on quitte et aux rechargements du shell. Les mêmes
// commandes partent des raccourcis (`anna record …`).
//
// Une socket longue suit l'état (`record_watch`) ; les demandes passent par
// une seconde, une commande par connexion, comme Gesture.qml.
Singleton {
    id: rec

    // Le daemon parle record_* (un anna plus ancien répond par une erreur).
    property bool available: false
    // { mode, since (ms Unix), path }, ou null quand rien n'enregistre.
    property var audio: null
    property var screen: null
    property string error: ""
    // Le dernier fichier enregistré.
    property string last: ""

    readonly property bool audioOn: rec.audio !== null
    readonly property bool screenOn: rec.screen !== null

    // L'heure, à la seconde, tant qu'un enregistrement tourne : le temps
    // écoulé se recalcule dessus.
    property double now: Date.now()
    Timer {
        interval: 1000
        repeat: true
        running: rec.audioOn || rec.screenOn
        triggeredOnStart: true
        onTriggered: rec.now = Date.now()
    }

    // « 1:05 », « 1:02:09 » : depuis le début de `track`.
    function elapsed(track) {
        if (!track)
            return "";
        var s = Math.max(0, Math.floor((rec.now - track.since) / 1000));
        var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60;
        var pad = (n) => (n < 10 ? "0" : "") + n;
        return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(sec);
    }

    // `mode` : "mic" ou "mix" (avec le son de l'ordinateur).
    function toggleAudio(mode) {
        rec._send({ cmd: "record_toggle", kind: "audio", mode: mode || "" });
    }

    // `mode` : "area" (une région) ou "screen" (l'écran qui a le focus).
    function toggleScreen(mode) {
        rec._send({ cmd: "record_toggle", kind: "screen", mode: mode || "" });
    }

    function stop(kind) {
        rec._send(kind ? { cmd: "record_stop", kind: kind } : { cmd: "record_stop" });
    }

    function _apply(s) {
        rec.available = true;
        rec.audio = s.audio || null;
        rec.screen = s.screen || null;
        rec.error = s.error || "";
        rec.last = s.last || "";
        rec.now = Date.now();
    }

    // ── Le suivi ─────────────────────────────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var r = JSON.parse(line);
                    if (r && r.record)
                        rec._apply(r.record);
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"record_watch"}\n');
            else
                rec.available = false;
        }
    }

    // (Re)connexion tant que le daemon est absent : il redémarre avec la
    // session. Jamais tout de suite après une fermeture : un anna qui ne
    // connaît pas record_watch répond par une erreur et ferme, et reconnecter
    // aussitôt bouclerait sans fin. La première connexion part à la création.
    Timer {
        interval: 3000
        running: !watchSock.connected
        repeat: true
        onTriggered: watchSock.connected = true
    }
    Component.onCompleted: watchSock.connected = true

    // ── Les demandes ─────────────────────────────────────────────────
    property var _queue: []

    function _send(obj) {
        rec._queue = rec._queue.concat([JSON.stringify(obj)]);
        if (!reqSock.connected)
            reqSock.connected = true;
    }

    function _next() {
        rec._queue = rec._queue.slice(1);
        reqSock.connected = false;
        if (rec._queue.length > 0)
            Qt.callLater(function () { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        // La réponse (`{"ok":…}`) importe peu : l'état arrive par le suivi.
        parser: SplitParser {
            onRead: (line) => rec._next()
        }
        onConnectedChanged: {
            if (connected && rec._queue.length > 0)
                write(rec._queue[0] + "\n");
        }
    }
}
