import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

Item {
    id: tuner

    // ── State ─────────────────────────────────────────────────────────────
    // active == the metronome/tuner page is currently shown. The mic capture
    // backend only runs while active — no open input stream when it's hidden
    // (same resource discipline as the metronome player).
    property bool   active:   false
    property real   freq:     0
    property string noteName: "—"
    property int    octave:   0
    property int    cents:    0
    property real   refFreq:  440   // A4 reference (concert pitch) in Hz
    readonly property bool inTune: freq > 0 && Math.abs(cents) <= 5

    readonly property var noteNames: ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    function setFreq(f) {
        if (f <= 0) {
            tuner.freq = 0
            tuner.noteName = "—"
            tuner.cents = 0
            return
        }
        var midi = 69.0 + 12.0 * Math.log2(f / tuner.refFreq)
        var n = Math.round(midi)
        tuner.cents = Math.round((midi - n) * 100)
        tuner.noteName = tuner.noteNames[((n % 12) + 12) % 12]
        tuner.octave = Math.floor(n / 12) - 1
        tuner.freq = f
    }

    // ── Backend ───────────────────────────────────────────────────────────
    // Native `anna` daemon: subscribe to the tuner service over the Unix socket
    // and receive one {"pitch":<hz>} JSON line per analysis frame. The mic is
    // captured by anna only while this connection is open (i.e. while active).
    Socket {
        id: tunerSock
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/anna.sock"
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line)
                    if (typeof msg.pitch === "number") tuner.setFreq(msg.pitch)
                } catch (e) { /* ignore malformed / partial line */ }
            }
        }
        onConnectedChanged: {
            if (connected) write('{"cmd":"tuner_watch"}\n')
        }
    }

    // Connect while active; retry every 2 s if the daemon isn't up yet.
    Timer {
        interval: 2000
        running: tuner.active
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!tunerSock.connected) tunerSock.connected = true
    }

    // Disconnect (stops the mic in anna) and reset the readout when we stop.
    onActiveChanged: {
        if (!active) {
            tunerSock.connected = false
            setFreq(0)
        }
    }

    // Re-map the currently held pitch when the reference changes.
    onRefFreqChanged: if (freq > 0) setFreq(freq)

    // ── UI ─────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 4

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "ACCORDEUR"
            font.family: "JetBrains Mono"
            font.pixelSize: 12
            font.weight: Font.Medium
            font.letterSpacing: 2
            color: Theme.accentMuted
        }

        // Detected note + octave
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: tuner.freq > 0 ? tuner.noteName + tuner.octave : "—"
            font.family: "JetBrains Mono"
            font.pixelSize: 40
            font.bold: true
            color: tuner.inTune ? Theme.colorSuccess : Theme.textPrimary
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        // Frequency + cents deviation
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: tuner.freq > 0
                  ? tuner.freq.toFixed(1) + " Hz   " + (tuner.cents > 0 ? "+" : "") + tuner.cents + "¢"
                  : "…"
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            color: Theme.textDim
        }

        Item { Layout.preferredHeight: 4 }

        // Cents meter (−50 … +50), needle centered when in tune
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 22

            Rectangle {   // track
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: Theme.bgDeep
            }
            Rectangle {   // center reference
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: 2
                height: 16
                color: Qt.rgba(Theme.iconColor.r, Theme.iconColor.g, Theme.iconColor.b, 0.4)
            }
            Rectangle {   // needle
                visible: tuner.freq > 0
                width: 6
                height: 20
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: tuner.inTune ? Theme.colorSuccess : Theme.accentColor
                x: {
                    const half = parent.width / 2 - width / 2
                    return parent.width / 2 - width / 2
                         + Math.max(-50, Math.min(50, tuner.cents)) / 50 * half
                }
                Behavior on x { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                Behavior on color { ColorAnimation { duration: 120 } }
            }
        }

        Item { Layout.preferredHeight: 4 }

        // Reference pitch (A4) calibration — adjust the fundamental
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 6

            Repeater {
                model: [-1, 1]
                Rectangle {
                    required property var modelData
                    width: 24
                    height: 22
                    radius: 4
                    color: refMa.containsMouse ? Theme.accentDark : "transparent"
                    border.color: Theme.bgElevated
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: parent.modelData > 0 ? "+" : "−"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        color: Theme.accentMuted
                    }
                    MouseArea {
                        id: refMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: tuner.refFreq = Math.max(400, Math.min(480, tuner.refFreq + parent.modelData))
                    }
                }
            }

            Text {
                text: "A4"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: Theme.textDim
            }

            TextInput {
                id: refInput
                text: tuner.refFreq.toFixed(0)
                font.family: "JetBrains Mono"
                font.pixelSize: 14
                font.bold: true
                color: Theme.textPrimary
                horizontalAlignment: TextInput.AlignHCenter
                selectByMouse: true
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator { bottom: 400; top: 480 }
                onEditingFinished: {
                    var v = parseInt(text)
                    if (!isNaN(v)) tuner.refFreq = Math.max(400, Math.min(480, v))
                    text = tuner.refFreq.toFixed(0)
                }
                Connections {
                    target: tuner
                    function onRefFreqChanged() {
                        if (!refInput.activeFocus)
                            refInput.text = tuner.refFreq.toFixed(0)
                    }
                }
            }

            Text {
                text: "Hz"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: Theme.textDim
            }
        }
    }
}
