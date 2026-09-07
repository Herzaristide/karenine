pragma Singleton
import QtQuick
import Quickshell.Io

// État du volume pour la carte de réglage. Ne sonde `wpctl` que pendant que
// `active` est vrai, c'est-à-dire tant qu'une carte volume est affichée —
// aucun sondage ne tourne quand le dock est fermé.
QtObject {
    id: root

    property bool active: false
    property real level: 0.0
    property bool muted: false

    readonly property int percent: Math.round(level * 100)

    property Process readProc: Process {
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        stdout: StdioCollector { id: readOut }
        onRunningChanged: {
            if (running)
                return;
            var m = readOut.text.trim().match(/Volume:\s*([\d.]+)(\s*\[MUTED\])?/);
            if (m) {
                root.level = parseFloat(m[1]);
                root.muted = m[2] !== undefined;
            }
        }
    }

    // Un `Process` déjà en cours ignore `running = true` : sans file d'attente,
    // trois clics rapides sur « + » n'en monteraient qu'un. On empile, et le
    // rafraîchissement n'a lieu qu'une fois la file vidée.
    property var _queue: []

    property Process writeProc: Process {
        onRunningChanged: {
            if (running)
                return;
            root._pump();
            if (!running)
                root.refresh();
        }
    }

    property Timer poll: Timer {
        interval: 2000
        repeat: true
        running: root.active
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function refresh() {
        if (!readProc.running)
            readProc.running = true;
    }

    function _run(argv) {
        root._queue.push(argv);
        root._pump();
    }

    function _pump() {
        if (writeProc.running || root._queue.length === 0)
            return;
        writeProc.command = root._queue.shift();
        writeProc.running = true;
    }

    function up()         { _run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+"]); }
    function down()       { _run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"]); }
    function toggleMute() { _run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]); }
}
