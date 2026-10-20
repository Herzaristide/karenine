pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

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
    // Native `anna` daemon owns timing + audio via a cpal output callback that
    // mixes clicks at exact sample offsets, so beats are perfectly evenly
    // spaced — no scheduler jitter. We open a metronome session over the Unix
    // socket, send control lines ({"action":…}), and receive {"beat":<n>}.
    Socket {
        id: metroSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line)
                    if (typeof msg.beat === "number") {
                        metroPanel.beatIndex = msg.beat
                    } else if (msg.ready === true) {
                        // Push current state now the session is established.
                        metroPanel.metroCmd({ action: "beats", value: metroPanel.beatsPerBar })
                        metroPanel.metroCmd({ action: "bpm",   value: metroPanel.bpm })
                        if (metroPanel.metroRunning)
                            metroPanel.metroCmd({ action: "start", bpm: metroPanel.bpm })
                    }
                } catch (e) { /* ignore malformed / partial line */ }
            }
        }
        onConnectedChanged: {
            if (connected) write('{"cmd":"metronome"}\n')
        }
    }

    // Connect while the metronome is visible or ticking; retry every 2 s.
    Timer {
        interval: 2000
        running: metroPanel.active || metroPanel.metroRunning
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!metroSock.connected) metroSock.connected = true
    }

    onActiveChanged: if (!active && !metroRunning) metroSock.connected = false

    function metroCmd(obj) {
        if (metroSock.connected)
            metroSock.write(JSON.stringify(obj) + "\n")
    }

    onMetroRunningChanged: {
        if (metroRunning) {
            beatIndex = -1
            metroSock.connected = true
            metroCmd({ action: "start", bpm: bpm })
        } else {
            metroCmd({ action: "stop" })
        }
    }
    onBpmChanged:               metroCmd({ action: "bpm",   value: bpm })
    onBeatsPerBarChanged:       metroCmd({ action: "beats", value: beatsPerBar })

    // ── UI : en colonne, à droite du panneau Musique ──────────────────────
    //   ( − ) 120 ( + )
    //         bpm
    //      ● ● ● ●
    //    (4/4) (Tap)
    //   (  ▶ Lancer  )
    implicitWidth: column.implicitWidth

    ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: 8

        // Le tempo : en grand, éditable, entre ses deux boutons.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 4

            GlassButton {
                implicitWidth: 28
                implicitHeight: 28
                fontSize: 15
                text: "−"
                onClicked: metroPanel.bpm = metroPanel.clampBpm(metroPanel.bpm - 1)
            }
            ColumnLayout {
                spacing: -4
                TextInput {
                    id: bpmInput
                    Layout.preferredWidth: 76
                    text: metroPanel.bpm.toString()
                    font.family: "Inter"
                    font.pixelSize: 34
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: Theme.textPrimary
                    horizontalAlignment: TextInput.AlignHCenter
                    selectByMouse: true
                    validator: IntValidator { bottom: 20; top: 300 }
                    // Au clavier : Tab y arrive, ↑ ↓ changent le tempo d'un
                    // battement (Maj : de dix), Entrée valide ce qu'on a tapé.
                    activeFocusOnTab: true
                    Keys.onUpPressed: (event) => bpmInput.nudge(event.modifiers & Qt.ShiftModifier ? 10 : 1)
                    Keys.onDownPressed: (event) => bpmInput.nudge(event.modifiers & Qt.ShiftModifier ? -10 : -1)
                    function nudge(d) {
                        metroPanel.bpm = metroPanel.clampBpm(metroPanel.bpm + d)
                        text = metroPanel.bpm.toString()
                    }
                    FocusRing { radius: 10; gap: 2 }
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
                    // La molette règle le tempo, comme un bouton rotatif.
                    WheelHandler {
                        onWheel: (event) => bpmInput.nudge(event.angleDelta.y > 0 ? 1 : -1)
                    }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "bpm"
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
            }
            GlassButton {
                implicitWidth: 28
                implicitHeight: 28
                fontSize: 15
                text: "+"
                onClicked: metroPanel.bpm = metroPanel.clampBpm(metroPanel.bpm + 1)
            }
        }

        // Les temps de la mesure : le premier en vert, les autres à l'accent.
        Row {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 2
            spacing: 9
            Repeater {
                model: metroPanel.beatsPerBar
                Rectangle {
                    id: beatDot
                    required property int index
                    width: 12
                    height: 12
                    radius: 6
                    property bool isActive: metroPanel.metroRunning && metroPanel.beatIndex === index
                    color: isActive
                           ? (index === 0 ? Theme.colorSuccess : Theme.glow(0))
                           : Qt.alpha(Theme.textPrimary, 0.1)
                    border.width: 1
                    border.color: Qt.alpha(Theme.textPrimary, index === 0 ? 0.22 : 0.08)
                    Behavior on color { ColorAnimation { duration: 80 } }
                    SequentialAnimation on scale {
                        running: beatDot.isActive
                        NumberAnimation { to: 1.25; duration: 60; easing.type: Easing.OutCubic }
                        NumberAnimation { to: 1.0;  duration: 220; easing.type: Easing.OutQuint }
                    }
                }
            }
        }

        // La mesure et le tap tempo.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            // 2 → 3 → 4 → 5 → 6 → 2
            GlassButton {
                Layout.fillWidth: true
                implicitHeight: 26
                fontSize: 11
                text: metroPanel.beatsPerBar + "/4"
                onClicked: {
                    var n = metroPanel.beatsPerBar + 1
                    if (n > 6) n = 2
                    metroPanel.beatsPerBar = n
                    metroPanel.beatIndex = -1
                }
            }
            GlassButton {
                Layout.fillWidth: true
                implicitHeight: 26
                fontSize: 11
                text: I18n.tr("metronome.tapShort")
                onClicked: metroPanel.tapTempo()
            }
        }

        Item { Layout.fillHeight: true }

        // Lancer, arrêter.
        GlassButton {
            Layout.fillWidth: true
            implicitHeight: 32
            accent: metroPanel.metroRunning
            fontSize: 12
            icon: Qt.resolvedUrl("../assets/icons/" + (metroPanel.metroRunning ? "stop.svg" : "play.svg"))
            text: metroPanel.metroRunning ? I18n.tr("common.stop") : I18n.tr("metronome.start")
            onClicked: metroPanel.metroRunning = !metroPanel.metroRunning
        }
    }
}
