import QtQuick
import QtQuick.Layouts
import "../services"

// Le lecteur, au milieu du panneau Musique : la forme d'onde de la prise
// choisie dans la colonne de gauche (`recorder`, un AudioRecorder), et sous
// elle, où en est la lecture et ce que dure la prise. Un clic ou un glisser
// sur l'onde y va. Pendant l'enregistrement, l'onde passe au rouge et se
// dessine en direct, avec le temps écoulé et la source.
//
//   ▂▅▇█▇▅▃▂▁▂▃▆█▇▆|▅▃▂▁▁▂▄▆▇▆▄▃▂▁▂▃▅▆▅▃
//   0:42                            2:13
Item {
    id: view

    // L'AudioRecorder de la colonne de gauche : la prise choisie, la lecture.
    required property var recorder
    readonly property bool on: Recorder.audioOn

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Waveform {
                anchors.fill: parent
                live: view.on
                peaks: view.on ? Recorder.live : view.recorder.peaks
                progress: view.recorder.progress
                restColor: view.on ? Qt.alpha(Theme.colorDanger, 0.8) : Qt.alpha(Theme.textPrimary, 0.26)
                onSeek: (fraction) => view.recorder.seek(fraction)
            }
            // Pas de forme d'onde (pas encore lue, ou aucune prise) : une
            // ligne au repos.
            Rectangle {
                visible: !view.on && view.recorder.peaks.length === 0
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 1
                color: Qt.alpha(Theme.textPrimary, 0.12)
            }
        }

        // Où en est la lecture, ce que dure la prise ; en enregistrant, le
        // temps écoulé et la source.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                text: view.on ? Recorder.elapsed(Recorder.audio)
                      : view.recorder.take === null ? ""
                      : Recorder.clock(view.recorder.position)
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: view.on ? Theme.colorDanger : view.recorder.playing ? Theme.textPrimary : Theme.textSecondary
            }
            Item { Layout.fillWidth: true }
            Text {
                text: view.on
                      ? (Recorder.audio && Recorder.audio.mode === "mix" ? I18n.tr("record.mix") : I18n.tr("record.mic"))
                      : view.recorder.take === null ? "" : Recorder.clock(view.recorder.duration)
                font.family: "Inter"
                font.pixelSize: 11
                font.features: { "tnum": 1 }
                color: view.on ? Theme.colorDanger : Theme.textDim
            }
        }
    }
}
