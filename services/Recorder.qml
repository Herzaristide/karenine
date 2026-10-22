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
    // Les dernières prises du micro, la plus récente d'abord :
    // [{ path, at: "20261020_165927", duration (s) }].
    property var takes: []
    // Pendant l'enregistrement du micro : les crêtes des dernières secondes
    // (0–1, vingt par seconde), la plus ancienne d'abord.
    property var live: []
    // La prise qu'anna joue : { path, from (s), since (ms Unix) }, ou null.
    property var playing: null

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

    // La forme d'onde d'une prise : `done(peaks)`, des crêtes 0–1 (200 au
    // plus), ou `done([])` si anna n'a pas pu la lire.
    function peaks(path, done) {
        rec._send({ cmd: "record_peaks", path: path }, (r) => done(r && r.peaks ? r.peaks : []));
    }

    // Joue une prise depuis `from` secondes, à la place de ce qui jouait :
    // anna la lit (ffmpeg), le shell n'a besoin d'aucun module multimédia.
    function play(path, from) {
        rec._send({ cmd: "record_play", path: path, from: from || 0 });
    }

    function pause() {
        rec._send({ cmd: "record_pause" });
    }

    // Relit les prises du dossier (des fichiers effacés ou déplacés à la
    // main) ; l'état qui revient est celui du suivi.
    function refresh() {
        rec._send({ cmd: "record_get" }, (r) => {
            if (r && r.record)
                rec._apply(r.record);
        });
    }

    // « 1:05 » : une durée en secondes.
    function clock(seconds) {
        var s = Math.max(0, Math.floor(seconds || 0));
        return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + s % 60;
    }

    function _apply(s) {
        rec.available = true;
        rec.audio = s.audio || null;
        rec.screen = s.screen || null;
        rec.error = s.error || "";
        rec.last = s.last || "";
        rec.takes = s.takes || [];
        rec.live = s.live || [];
        rec.playing = s.playing || null;
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
    // [{ line, done }] : `done(réponse)`, quand la réponse importe.
    property var _queue: []

    function _send(obj, done) {
        rec._queue = rec._queue.concat([{ line: JSON.stringify(obj), done: done || null }]);
        if (!reqSock.connected)
            reqSock.connected = true;
    }

    function _next(line) {
        var done = rec._queue.length > 0 ? rec._queue[0].done : null;
        if (done) {
            var r = null;
            try { r = JSON.parse(line); } catch (e) { /* réponse illisible */ }
            done(r);
        }
        rec._queue = rec._queue.slice(1);
        reqSock.connected = false;
        if (rec._queue.length > 0)
            Qt.callLater(function () { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        // La réponse (`{"ok":…}`) importe peu, l'état arrivant par le suivi,
        // sauf aux demandes qui l'attendent (les crêtes d'une prise).
        parser: SplitParser {
            onRead: (line) => rec._next(line)
        }
        onConnectedChanged: {
            if (connected && rec._queue.length > 0)
                write(rec._queue[0].line + "\n");
        }
    }
}
