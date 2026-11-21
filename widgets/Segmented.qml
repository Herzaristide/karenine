pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Un choix entre quelques options, comme les onglets du panneau : une
// pastille qui glisse sous l'option choisie.
//   options : [{ label, value }] ; `current` : la valeur choisie.
Rectangle {
    id: seg

    property var options: []
    property var current
    signal picked(var value)

    readonly property int index: {
        for (var i = 0; i < seg.options.length; i++)
            if (seg.options[i].value === seg.current)
                return i;
        return -1;
    }
    readonly property real unit: seg.options.length > 0 ? (seg.width - 6 - (seg.options.length - 1) * 2) / seg.options.length : 0

    implicitWidth: 180
    implicitHeight: 30
    radius: Theme.radiusSmall + 2
    color: Qt.alpha(Theme.textPrimary, 0.06)

    Rectangle {
        property real at: Math.max(0, seg.index)
        Behavior on at { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
        x: 3 + at * (seg.unit + 2)
        y: 3
        width: seg.unit
        height: seg.height - 6
        radius: Theme.radiusSmall
        color: Theme.bgDeep
        opacity: seg.index >= 0 ? 1 : 0
    }

    Row {
        x: 3
        y: 3
        spacing: 2
        Repeater {
            model: seg.options
            Item {
                id: opt
                required property var modelData
                required property int index
                readonly property bool active: opt.index === seg.index
                width: seg.unit
                height: seg.height - 6
                Text {
                    anchors.centerIn: parent
                    text: opt.modelData.label
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: opt.active ? Theme.textPrimary : optMa.containsMouse ? Theme.textPrimary : Theme.textSecondary
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
                MouseArea {
                    id: optMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!opt.active) seg.picked(opt.modelData.value)
                }
            }
        }
    }
}
