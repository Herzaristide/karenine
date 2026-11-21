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
//
//     (◉) Titre du morceau            • la = 432 Hz     le lecteur, à même
//         Artiste · Album                               le fond : le petit
//     Am                              ╭─ F C G ─╮       disque et le morceau,
//     A · C · E                      Bb   C     D       l'harmonie de ce qui
//     (Dm)(G7)(C)                     ╰ C# F# B ╯       joue, la progression
//     ━━━━━━━●────────────────────────────────          et les commandes ;
//             ⟲    ⏮    ⏯    ⏭    ≡                     centré dans le reste
//
//   ╭ ENREGISTRER ● ─────────────────── (●)(▶)(🎤) ╮
//   │ ▂▅▇█▇▅▃▂▁▂▃▆█▇▆|▅▃▂    16:59           2:13 │   les commandes à
//   │ 0:42          2:13      16:40           1:05 │   droite du titre, la
//   │                         hier 21:12      3:20 │   prise choisie à
//   ╰──────────────────────────────────────────────╯   gauche, les prises
//                                                       à droite
//
// Les cartes du haut et celle du bas ont la même hauteur (`edgeH`) ; le
// lecteur prend ce qui reste, et grandit avec. Tout se règle sur la largeur
// du panneau (340 à 860 px) et sa hauteur : rien ne dépasse. Sur un écran trop bas pour tout, la vue défile.
Flickable {
    id: root

    contentWidth: width
    contentHeight: column.height
    clip: true
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds

    // La largeur des deux cartes du haut, au plus.
    readonly property int cornerMax: 240
    // La hauteur des prises, au moins (le titre, l'onde et les commandes ;
    // les prises, à côté, défilent).
    readonly property int recordMin: 150
    readonly property int pad: 12
    // Les cartes du haut et celle du bas ont la même hauteur : celle qu'il
    // faut à la plus haute. Le lecteur, entre les deux, prend le reste.
    readonly property real edgeH: Math.max(Math.max(metronome.implicitHeight, tuner.implicitHeight) + 2 * root.pad,
                                           root.recordMin)

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

            Card {
                Layout.preferredWidth: tools.cardW
                Layout.preferredHeight: root.edgeH
                // Toute la hauteur commune.
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
                Layout.preferredHeight: root.edgeH
                Tuner {
                    id: tuner
                    anchors.fill: parent
                    anchors.margins: root.pad
                    active: Tuning.on
                }
            }
        }

        // ── Le lecteur, et l'harmonie de ce qui joue ─────────────────
        // Pas de carte : à même le fond, aligné sur le contenu des cartes,
        // centré dans la hauteur qui reste. Plus il y en a, plus la roue
        // et le disque grandissent.
        Item {
            id: middle
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: player.baseHeight

            MusicPlayerWidget {
                id: player
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: root.pad
                anchors.rightMargin: root.pad
                height: implicitHeight
                grow: Math.max(0, Math.min(64, middle.height - player.baseHeight - 2 * root.pad))
            }
        }

        // ── Les prises ───────────────────────────────────────────────
        Card {
            Layout.fillWidth: true
            Layout.preferredHeight: root.edgeH

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root.pad
                spacing: 8

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
                    // Enregistrer, jouer, la source : à droite du titre,
                    // comme le métronome et l'accordeur.
                    AudioRecorder {
                        id: recorder
                        takesHost: takes
                    }
                }
                // L'onde à gauche, les prises à droite.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 14

                    TakeView {
                        recorder: recorder
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    Item {
                        id: takes
                        Layout.fillHeight: true
                        Layout.preferredWidth: Math.max(140, Math.min(260, parent.width * 0.42))
                    }
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
