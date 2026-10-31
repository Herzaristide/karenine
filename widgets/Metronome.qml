pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

Item {
    id: metroPanel

    // ── State ─────────────────────────────────────────────────────────────
    // Le métronome vit dans services/Tempo.qml : il bat onglet fermé, et le
    // pilote le lance sans l'ouvrir. Ici, sa façade et le tap tempo.
    property var  tapHistory:        []
    // L'onglet est à l'écran : Tempo ouvre sa session d'avance.
    property bool active:            false

    onActiveChanged: Tempo.shown = active
    Component.onCompleted: Tempo.shown = active
    Component.onDestruction: Tempo.shown = false

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
            Tempo.bpm = Tempo.clampBpm(Math.round(60000 / (sum / (h.length - 1))))
        }
    }

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
                onClicked: Tempo.bpm = Tempo.clampBpm(Tempo.bpm - 1)
            }
            ColumnLayout {
                spacing: -4
                TextInput {
                    id: bpmInput
                    Layout.preferredWidth: 76
                    text: Tempo.bpm.toString()
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
                        Tempo.bpm = Tempo.clampBpm(Tempo.bpm + d)
                        text = Tempo.bpm.toString()
                    }
                    FocusRing { radius: 10; gap: 2 }
                    onEditingFinished: {
                        var v = parseInt(text)
                        if (!isNaN(v)) Tempo.bpm = Tempo.clampBpm(v)
                        text = Tempo.bpm.toString()
                    }
                    Connections {
                        target: Tempo
                        function onBpmChanged() {
                            if (!bpmInput.activeFocus)
                                bpmInput.text = Tempo.bpm.toString()
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
                onClicked: Tempo.bpm = Tempo.clampBpm(Tempo.bpm + 1)
            }
        }

        // Les temps de la mesure : le premier en vert, les autres à l'accent.
        Row {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 2
            spacing: 9
            Repeater {
                model: Tempo.beatsPerBar
                Rectangle {
                    id: beatDot
                    required property int index
                    width: 12
                    height: 12
                    radius: 6
                    property bool isActive: Tempo.running && Tempo.beatIndex === index
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
                text: Tempo.beatsPerBar + "/4"
                onClicked: Tempo.setBeats(Tempo.beatsPerBar >= 6 ? 2 : Tempo.beatsPerBar + 1)
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
            accent: Tempo.running
            fontSize: 12
            icon: Qt.resolvedUrl("../assets/icons/" + (Tempo.running ? "stop.svg" : "play.svg"))
            text: Tempo.running ? I18n.tr("common.stop") : I18n.tr("metronome.start")
            onClicked: Tempo.running = !Tempo.running
        }
    }
}
