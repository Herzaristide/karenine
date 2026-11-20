pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// La vue Musique du panneau de droite : tout à la fois, sans onglets.
//
//   ╭ MÉTRONOME   (▶) ╮        ╭ ACCORDEUR  (🎤) ╮   un dans chaque
//   │ (−)  120  (+)   │        │     A4  +3 ¢      │   coin, sur une
//   │     ● ● ● ●     │        │ ┊····┃····┊       │   seule ligne
//   │ ( 4/4 )( Tap )  │        │ 440,0 Hz   A4 440 │
//   ╰─────────────────╯        ╰───────────────────╯
//                    ╭──────╮
//                    │  ◉   │      le lecteur, au centre ; son disque
//                    ╰──────╯      prend la place qui reste, entre
//                 Titre du morceau  96 et 220 px
//                ━━━━━●──────────
//                 ⟲  ⏮  ⏯  ⏭  ≡
//
//   ╭ ENREGISTRER ● ────────────────────────────────╮
//   │ ▂▅▇█▇▅▃▂▁▂▃▆█▇▆|▅▃▂▁▁▂▄▆▇▆▄▃▂               │   la prise choisie,
//   │ (●)(▶)                                  (🎤) │   les commandes, puis
//   │ 16:59                                   2:13 │   les prises
//   ╰──────────────────────────────────────────────╯
//
// Tout se règle sur la largeur du panneau (340 à 860 px) et sa hauteur :
// rien ne dépasse. Sur un écran trop bas pour tout, la vue défile.
Flickable {
    id: root

    contentWidth: width
    contentHeight: column.height
    clip: true
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds

    // La largeur des deux cartes du haut, au plus.
    readonly property int cornerMax: 240
    // La hauteur laissée aux prises, au moins.
    readonly property int recordMin: 210
    readonly property int pad: 12

    ColumnLayout {
        id: column
        width: root.width
        height: Math.max(root.height, implicitHeight)
        spacing: 14

        // ── Le métronome et l'accordeur, un dans chaque coin ─────────
        // Toujours sur une ligne ; au-delà de `cornerMax`, ils restent dans
        // leurs coins et le milieu se libère.
        RowLayout {
            id: tools
            Layout.fillWidth: true
            // L'écart entre les deux cartes est le vide du milieu, pas
            // l'espacement de la ligne : sinon il compte deux fois et la
            // ligne déborde.
            spacing: 0

            readonly property int gap: 12
            readonly property real cardW: Math.min(root.cornerMax, (root.width - tools.gap) / 2)
            readonly property real cardH: Math.max(metronome.implicitHeight, tuner.implicitHeight) + 2 * root.pad

            Card {
                Layout.preferredWidth: tools.cardW
                Layout.preferredHeight: tools.cardH
                Metronome {
                    id: metronome
                    anchors.fill: parent
                    anchors.margins: root.pad
                    active: true
                }
            }
            Item {
                Layout.fillWidth: true
                Layout.minimumWidth: tools.gap
            }
            Card {
                Layout.preferredWidth: tools.cardW
                Layout.preferredHeight: tools.cardH
                Tuner {
                    id: tuner
                    anchors.fill: parent
                    anchors.margins: root.pad
                    active: Tuning.on
                }
            }
        }

        // ── Le lecteur, au centre ────────────────────────────────────
        MusicPlayerWidget {
            id: player
            Layout.fillWidth: true
            Layout.preferredHeight: player.implicitHeight
            Layout.topMargin: 4
            Layout.bottomMargin: 4
            maxDisc: Math.max(96, Math.min(220, root.height - tools.height - root.recordMin
                                                - 2 * column.spacing - 8 - player.chromeHeight))
        }

        // ── Les prises ───────────────────────────────────────────────
        Card {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: root.recordMin

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root.pad
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    SectionTitle {
                        text: I18n.tr("record.title")
                    }
                    // Un enregistrement en cours.
                    Rectangle {
                        visible: Recorder.audioOn
                        implicitWidth: 7
                        implicitHeight: 7
                        radius: 3.5
                        color: Theme.colorDanger
                        SequentialAnimation on opacity {
                            running: Recorder.audioOn
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
                TakeView {
                    recorder: recorder
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56
                }
                AudioRecorder {
                    id: recorder
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
            }
        }
    }

    // Une carte : l'aplat surélevé, arrondi.
    component Card: Rectangle {
        radius: Theme.radius
        color: Theme.bgElevated
    }
}
