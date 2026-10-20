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

    // ── UI : allumer, la note, puis la jauge des cents ────────────────────
    //   (♪)   A4    ┊ · · · · ┃ · · · · ┊
    //        +3 ¢   440,0 Hz       A4 = 440
    // Coupé (Tuning.on), le micro reste fermé et la jauge s'efface.
    RowLayout {
        anchors.fill: parent
        spacing: 14

        GlassButton {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 32
            implicitHeight: 32
            accent: Tuning.on
            icon: Qt.resolvedUrl("../assets/icons/music-note.svg")
            onClicked: Tuning.setOn(!Tuning.on)
        }

        // La note, en grand, et son écart.
        ColumnLayout {
            opacity: Tuning.on ? 1 : 0.35
            Behavior on opacity { NumberAnimation { duration: 180 } }
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 64
            spacing: 0

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tuner.freq > 0 ? tuner.noteName + tuner.octave : "—"
                font.family: "Inter"
                font.pixelSize: 34
                font.weight: tuner.freq > 0 ? Font.DemiBold : Font.Light
                color: tuner.freq <= 0 ? Theme.textDim : tuner.inTune ? Theme.colorSuccess : Theme.textPrimary
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tuner.freq > 0 ? (tuner.cents > 0 ? "+" : "") + tuner.cents + " ¢" : " "
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: Font.Medium
                font.features: { "tnum": 1 }
                color: tuner.inTune ? Theme.colorSuccess : Theme.textSecondary
            }
        }

        // La jauge des cents (±50), la zone juste teintée au milieu.
        Item {
            id: meter
            opacity: Tuning.on ? 1 : 0.5
            Behavior on opacity { NumberAnimation { duration: 180 } }
            Layout.fillWidth: true
            Layout.fillHeight: true

            readonly property real mid: 22

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: meter.mid - height / 2
                width: meter.width * 0.1
                height: 22
                radius: 7
                color: Qt.alpha(Theme.colorSuccess, tuner.inTune ? 0.24 : 0.09)
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Rectangle {
                id: track
                y: meter.mid - height / 2
                width: parent.width
                height: 4
                radius: 2
                color: Qt.alpha(Theme.textPrimary, 0.1)
            }
            // Les graduations, tous les 10 ¢.
            Repeater {
                model: 11
                Rectangle {
                    required property int index
                    x: index / 10 * (meter.width - width)
                    y: meter.mid - height / 2
                    width: 2
                    height: index === 5 ? 16 : 8
                    radius: 1
                    color: Qt.alpha(Theme.textPrimary, index === 5 ? 0.4 : 0.16)
                }
            }
            // L'aiguille.
            Rectangle {
                visible: tuner.freq > 0
                width: 6
                height: 24
                radius: 3
                y: meter.mid - height / 2
                color: tuner.inTune ? Theme.colorSuccess : Theme.glow(0)
                x: (meter.width - width) / 2
                   + Math.max(-50, Math.min(50, tuner.cents)) / 50 * (meter.width - width) / 2
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 160 } }
            }

            // Sous la jauge : la fréquence entendue, et la référence (elle
            // se règle dans les réglages).
            Text {
                anchors.left: parent.left
                y: meter.mid + 16
                text: !Tuning.on ? I18n.tr("tuner.off")
                      : tuner.freq > 0 ? tuner.freq.toFixed(1) + " Hz" : I18n.tr("tuner.play")
                font.family: "Inter"
                font.pixelSize: 10
                font.features: { "tnum": 1 }
                color: Theme.textDim
            }
            Text {
                anchors.right: parent.right
                y: meter.mid + 16
                text: "A4 = " + tuner.refFreq.toFixed(0) + " Hz"
                font.family: "Inter"
                font.pixelSize: 10
                color: Theme.textDim
            }
        }
    }
}
