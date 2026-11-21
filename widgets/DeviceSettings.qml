pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import "../services"

// La webcam, dans les réglages (widgets/Settings.qml) : celle que les
// applications prennent par défaut (via le portail), et ‹ › pour en
// changer. La section ne se montre que s'il y en a une. Le son et le Wi-Fi
// se règlent dans leurs volets de la barre du bas (panels/Bar.qml).
//
// Ce sont des nœuds PipeWire : `wpctl status` les liste (le défaut marqué
// d'un *), `wpctl set-default` en change.
SettingsSection {
    id: root

    title: I18n.tr("settings.video")
    visible: root.nodes.video.length > 0

    // { sink: [], source: [], video: [] } : [{ id, name, active }]
    property var nodes: ({ sink: [], source: [], video: [] })

    // ── PipeWire ─────────────────────────────────────────────────
    Process {
        id: statusProc
        command: ["wpctl", "status"]
        stdout: StdioCollector {
            onStreamFinished: root.nodes = root.parseStatus(text)
        }
    }

    // Les sections Audio et Video de `wpctl status`, dessinées en arbre :
    //   Audio
    //    ├─ Sinks:
    //    │  *   52. Speaker   [vol: 0.60]
    function parseStatus(text) {
        var out = { sink: [], source: [], video: [] };
        var top = "";
        var sec = "";
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (/^Audio/.test(line)) { top = "audio"; sec = ""; continue; }
            if (/^Video/.test(line)) { top = "video"; sec = ""; continue; }
            if (/^\S/.test(line)) { top = ""; sec = ""; continue; }
            var head = line.match(/(Devices|Sinks|Sources|Filters|Streams):/);
            if (head) {
                sec = head[1] === "Sinks" && top === "audio" ? "sink"
                    : head[1] === "Sources" && top === "audio" ? "source"
                    : head[1] === "Sources" && top === "video" ? "video" : "";
                continue;
            }
            if (sec === "")
                continue;
            var m = line.match(/^[\s│├└─]*(\*)?\s*(\d+)\.\s+(.*?)\s*(\[.*\])?\s*$/);
            if (m)
                out[sec].push({ id: m[2], active: m[1] === "*", name: m[3].replace(/\s*\(V4L2\)$/, "") });
        }
        return out;
    }

    Process {
        id: setDefaultProc
        onRunningChanged: if (!running) statusProc.running = true
    }

    // Le suivant (ou le précédent) de la liste devient le défaut.
    function cycle(kind, dir) {
        var list = root.nodes[kind];
        if (list.length < 2 || setDefaultProc.running)
            return;
        var cur = list.findIndex(n => n.active);
        var next = list[(cur + dir + list.length) % list.length];
        setDefaultProc.command = ["wpctl", "set-default", next.id];
        setDefaultProc.running = true;
    }

    function activeName(kind) {
        var list = root.nodes[kind];
        var a = list.find(n => n.active) || list[0];
        return a ? a.name : "—";
    }

    Timer {
        interval: 3000
        repeat: true
        running: true  // l'onglet n'existe que tant qu'il est affiché
        triggeredOnStart: true
        onTriggered: {
            if (!statusProc.running)
                statusProc.running = true;
        }
    }

    // ── La ligne ─────────────────────────────────────────────────
    SettingsRow {
        icon: "video.svg"
        title: I18n.tr("settings.video.webcam")
        subtitle: root.activeName("video")
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            // Rien à choisir avec une seule.
            visible: root.nodes.video.length > 1
            BarButton { size: 26; icon: "chevron-left.svg"; onClicked: root.cycle("video", -1) }
            BarButton { size: 26; icon: "chevron-right.svg"; onClicked: root.cycle("video", 1) }
        }
    }
}
