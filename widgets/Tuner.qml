pragma ComponentBehavior: Bound
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
    // A4 reference (concert pitch) in Hz, set in the settings (Tuning).
    readonly property real refFreq: Tuning.refFreq
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
        path: Anna.socketPath
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

    // ── UI : horizontale, dans le style de la barre de conversation ──────
    //    A4        −50 ┊ · · · · ┃ · · · · ┊ +50
    //   440,0 Hz         ▮ (l'aiguille)
    //   +3 ¢              A4 = 440 Hz
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 28

        // La note, en grand.
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 140
            spacing: 2

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tuner.freq > 0 ? tuner.noteName + tuner.octave : "—"
                font.family: "Inter"
                font.pixelSize: 60
                font.weight: Font.DemiBold
                color: tuner.inTune ? Theme.colorSuccess : Theme.textPrimary
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tuner.freq > 0
                      ? tuner.freq.toFixed(1) + " Hz  ·  " + (tuner.cents > 0 ? "+" : "") + tuner.cents + " ¢"
                      : "Joue une note…"
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textSecondary
            }
        }

        // La jauge des cents, puis la référence.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 14

            Item {
                id: meter
                Layout.fillWidth: true
                Layout.preferredHeight: 54

                // La zone juste (±5 ¢), teintée.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: track.verticalCenter
                    width: meter.width * 0.1
                    height: 26
                    radius: 8
                    color: Qt.alpha(Theme.colorSuccess, tuner.inTune ? 0.24 : 0.1)
                    Behavior on color { ColorAnimation { duration: 160 } }
                }

                Rectangle {
                    id: track
                    y: 14
                    width: parent.width
                    height: 6
                    radius: 3
                    color: Qt.alpha(Theme.textPrimary, 0.1)
                }

                // Les graduations, tous les 10 ¢.
                Repeater {
                    model: 11
                    Rectangle {
                        required property int index
                        x: index / 10 * (meter.width - width)
                        anchors.verticalCenter: track.verticalCenter
                        width: 2
                        height: index === 5 ? 20 : 10
                        radius: 1
                        color: Qt.alpha(Theme.textPrimary, index === 5 ? 0.45 : 0.18)
                    }
                }

                // L'aiguille.
                Rectangle {
                    visible: tuner.freq > 0
                    width: 8
                    height: 28
                    radius: 4
                    anchors.verticalCenter: track.verticalCenter
                    color: tuner.inTune ? Theme.colorSuccess : Theme.glow(0)
                    x: (meter.width - width) / 2
                       + Math.max(-50, Math.min(50, tuner.cents)) / 50 * (meter.width - width) / 2
                    Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 160 } }
                }

                Text {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    text: "−50"
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    text: "juste"
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: tuner.inTune ? Theme.colorSuccess : Theme.textDim
                }
                Text {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    text: "+50"
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
            }

            // La référence (A4) : elle se règle dans les réglages.
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "A4 = " + tuner.refFreq.toFixed(0) + " Hz"
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textSecondary
            }
        }
    }
}
