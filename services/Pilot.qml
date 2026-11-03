pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Le pilote (anna/src/claude/pilot.rs) et la voix qui lui parle
// (anna/src/claude/voice.rs), vus de la barre de conversation.
//
// Le pilote est une session Claude qu'anna garde prête pour les demandes du
// bureau : son, fenêtres, apps, notes… Il agit, il ne lance jamais de
// session Claude Code.
//
// Même plomberie que Gesture : une socket longue par flux (`pilot_watch`,
// `voice_watch`), et les requêtes ponctuelles passent par une troisième, une
// commande par connexion.
Singleton {
    id: pilot

    // ── Voix ─────────────────────────────────────────────────────────
    // anna écoute jusqu'à la fin de la phrase, transcrit en local, et
    // transmet au pilote. voicePhase : "idle", "listening" ou "transcribing".
    property string voicePhase: "idle"
    // Lancée par le mot d'éveil, que la transcription n'a pas encore
    // confirmé : la barre l'attend sans couleur.
    property bool voiceWaking: false
    property real voiceLevel: 0
    property string voiceError: ""
    // Le mot d'activation écoute (micro ouvert en continu).
    property bool voiceWake: false
    // Le mot d'éveil de cette machine (« Karénine », « Bernanos »…).
    property string voiceWakeWord: "Karénine"

    // Lance l'écoute, ou la termine tout de suite si elle est en cours.
    function voiceToggle(send) {
        pilot._send({ cmd: "voice_toggle", send: send === undefined ? true : !!send });
    }

    function voiceWakeToggle() {
        pilot._send({ cmd: "voice_wake" });
    }

    Socket {
        id: voiceSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var msg;
                try { msg = JSON.parse(line); } catch (e) { return; }
                if (!msg || !msg.voice)
                    return;
                // La phase en dernier : qui réagit à la fin de l'écoute
                // trouve déjà le texte final.
                pilot.voiceLevel = msg.voice.level || 0;
                pilot.voiceWaking = !!msg.voice.waking;
                pilot.voiceError = msg.voice.error || "";
                pilot.voiceWake = !!msg.voice.wake;
                pilot.voiceWakeWord = msg.voice.wakeWord || "Karénine";
                pilot.voicePhase = msg.voice.phase;
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"voice_watch"}\n');
            else
                pilot.voicePhase = "idle";
        }
    }

    // ── Pilote ───────────────────────────────────────────────────────
    // items : { kind: "user" | "action" | "reply" | "error", text }, les
    // derniers échanges.
    property bool pilotBusy: false
    property var pilotItems: []

    // Un tour du pilote vient de se terminer.
    signal pilotDone()

    // `clipboard` joint le texte du presse-papiers à la demande.
    function pilotAsk(text, clipboard) {
        pilot._send({ cmd: "pilot_ask", text: text, clipboard: !!clipboard });
    }

    function pilotReset() {
        pilot._send({ cmd: "pilot_reset" });
    }

    Socket {
        id: pilotSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var msg;
                try { msg = JSON.parse(line); } catch (e) { return; }
                if (!msg || !msg.pilot)
                    return;
                var wasBusy = pilot.pilotBusy;
                pilot.pilotItems = msg.pilot.items || [];
                pilot.pilotBusy = !!msg.pilot.busy;
                if (wasBusy && !pilot.pilotBusy)
                    pilot.pilotDone();
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"pilot_watch"}\n');
            else
                pilot.pilotBusy = false;
        }
    }

    // (Re)connexion tant que le daemon est absent — il redémarre avec la
    // session. Chaque flux compte : l'un peut tomber sans l'autre.
    Timer {
        interval: 3000
        running: !pilotSock.connected || !voiceSock.connected
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!pilotSock.connected)
                pilotSock.connected = true;
            if (!voiceSock.connected)
                voiceSock.connected = true;
        }
    }

    // ── Requêtes ─────────────────────────────────────────────────────
    // File d'attente : { line, done } — `done` reçoit la réponse décodée.
    property var _queue: []

    function _send(obj, done) {
        pilot._queue = pilot._queue.concat([{ line: JSON.stringify(obj), done: done || null }]);
        if (!reqSock.connected)
            reqSock.connected = true;
    }

    function _next(reply) {
        var head = pilot._queue[0];
        pilot._queue = pilot._queue.slice(1);
        reqSock.connected = false;
        if (head && head.done)
            head.done(reply);
        if (pilot._queue.length > 0)
            Qt.callLater(function () { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var r = null;
                try { r = JSON.parse(line); } catch (e) { /* ignore */ }
                pilot._next(r);
            }
        }
        onConnectedChanged: {
            if (connected && pilot._queue.length > 0)
                write(pilot._queue[0].line + "\n");
        }
    }
}
