pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// La vue Musique du panneau de droite : le lecteur en tête, puis un seul
// outil à la fois — le métronome, l'accordeur, ou les prises. Un point à
// l'accent marque l'outil qui tourne en fond (le métronome qui bat, un
// enregistrement en cours).
//
//   ╭───────────────────────────╮
//   │   le lecteur (MPRIS)       │
//   ╰───────────────────────────╯
//   ╭ Métronome• │ Accordeur │ Prises ╮
//   │      l'outil choisi        │
//   ╰───────────────────────────╯
ColumnLayout {
    id: root

    spacing: 18

    // L'outil affiché : "metronome", "tuner" ou "takes".
    property string tool: "metronome"

    MusicPlayerWidget {
        Layout.fillWidth: true
        Layout.preferredHeight: 210
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: Theme.radius
        color: Theme.bgElevated

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 10

            // Le choix de l'outil.
            Row {
                id: toolRow
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                spacing: 2

                Repeater {
                    model: [
                        { key: "metronome", label: I18n.tr("metronome.title"), live: Tempo.running },
                        { key: "tuner", label: I18n.tr("tuner.title"), live: false },
                        { key: "takes", label: I18n.tr("record.title"), live: Recorder.audioOn }
                    ]

                    Rectangle {
                        id: toolTab
                        required property var modelData
                        readonly property bool active: root.tool === toolTab.modelData.key

                        width: (toolRow.width - 4) / 3
                        height: toolRow.height
                        radius: Theme.radiusSmall
                        color: toolTab.active ? Theme.bgDeep : toolMa.containsMouse ? Theme.hoverOverlay : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: toolTab.modelData.label
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: toolTab.active ? Font.DemiBold : Font.Medium
                            color: toolTab.active ? Theme.textPrimary : Theme.textSecondary
                        }
                        // Il tourne en fond.
                        Rectangle {
                            visible: toolTab.modelData.live
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.top: parent.top
                            anchors.topMargin: 8
                            width: 6
                            height: 6
                            radius: 3
                            color: Theme.accentColor
                        }
                        MouseArea {
                            id: toolMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.tool = toolTab.modelData.key
                        }
                    }
                }
            }

            // L'outil : seul celui qu'on voit existe (le micro de l'accordeur
            // ne s'ouvre que lui affiché).
            Loader {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 8
                sourceComponent: root.tool === "tuner" ? tunerTool
                               : root.tool === "takes" ? takesTool : metronomeTool
            }
        }
    }

    Component {
        id: metronomeTool
        Item {
            Metronome {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                active: true
                height: Math.min(parent.height, 200)
            }
        }
    }

    Component {
        id: tunerTool
        Item {
            Tuner {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 64
                active: Tuning.on
            }
        }
    }

    Component {
        id: takesTool
        RowLayout {
            spacing: 16
            AudioRecorder {
                id: recorder
                Layout.preferredWidth: 150
                Layout.fillHeight: true
            }
            TakeView {
                recorder: recorder
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
