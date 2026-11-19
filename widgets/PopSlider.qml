import QtQuick
import "../services"

// Un curseur fin, celui des volets de la barre : l'icône de ce qu'il règle,
// la piste et sa partie remplie, le bouton, la valeur en pourcentage.
// Pendant le glisser il suit la souris, puis retombe sur la valeur réelle ;
// la molette le règle de 5 en 5.
Item {
    id: slider

    property string icon
    property real value: 0
    property color fill: Theme.textSecondary
    property string label: I18n.tr("common.percent", { n: Math.round(slider.shown * 100) })
    property real dragValue: -1
    readonly property real shown: dragValue >= 0 ? dragValue : Math.max(0, Math.min(1, value))
    signal moved(real v)

    implicitWidth: 260
    implicitHeight: 28

    NixIcon {
        id: glyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconSize: 16
        source: "../assets/ui/" + slider.icon
        color: Theme.textSecondary
    }

    Text {
        id: valueText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 40
        horizontalAlignment: Text.AlignRight
        text: slider.label
        font.family: "Inter"
        font.pixelSize: 12
        font.features: { "tnum": 1 }
        color: Theme.textSecondary
    }

    Item {
        id: trackArea
        anchors.left: glyph.right
        anchors.leftMargin: 12
        anchors.right: valueText.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        height: 18

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 4
            radius: 2
            color: Theme.dividerColor
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: track.width * slider.shown
            height: track.height
            radius: track.radius
            color: slider.fill
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: slider.shown * (trackArea.width - width)
            width: 14
            height: 14
            radius: 7
            color: slider.fill
            border.width: 2
            border.color: Theme.bgDeep
            scale: knob.pressed ? 1.15 : 1
            Behavior on scale { NumberAnimation { duration: 100 } }
        }

        MouseArea {
            id: knob
            anchors.fill: parent
            anchors.topMargin: -8
            anchors.bottomMargin: -8
            preventStealing: true
            cursorShape: Qt.PointingHandCursor

            function follow(mx) {
                slider.dragValue = Math.max(0, Math.min(1, (mx - 7) / Math.max(1, trackArea.width - 14)));
                slider.moved(slider.dragValue);
            }
            onPressed: (mouse) => follow(mouse.x)
            onPositionChanged: (mouse) => follow(mouse.x)
            onReleased: slider.dragValue = -1
            onWheel: (wheel) => slider.moved(Math.max(0, Math.min(1, slider.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))))
        }
    }
}
