pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io
import "../services"

// Audio only: volume, mute, output and input devices. Everything else lives
// elsewhere — theme, accent and palette in the settings window (the TopBar's
// gear button), battery in the TopBar itself, screenshots on Print.
Item {
    id: root

    implicitHeight: controlsCol.implicitHeight + 16

    // ── State ──────────────────────────────────────────────────────────────
    property real  volumeLevel: 0.0
    property bool  isMuted:     false
    property string volString:   "vol  --"

    // ── wpctl get-volume ───────────────────────────────────────────────────
    Process {
        id: getVolProc
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        stdout: StdioCollector { id: getVolOut }
        onRunningChanged: {
            if (!running) {
                var line = getVolOut.text.trim(); // e.g. "Volume: 0.75" or "Volume: 0.75 [MUTED]"
                var m = line.match(/Volume:\s*([\d.]+)(\s*\[MUTED\])?/);
                if (m) {
                    root.volumeLevel = parseFloat(m[1]);
                    root.isMuted     = m[2] !== undefined;
                    var pct = Math.round(root.volumeLevel * 100);
                    root.volString = root.isMuted
                        ? "vol  -- MUTED"
                        : "vol  " + pct + "%";
                }
            }
        }
    }

    // ── wpctl set-volume ───────────────────────────────────────────────────
    Process {
        id: setVolProc
        property var pendingArgs: []
        command: ["wpctl"].concat(pendingArgs)
        onRunningChanged: {
            if (!running && !getVolProc.running) getVolProc.running = true;
        }
    }

    // Capped at 100 % (-l 1.0): past it PipeWire amplifies in software, and
    // the output clips.
    function _wpctl(args) { setVolProc.pendingArgs = args; setVolProc.running = true; }
    function volumeUp()   { root._wpctl(["set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%+"]); }
    function volumeDown() { root._wpctl(["set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"]); }
    function toggleMute() { root._wpctl(["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]); }

    // ── wpctl status → parse sinks + sources ──────────────────────────────
    property var    sinks:           []
    property var    sources:         []
    property string pendingDeviceId: ""

    Process {
        id: statusProc
        command: [
            "sh", "-c",
            "wpctl status | awk '" +
            "/Sinks:/{sec=\"sink\"} /Sources:/{sec=\"source\"} /Filters:|Streams:|Video/{sec=\"\"} " +
            "sec&&/[0-9]+\\./{act=(index($0,\"*\")>0)?\"true\":\"false\"; line=$0; gsub(/^[^0-9]*/,\"\",line); id=line+0; " +
            "desc=line; sub(/^[0-9]+\\. */,\"\",desc); gsub(/ *\\[.*/,\"\",desc); gsub(/ *$/,\"\",desc); " +
            "print sec\"|\"id\"|\"act\"|\"desc}'" ]
        stdout: StdioCollector { id: statusOut }
        onRunningChanged: {
            if (!running) {
                const newSinks = [];
                const newSources = [];
                const lines = statusOut.text.trim().split('\n');
                for (const line of lines) {
                    if (!line) continue;
                    const parts = line.split('|');
                    if (parts.length < 4) continue;
                    const entry = { id: parts[1], active: parts[2] === "true", desc: parts.slice(3).join('|') };
                    if (parts[0] === "sink")   newSinks.push(entry);
                    if (parts[0] === "source") newSources.push(entry);
                }
                root.sinks   = newSinks;
                root.sources = newSources;
            }
        }
    }

    Process {
        id: setDefaultProc
        command: ["wpctl", "set-default", root.pendingDeviceId]
        onRunningChanged: {
            if (!running && !statusProc.running) statusProc.running = true;
        }
    }

    function activeSinkName() {
        var a = sinks.find(function(s) { return s.active; });
        return a ? a.desc : (sinks.length ? sinks[0].desc : "—");
    }
    function activeSourceName() {
        var a = sources.find(function(s) { return s.active; });
        return a ? a.desc : (sources.length ? sources[0].desc : "—");
    }
    function cycleDevice(list, dir) {
        if (list.length === 0) return;
        var cur = list.findIndex(function(s) { return s.active; });
        var next = (cur + dir + list.length) % list.length;
        root.pendingDeviceId = list[next].id;
        setDefaultProc.running = true;
    }

    // ── Refresh timer ──────────────────────────────────────────────────────
    Timer {
        interval: 3000
        repeat:   true
        running:  true
        onTriggered: {
            if (!getVolProc.running)  getVolProc.running  = true;
            if (!statusProc.running)  statusProc.running  = true;
        }
    }

    Component.onCompleted: { getVolProc.running = true; statusProc.running = true; }

    // ── UI ─────────────────────────────────────────────────────────────────
    ColumnLayout {
        id: controlsCol
        anchors {
            left:   parent.left
            right:  parent.right
            top:    parent.top
            margins: 8
        }
        spacing: 6

        // Header row ─────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:            "AUDIO"
                font.family:     "JetBrains Mono"
                font.pixelSize:  12
                font.bold:       true
                color:           Theme.accentColor
            }

            Item { Layout.fillWidth: true }

            // Volume buttons
            Repeater {
                model: [
                    { label: "[−]",    action: function() { root.volumeDown(); } },
                    { label: "[+]",    action: function() { root.volumeUp();   } },
                    { label: root.isMuted ? "[unmute]" : "[mute]", action: function() { root.toggleMute(); } }
                ]

                delegate: Text {
                    id: volBtn
                    required property var modelData
                    text:            modelData.label
                    font.family:     "JetBrains Mono"
                    font.pixelSize:  11
                    color:           btnHover.containsMouse ? Theme.accentColor : Theme.textInactive
                    Behavior on color { ColorAnimation { duration: 100 } }
                    MouseArea {
                        id:           btnHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape:  Qt.PointingHandCursor
                        onClicked:    volBtn.modelData.action()
                    }
                }
            }
        }

        // Volume readout ─────────────────────────────────────────────────
        Text {
            text:           root.volString
            font.family:    "JetBrains Mono"
            font.pixelSize: 11
            color:          root.isMuted ? Theme.textDim : Theme.textInactive
        }

        // Output device row ────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:           "SORTIE"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                font.bold:      true
                color:          Theme.textInactive
            }

            Text {
                Layout.fillWidth: true
                text:           root.activeSinkName()
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          Theme.textBody
                elide:          Text.ElideRight
            }

            Text {
                text:           "[<]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          sinkPrevHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           sinkPrevHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sinks, -1)
                }
            }

            Text {
                text:           "[>]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          sinkNextHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           sinkNextHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sinks, 1)
                }
            }
        }

        // Input device row ─────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:           "ENTRÉE"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                font.bold:      true
                color:          Theme.textInactive
            }

            Text {
                Layout.fillWidth: true
                text:           root.activeSourceName()
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          Theme.textBody
                elide:          Text.ElideRight
            }

            Text {
                text:           "[<]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          srcPrevHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           srcPrevHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sources, -1)
                }
            }

            Text {
                text:           "[>]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          srcNextHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           srcNextHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sources, 1)
                }
            }
        }

        // Bottom separator ───────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color:            Theme.dividerColor
            Layout.topMargin: 2
        }
    }
}
