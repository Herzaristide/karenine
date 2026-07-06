import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io

Item {
    id: metroPanel

    // ── State ─────────────────────────────────────────────────────────────
    property bool metroRunning:      false
    property int  bpm:               120
    property int  beatsPerBar:       4
    property int  beatIndex:         -1
    property var  tapHistory:        []
    // True when this widget is the one currently shown in the panel. The audio
    // backend (persistent aplay stream) only runs while the metronome is
    // visible or actively ticking — no idle stream when it's not in use.
    property bool active:            false

    // Path resolved by quickshell.nix → ~/.config/quickshell/metronome.sh
    readonly property string backendPath: Qt.resolvedUrl("metronome.sh").toString().replace("file://", "")

    function clampBpm(v) { return Math.max(20, Math.min(300, v)) }

    function tapTempo() {
        var now = Date.now()
        var h = metroPanel.tapHistory
        if (h.length > 0 && now - h[h.length - 1] > 3000) h = []
        h.push(now)
        if (h.length > 6) h = h.slice(-6)
        metroPanel.tapHistory = h
        if (h.length >= 2) {
            var sum = 0
            for (var i = 1; i < h.length; i++) sum += h[i] - h[i - 1]
            metroPanel.bpm = metroPanel.clampBpm(Math.round(60000 / (sum / (h.length - 1))))
        }
    }

    // ── Backend ───────────────────────────────────────────────────────────
    // Long-lived Python process that owns timing + audio via a PortAudio
    // (PipeWire) callback. Clicks are mixed into the audio stream at exact
    // sample offsets, so beats are perfectly evenly spaced — no per-beat
    // process spawn, no scheduler jitter.
    Process {
        id: metroBackend
        command: ["bash", "-c", "exec bash '" + metroPanel.backendPath + "' 2>>$HOME/.cache/quickshell-metronome.log"]
        running: metroPanel.active || metroPanel.metroRunning
        stdinEnabled: true
        stdout: SplitParser {
            onRead: (data) => {
                var line = data.trim()
                if (line.indexOf("BEAT ") === 0) {
                    metroPanel.beatIndex = parseInt(line.substring(5))
                } else if (line === "READY") {
                    // Re-push state in case the backend was just (re)spawned
                    metroPanel.metroSend("BEATS " + metroPanel.beatsPerBar)
                    metroPanel.metroSend("BPM " + metroPanel.bpm)
                    if (metroPanel.metroRunning)
                        metroPanel.metroSend("START " + metroPanel.bpm)
                }
            }
        }
        stderr: SplitParser { onRead: (data) => { /* ignore */ } }
    }

    function metroSend(cmd) {
        if (metroBackend.running)
            metroBackend.write(cmd + "\n")
    }

    onMetroRunningChanged: {
        if (metroRunning) {
            beatIndex = -1
            metroSend("START " + bpm)
        } else {
            metroSend("STOP")
        }
    }
    onBpmChanged:               metroSend("BPM " + bpm)
    onBeatsPerBarChanged:       metroSend("BEATS " + beatsPerBar)

    // ── UI Layout (centered column, max width) ───────────────────────────
    readonly property int contentMaxWidth: 320

    ColumnLayout {
        id: contentColumn
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 24, metroPanel.contentMaxWidth)
        spacing: 0

        Item { Layout.fillHeight: true }

        // ── Header ────────────────────────────────────────────
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "MÉTRONOME"
            font.family: "JetBrains Mono"
            font.pixelSize: 12
            font.weight: Font.Medium
            font.letterSpacing: 2
            color: Theme.accentMuted
        }

        Item { Layout.preferredHeight: 18 }

        // ── BPM display (large, centered) ─────────────────────
        TextInput {
            id: bpmInput
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 180
            text: metroPanel.bpm.toString()
            font.family: "JetBrains Mono"
            font.pixelSize: 56
            font.bold: true
            color: Theme.textPrimary
            horizontalAlignment: TextInput.AlignHCenter
            selectByMouse: true
            validator: IntValidator { bottom: 20; top: 300 }
            onEditingFinished: {
                var v = parseInt(text)
                if (!isNaN(v)) metroPanel.bpm = metroPanel.clampBpm(v)
                text = metroPanel.bpm.toString()
            }
            Connections {
                target: metroPanel
                function onBpmChanged() {
                    if (!bpmInput.activeFocus)
                        bpmInput.text = metroPanel.bpm.toString()
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "bpm"
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            font.letterSpacing: 1.5
            color: Theme.textDim
        }

        Item { Layout.preferredHeight: 16 }

        // ── BPM adjust buttons ────────────────────────────────
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 6

            Repeater {
                model: [-1, 1]
                Rectangle {
                    required property var modelData
                    width: 38
                    height: 28
                    radius: 4
                    color: ma.containsMouse ? Theme.accentDark : "transparent"
                    border.color: Theme.bgElevated
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: (modelData > 0 ? "+" : "") + modelData
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        color: Theme.accentMuted
                    }
                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: metroPanel.bpm = metroPanel.clampBpm(metroPanel.bpm + parent.modelData)
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 22 }

        // ── Beat indicator dots (centered) ────────────────────
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 12

            Repeater {
                model: metroPanel.beatsPerBar
                Rectangle {
                    required property int index
                    width: 18
                    height: 18
                    radius: 9
                    property bool isActive: metroPanel.metroRunning && metroPanel.beatIndex === index
                    color: isActive
                           ? (index === 0 ? Theme.colorSuccess : Theme.accentColor)
                           : Theme.bgDeep
                    border.width: index === 0 ? 1 : 0
                    border.color: Qt.rgba(Theme.iconColor.r, Theme.iconColor.g, Theme.iconColor.b, 0.15)
                    Behavior on color { ColorAnimation { duration: 60 } }
                    SequentialAnimation on scale {
                        running: isActive
                        NumberAnimation { to: 1.25; duration: 50; easing.type: Easing.OutQuad }
                        NumberAnimation { to: 1.0;  duration: 140; easing.type: Easing.InQuad }
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 24 }

        // ── Start / stop (centered row) ───────────────────────
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 10

            // Start / stop (large primary)
            Rectangle {
                width: 96; height: 36; radius: 6
                color: startStopMa.containsMouse
                       ? Theme.accentColor
                       : (metroPanel.metroRunning ? Theme.accentColor : Theme.bgDeep)
                border.color: Theme.accentColor
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: metroPanel.metroRunning ? "■  STOP" : "▶  START"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    font.letterSpacing: 1.5
                    color: (metroPanel.metroRunning || startStopMa.containsMouse)
                           ? Theme.textPrimary
                           : Theme.accentColor
                }
                MouseArea {
                    id: startStopMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: metroPanel.metroRunning = !metroPanel.metroRunning
                }
            }

            // Beats-per-bar cycle
            Rectangle {
                width: 44; height: 36; radius: 6
                color: bpbMa.containsMouse ? Theme.accentDark : "transparent"
                border.color: Theme.accentDark
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: metroPanel.beatsPerBar + "/4"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.textSecondary
                }
                MouseArea {
                    id: bpbMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // Cycle 2 → 3 → 4 → 5 → 6 → 2
                        var n = metroPanel.beatsPerBar + 1
                        if (n > 6) n = 2
                        metroPanel.beatsPerBar = n
                        metroPanel.beatIndex = -1
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 22 }

        // ── Tap tempo ────────────────────────────────────────
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 200
            height: 34
            radius: 6
            color: tapMa.containsMouse ? Theme.accentDark : Theme.bgDeep
            border.color: Theme.accentDark
            border.width: 1
            Text {
                anchors.centerIn: parent
                text: "TAP TEMPO"
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                font.letterSpacing: 2
                color: tapMa.containsMouse ? Theme.textPrimary : Theme.accentMuted
            }
            MouseArea {
                id: tapMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: metroPanel.tapTempo()
            }
        }

        Item { Layout.fillHeight: true }
    }
}
