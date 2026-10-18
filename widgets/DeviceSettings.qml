pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"

// Les périphériques, première colonne des réglages : la sortie et l'entrée
// du son, la webcam, le Wi-Fi (WifiSettings). Le volume, la luminosité et
// le Bluetooth, eux, sont dans la barre du haut des widgets (HubTopBar).
//
// Son et webcam sont des nœuds PipeWire : `wpctl status` les liste (le
// défaut marqué d'un *), `wpctl set-default` en change — une webcam par
// défaut est celle que les applications prennent via le portail.
ColumnLayout {
    id: root

    spacing: 6

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
        running: root.visible
        triggeredOnStart: true
        onTriggered: {
            if (!statusProc.running)
                statusProc.running = true;
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    component Heading: Text {
        Layout.bottomMargin: 4
        font.family: "Inter"
        font.pixelSize: 12
        font.weight: Font.Medium
        color: Theme.accentMuted
    }

    // Une ligne : ce qu'elle règle, le périphérique, et ‹ › pour en changer.
    component DeviceRow: Rectangle {
        id: row
        property string label
        property string kind
        readonly property int count: root.nodes[row.kind].length

        Layout.fillWidth: true
        // Un nom long passe sur deux lignes : la carte grandit.
        implicitHeight: Math.max(46, rowText.implicitHeight + 16)
        radius: 14
        color: Qt.alpha(Theme.textPrimary, 0.05)
        border.width: 1
        border.color: Qt.alpha(Theme.textPrimary, 0.08)

        Column {
            id: rowText
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: arrows.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                text: row.label
                font.family: "Inter"
                font.pixelSize: 10
                color: Theme.textSecondary
            }
            Text {
                width: parent.width
                text: root.activeName(row.kind)
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textPrimary
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        Row {
            id: arrows
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            // Rien à choisir avec un seul périphérique.
            visible: row.count > 1
            GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "‹"; onClicked: root.cycle(row.kind, -1) }
            GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "›"; onClicked: root.cycle(row.kind, 1) }
        }
    }

    // ── Les lignes ───────────────────────────────────────────────
    Heading { text: I18n.tr("settings.sound") }
    DeviceRow { label: I18n.tr("settings.sound.output"); kind: "sink" }
    DeviceRow { label: I18n.tr("settings.sound.input"); kind: "source" }

    Heading {
        Layout.topMargin: 10
        text: I18n.tr("settings.video")
    }
    DeviceRow {
        label: I18n.tr("settings.video.webcam")
        kind: "video"
        visible: root.nodes.video.length > 0
    }

    WifiSettings {
        Layout.fillWidth: true
    }
}
