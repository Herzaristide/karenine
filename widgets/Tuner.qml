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
    // A4 reference (concert pitch) in Hz, set under the meter (Tuning).
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

    // ── UI : une petite carte, dans le coin haut droit du panneau Musique ──
    //   ACCORDEUR      (🎤)
    //       A4  +3 ¢
    //   ┊ · · · ┃ · · · ┊
    //   440,0 Hz    A4 = 440
    // Coupé (Tuning.on), le micro reste fermé et la jauge s'efface.
    implicitHeight: column.implicitHeight

    ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            SectionTitle {
                Layout.alignment: Qt.AlignVCenter
                Layout.fillWidth: true
                text: I18n.tr("tuner.title")
            }
            // Allumer, couper : le micro ne s'ouvre qu'allumé.
            GlassButton {
                implicitWidth: 26
                implicitHeight: 26
                accent: Tuning.on
                icon: Qt.resolvedUrl("../assets/icons/mic.svg")
                onClicked: Tuning.setOn(!Tuning.on)
            }
        }

        // La note, en grand, et son écart à côté.
        Row {
            Layout.alignment: Qt.AlignHCenter
            spacing: 6
            opacity: Tuning.on ? 1 : 0.35
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Text {
                id: noteText
                text: tuner.freq > 0 ? tuner.noteName + tuner.octave : "—"
                font.family: "Inter"
                font.pixelSize: 24
                font.weight: tuner.freq > 0 ? Font.DemiBold : Font.Light
                color: tuner.freq <= 0 ? Theme.textDim : tuner.inTune ? Theme.colorSuccess : Theme.textPrimary
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Text {
                visible: tuner.freq > 0
                anchors.baseline: noteText.baseline
                text: (tuner.cents > 0 ? "+" : "") + tuner.cents + " ¢"
                font.family: "Inter"
                font.pixelSize: 10
                font.weight: Font.Medium
                font.features: { "tnum": 1 }
                color: tuner.inTune ? Theme.colorSuccess : Theme.textSecondary
            }
        }

        // La jauge des cents (±50), la zone juste teintée au milieu.
        Item {
            id: meter
            Layout.fillWidth: true
            Layout.preferredHeight: 20
            opacity: Tuning.on ? 1 : 0.5
            Behavior on opacity { NumberAnimation { duration: 180 } }

            readonly property real mid: height / 2

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: meter.mid - height / 2
                width: meter.width * 0.1
                height: 18
                radius: 5
                color: Qt.alpha(Theme.colorSuccess, tuner.inTune ? 0.24 : 0.09)
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Rectangle {
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
                    height: index === 5 ? 12 : 6
                    radius: 1
                    color: Qt.alpha(Theme.textPrimary, index === 5 ? 0.4 : 0.16)
                }
            }
            // L'aiguille.
            Rectangle {
                visible: tuner.freq > 0
                width: 5
                height: 20
                radius: 2.5
                y: meter.mid - height / 2
                color: tuner.inTune ? Theme.colorSuccess : Theme.glow(0)
                x: (meter.width - width) / 2
                   + Math.max(-50, Math.min(50, tuner.cents)) / 50 * (meter.width - width) / 2
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 160 } }
            }
        }

        // La fréquence entendue, et la référence, qui se règle ici
        // (− + au survol, la molette, ou ↑ ↓ au clavier ; un clic revient
        // à 440).
        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: !Tuning.on ? I18n.tr("tuner.off")
                      : tuner.freq > 0 ? tuner.freq.toFixed(1) + " Hz" : I18n.tr("tuner.play")
                font.family: "Inter"
                font.pixelSize: 10
                font.features: { "tnum": 1 }
                color: Theme.textDim
            }
            Item {
                id: refRow
                implicitWidth: refInner.width
                implicitHeight: refInner.height

                readonly property bool hovered: refMa.containsMouse || minus.hot
                                                || plus.hot || refRow.activeFocus

                activeFocusOnTab: true
                Keys.onUpPressed: Tuning.setRefFreq(Tuning.refFreq + 1)
                Keys.onDownPressed: Tuning.setRefFreq(Tuning.refFreq - 1)
                FocusRing { gap: 2 }

                Row {
                    id: refInner
                    spacing: 0

                    Nudge { id: minus; step: -1; text: "−"; shown: refRow.hovered }
                    Text {
                        height: 16
                        verticalAlignment: Text.AlignVCenter
                        text: "A4 " + tuner.refFreq.toFixed(0)
                        font.family: "Inter"
                        font.pixelSize: 10
                        font.features: { "tnum": 1 }
                        color: refRow.hovered ? Theme.textSecondary : Theme.textDim
                        MouseArea {
                            id: refMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Tuning.setRefFreq(440)
                            onWheel: (wheel) => Tuning.setRefFreq(Tuning.refFreq + (wheel.angleDelta.y > 0 ? 1 : -1))
                        }
                    }
                    Nudge { id: plus; step: 1; text: "+"; shown: refRow.hovered }
                }
            }
        }
    }

    // Un − ou un + de la référence, qui n'apparaît qu'au survol.
    component Nudge: Text {
        id: nudge
        property int step
        property bool shown
        readonly property bool hot: nudgeMa.containsMouse
        width: 12
        height: 16
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: "Inter"
        font.pixelSize: 12
        font.weight: Font.DemiBold
        color: nudge.hot ? Theme.textPrimary : Theme.textSecondary
        opacity: nudge.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        MouseArea {
            id: nudgeMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Tuning.setRefFreq(Tuning.refFreq + nudge.step)
        }
    }
}
