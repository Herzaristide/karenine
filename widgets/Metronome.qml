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

    // ── UI : une petite carte, dans le coin haut gauche du panneau Musique ─
    //   MÉTRONOME     (▶)
    //   (−)  120  (+)
    //       ● ● ● ●          les temps : le premier en vert
    //   ( 4/4 )( Tap )
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
                text: I18n.tr("metronome.title")
            }
            // Lancer, arrêter.
            GlassButton {
                implicitWidth: 26
                implicitHeight: 26
                accent: Tempo.running
                icon: Qt.resolvedUrl("../assets/icons/" + (Tempo.running ? "stop.svg" : "play.svg"))
                onClicked: Tempo.running = !Tempo.running
            }
        }

        // Le tempo, en grand, entre ses deux boutons ; les temps dessous.
        RowLayout {
            Layout.fillWidth: true
            spacing: 0

            GlassButton {
                implicitWidth: 24
                implicitHeight: 24
                fontSize: 14
                text: "−"
                onClicked: Tempo.bpm = Tempo.clampBpm(Tempo.bpm - 1)
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                TextInput {
                    id: bpmInput
                    Layout.fillWidth: true
                    text: Tempo.bpm.toString()
                    font.family: "Inter"
                    font.pixelSize: 24
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: Tempo.running ? Theme.textPrimary : Theme.textSecondary
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
                    FocusRing { radius: 8; gap: 2 }
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
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 5
                    Repeater {
                        model: Tempo.beatsPerBar
                        Rectangle {
                            id: beatDot
                            required property int index
                            width: 6
                            height: 6
                            radius: 3
                            property bool isActive: Tempo.running && Tempo.beatIndex === index
                            color: isActive
                                   ? (index === 0 ? Theme.colorSuccess : Theme.glow(0))
                                   : Qt.alpha(Theme.textPrimary, index === 0 ? 0.22 : 0.1)
                            Behavior on color { ColorAnimation { duration: 80 } }
                            SequentialAnimation on scale {
                                running: beatDot.isActive
                                NumberAnimation { to: 1.4; duration: 60; easing.type: Easing.OutCubic }
                                NumberAnimation { to: 1.0;  duration: 220; easing.type: Easing.OutQuint }
                            }
                        }
                    }
                }
            }
            GlassButton {
                implicitWidth: 24
                implicitHeight: 24
                fontSize: 14
                text: "+"
                onClicked: Tempo.bpm = Tempo.clampBpm(Tempo.bpm + 1)
            }
        }

        // La mesure (2 → 3 → 4 → 5 → 6 → 2) et le tap tempo.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            GlassButton {
                Layout.fillWidth: true
                implicitHeight: 24
                fontSize: 11
                text: Tempo.beatsPerBar + "/4"
                onClicked: Tempo.setBeats(Tempo.beatsPerBar >= 6 ? 2 : Tempo.beatsPerBar + 1)
            }
            GlassButton {
                Layout.fillWidth: true
                implicitHeight: 24
                fontSize: 11
                text: I18n.tr("metronome.tapShort")
                onClicked: metroPanel.tapTempo()
            }
        }
    }
}
