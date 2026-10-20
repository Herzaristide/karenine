import QtQuick
import QtQuick.Layouts
import "../services"

// L'enregistrement du son, sous l'accordeur (onglet Musique). anna le tient
// (services/Recorder.qml, anna/src/recorder.rs) : il continue quand l'onglet
// se ferme, et s'arrête d'ici, par son raccourci ou par `anna record stop`.
// Deux sources : le micro seul, ou le micro avec ce que joue l'ordinateur
// (jouer par-dessus un morceau). Le fichier va dans le dossier Musique, en FLAC.
//
//   Idle :         Enregistrer        [● Micro] [● Micro + ordinateur]
//   En cours :     ● 1:05  Micro                          [■ Arrêter]
Item {
    id: recPanel

    implicitHeight: 44

    readonly property bool on: Recorder.audioOn

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 8

        // Au repos : ce que font les boutons.
        Text {
            visible: !recPanel.on
            Layout.alignment: Qt.AlignVCenter
            text: I18n.tr("record.title")
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textDim
        }

        // En cours : un point rouge, le temps écoulé, la source.
        Rectangle {
            visible: recPanel.on
            Layout.alignment: Qt.AlignVCenter
            width: 8
            height: 8
            radius: 4
            color: Theme.colorDanger
            // Bat doucement, comme le voyant d'un enregistreur.
            SequentialAnimation on opacity {
                running: recPanel.on
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
        Text {
            visible: recPanel.on
            Layout.alignment: Qt.AlignVCenter
            text: Recorder.elapsed(Recorder.audio)
            font.family: "Inter"
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: Theme.colorDanger
        }
        Text {
            visible: recPanel.on
            Layout.alignment: Qt.AlignVCenter
            text: Recorder.audio && Recorder.audio.mode === "mix"
                  ? I18n.tr("record.mix") : I18n.tr("record.mic")
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textDim
        }

        Item { Layout.fillWidth: true }

        GlassButton {
            visible: !recPanel.on
            enabled: Recorder.available
            icon: Qt.resolvedUrl("../assets/icons/record.svg")
            text: I18n.tr("record.mic")
            onClicked: Recorder.toggleAudio("mic")
        }
        GlassButton {
            visible: !recPanel.on
            enabled: Recorder.available
            icon: Qt.resolvedUrl("../assets/icons/record.svg")
            text: I18n.tr("record.mix")
            onClicked: Recorder.toggleAudio("mix")
        }
        GlassButton {
            visible: recPanel.on
            danger: true
            icon: Qt.resolvedUrl("../assets/icons/stop.svg")
            text: I18n.tr("record.stop")
            onClicked: Recorder.stop("audio")
        }
    }
}
