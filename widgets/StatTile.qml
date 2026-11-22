pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import "../services"

// Une tuile de mesure, celle des stats de la machine (HardwareStats) et du
// lockscreen : la pastille et l'intitulé, le pourcentage en grand, un détail
// dessous, et la courbe qui remplit le fond, coupée aux coins arrondis.
//
//   ╭ ● PROCESSEUR   45°C ╮
//   │ 8%                  │
//   │ i7-11800H           │
//   │~~~~~~~~~~~~~~~~~~~~~│
//   ╰─────────────────────╯
Rectangle {
    id: tile
    property string label
    property string extra
    property int percent: -1          // -1 : pas de mesure
    // Le nombre affiché glisse vers la nouvelle mesure au lieu de sauter.
    property real shown: Math.max(0, percent)
    Behavior on shown { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    property string detail
    property var history: []
    property color tone: Theme.accentColor

    // La taille du pourcentage : 60 dans le panneau, moins dans une
    // tuile étroite (le lockscreen).
    property int bigSize: 60

    Layout.fillWidth: true
    implicitHeight: 150
    radius: Theme.radius
    color: Qt.alpha(Theme.textPrimary, 0.05)

    // La courbe occupe toute la carte, coupée à ses coins arrondis :
    // 100 % touche le haut, 0 % le bas.
    Item {
        id: graphLayer
        anchors.fill: parent
        visible: false
        layer.enabled: true
        MiniGraph {
            anchors.fill: parent
            anchors.topMargin: 12
            values: tile.history
            lineColor: tile.tone
            fillOpacity: 0.12
        }
    }
    Rectangle {
        id: tileShape
        anchors.fill: parent
        radius: tile.radius
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        anchors.fill: parent
        source: graphLayer
        maskEnabled: true
        maskSource: tileShape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        opacity: 0.85
    }

    // En-tête : pastille de couleur, intitulé, température.
    Row {
        id: header
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: 16
        anchors.topMargin: 14
        spacing: 7
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 6; height: 6; radius: 3
            color: tile.tone
        }
        Text {
            text: tile.label.toUpperCase()
            font.family: "Inter"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.letterSpacing: 1.4
            color: Theme.textSecondary
        }
    }
    Text {
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.verticalCenter: header.verticalCenter
        text: tile.extra
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.Medium
        font.features: { "tnum": 1 }
        color: Theme.textDim
    }

    // Le pourcentage, en grand.
    Row {
        id: bigValue
        anchors.left: parent.left
        anchors.top: header.bottom
        anchors.leftMargin: 14
        anchors.topMargin: 2
        Text {
            id: bigNumber
            text: tile.percent >= 0 ? Math.round(tile.shown) : "—"
            font.family: "Inter Display"
            font.pixelSize: tile.bigSize
            font.weight: Font.Light
            font.letterSpacing: -tile.bigSize / 24
            font.features: { "tnum": 1 }
            color: Theme.textPrimary
        }
        Text {
            visible: tile.percent >= 0
            anchors.baseline: bigNumber.baseline
            leftPadding: 3
            text: "%"
            font.family: "Inter Display"
            font.pixelSize: Math.round(tile.bigSize * 0.4)
            font.weight: Font.Normal
            color: tile.tone
        }
    }

    Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: bigValue.bottom
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.topMargin: -4
        text: tile.detail
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.Medium
        color: Theme.textSecondary
        elide: Text.ElideRight
    }
}
