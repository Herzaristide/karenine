pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import "../services"

// Les volets « son » et « micro » de la barre : les sorties (ou les
// entrées) que PipeWire connaît, celle par défaut surlignée, un clic en
// choisit une autre ; puis le volume de celle-là. Tout suit PipeWire en
// direct : un appareil branché ou un défaut changé ailleurs s'affiche
// aussitôt.
//
//   SORTIE
//   ▣ Haut-parleurs                     ← la sortie par défaut
//   ᛒ Casque
//   ▭ Écran DP-1
//   🔊 ━━━━━━━━━━━●───────  64 %
ColumnLayout {
    id: root

    // true : les entrées (micro), false : les sorties.
    property bool input: false

    spacing: 6

    readonly property PwNode current: root.input ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink
    readonly property bool ready: root.current !== null && root.current.ready && root.current.audio !== null

    // Les appareils, pas les flux des applications.
    readonly property var devices: Pipewire.nodes.values.filter(n => n.audio !== null && !n.isStream
                                                                       && n.isSink === !root.input)

    // Sans suivi, les propriétés audio d'un nœud ne sont jamais renseignées.
    PwObjectTracker {
        objects: [root.current]
    }

    function label(node) {
        return node.description || node.nickname || node.name;
    }

    function choose(node) {
        if (root.input)
            Pipewire.preferredDefaultAudioSource = node;
        else
            Pipewire.preferredDefaultAudioSink = node;
    }

    Text {
        text: root.input ? I18n.tr("settings.sound.input") : I18n.tr("settings.sound.output")
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.8
        font.capitalization: Font.AllUppercase
        color: Theme.textDim
    }

    Repeater {
        model: root.devices

        Rectangle {
            id: row
            required property var modelData
            readonly property bool active: root.current !== null && row.modelData.id === root.current.id

            Layout.fillWidth: true
            implicitHeight: 34
            radius: Theme.radiusSmall
            color: row.active ? Theme.selectedFill : rowMa.containsMouse ? Theme.hoverOverlay : "transparent"
            Behavior on color { ColorAnimation { duration: 140 } }

            NixIcon {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                iconSize: 16
                source: "../assets/ui/" + (root.input ? "mic.svg"
                                              : /blue|bluez/i.test(row.modelData.name) ? "bluetooth.svg"
                                              : /hdmi|displayport/i.test(row.modelData.name) ? "monitor.svg"
                                              : "volume.svg")
                color: row.active ? Theme.accentColor : Theme.textSecondary
            }
            Text {
                anchors.left: rowIcon.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: root.label(row.modelData)
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 13
                font.weight: row.active ? Font.Medium : Font.Normal
                color: Theme.textPrimary
            }
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.choose(row.modelData)
            }
        }
    }

    PopSlider {
        Layout.fillWidth: true
        Layout.topMargin: 4
        enabled: root.ready
        icon: root.ready && root.current.audio.muted ? (root.input ? "mic-mute.svg" : "volume-mute.svg")
                                                     : (root.input ? "mic.svg" : "volume.svg")
        value: root.ready ? root.current.audio.volume : 0
        fill: Theme.accentColor
        label: root.ready && root.current.audio.muted ? I18n.tr("volume.muted")
                                                      : I18n.tr("common.percent", { n: Math.round(shown * 100) })
        // Plafonné à 100 % : au-delà, PipeWire amplifie en logiciel et sature.
        onMoved: (v) => {
            if (root.ready)
                root.current.audio.volume = Math.max(0, Math.min(1, v));
        }
    }
}
