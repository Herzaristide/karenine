pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Le métronome lui-même : son tempo, sa mesure, s'il bat, et sa session
// avec anna. Ici plutôt que dans le widget (widgets/Metronome.qml), qui n'en
// est que la façade : il continue de battre onglet fermé, et le pilote ou le
// FIFO (« metronome:lancer:120 ») le lancent et l'arrêtent sans l'ouvrir.
//
// anna tient le temps et le son (une sortie cpal qui mêle les clics à
// l'échantillon près) ; on lui ouvre une session sur le socket, on envoie
// des lignes {"action":…} et on reçoit {"beat":<n>}.
Singleton {
    id: tempo

    readonly property int minBpm: 20
    readonly property int maxBpm: 300

    property bool running: false
    property int bpm: 120
    property int beatsPerBar: 4
    property int beatIndex: -1
    // Le widget est à l'écran : la session s'ouvre d'avance, pour que
    // « Lancer » batte tout de suite.
    property bool shown: false

    function clampBpm(v) { return Math.max(tempo.minBpm, Math.min(tempo.maxBpm, v)) }

    // Lancer (au tempo donné, sinon au courant), arrêter, basculer.
    function start(v) {
        if (v > 0)
            tempo.bpm = tempo.clampBpm(Math.round(v));
        tempo.running = true;
    }
    function stop() { tempo.running = false; }
    function toggle() { tempo.running = !tempo.running; }

    function setBeats(n) {
        tempo.beatsPerBar = Math.max(1, Math.min(16, Math.round(n)));
        tempo.beatIndex = -1;
    }

    // « lancer[:BPM[:TEMPS]] », « arreter », « basculer » : ce qu'écrit anna.
    function apply(action, bpmArg, beatsArg) {
        var b = parseInt(beatsArg);
        if (!isNaN(b))
            tempo.setBeats(b);
        if (action === "lancer")
            tempo.start(parseInt(bpmArg));
        else if (action === "arreter")
            tempo.stop();
        else
            tempo.toggle();
    }

    function send(obj) {
        if (sock.connected)
            sock.write(JSON.stringify(obj) + "\n");
    }

    onRunningChanged: {
        if (running) {
            beatIndex = -1;
            sock.connected = true;
            send({ action: "start", bpm: bpm });
        } else {
            send({ action: "stop" });
            if (!shown)
                sock.connected = false;
        }
    }
    onBpmChanged: send({ action: "bpm", value: bpm })
    onBeatsPerBarChanged: send({ action: "beats", value: beatsPerBar })
    onShownChanged: if (!shown && !running) sock.connected = false

    Socket {
        id: sock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (typeof msg.beat === "number") {
                        tempo.beatIndex = msg.beat;
                    } else if (msg.ready === true) {
                        // La session est prête : on lui donne l'état.
                        tempo.send({ action: "beats", value: tempo.beatsPerBar });
                        tempo.send({ action: "bpm", value: tempo.bpm });
                        if (tempo.running)
                            tempo.send({ action: "start", bpm: tempo.bpm });
                    }
                } catch (e) { /* ligne incomplète ou malformée */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"metronome"}\n');
        }
    }

    // Connecté tant qu'il est à l'écran ou qu'il bat ; nouvel essai toutes
    // les 2 s (anna redémarré…).
    Timer {
        interval: 2000
        running: tempo.shown || tempo.running
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!sock.connected) sock.connected = true
    }
}
