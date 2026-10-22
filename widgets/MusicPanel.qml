import QtQuick
import QtQuick.Layouts
import "../services"

// L'onglet Musique : un seul pupitre de travail, en trois colonnes, sans
// cloisons. À gauche, les commandes de l'enregistreur et les prises ; au
// milieu, l'accordeur (qui se coupe) puis le lecteur (la forme d'onde de la
// prise choisie) ; à droite, le métronome.
//
//   ╭──────────────────────────────────────────────────────────────╮
//   │ (●)(▶)   (🎤)  (♪)  A4  ┊ · · ┃ · · ┊        (−) 120 (+)      │
//   │ 16:59    2:13      +3 ¢ 440,0 Hz  A4 = 440          bpm        │
//   │ 16:40    1:05  ▂▅▇█▇▅▃▂▁▂▃▆█▇▆|▅▃▂▁▁▂▄▆▇▆▄▃       ● ● ● ●      │
//   │ hier 21:12 3:20                                 (4/4) (Tap)    │
//   │ 18/10 09:30 0:41 0:42                    2:13                  │
//   │                                                (  ▶ Lancer  )  │
//   ╰──────────────────────────────────────────────────────────────╯
Item {
    id: music

    // Le micro de l'accordeur et le flux du métronome ne s'ouvrent que
    // lorsque l'onglet se montre.
    property bool active: true

    implicitHeight: 196

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 24

        AudioRecorder {
            id: recorder
            Layout.preferredWidth: 156
            Layout.fillHeight: true
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 18

            // Coupé (son bouton), l'accordeur n'ouvre pas le micro.
            Tuner {
                active: music.active && Tuning.on
                Layout.fillWidth: true
                Layout.preferredHeight: 64
            }
            TakeView {
                recorder: recorder
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }

        Metronome {
            active: music.active
            Layout.preferredWidth: 150
            Layout.fillHeight: true
        }
    }
}
