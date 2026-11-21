import QtQuick
import "../services"

// Une icône de assets/ui qui change en fondu enchaîné : quand `icon` change
// (le son coupé, la batterie en charge…), l'ancienne s'efface en se tassant
// pendant que la nouvelle se pose d'un léger rebond. Deux emplacements
// alternent : celui qui reçoit la nouvelle icône monte, l'autre s'en va.
Item {
    id: root

    property string icon
    property color color: Theme.iconColor
    property real iconOpacity: 1
    property int iconSize: 18

    implicitWidth: root.iconSize
    implicitHeight: root.iconSize

    property bool front: true
    property string iconA: root.icon
    property string iconB: ""
    onIconChanged: {
        if (root.front)
            root.iconB = root.icon;
        else
            root.iconA = root.icon;
        root.front = !root.front;
    }

    component Slot: NixIcon {
        id: slot
        property bool shown: false
        property real baseOpacity: 1
        anchors.centerIn: parent
        anchors.verticalCenterOffset: slot.shown ? 0 : 3
        opacity: slot.shown ? slot.baseOpacity : 0
        scale: slot.shown ? 1 : 0.7
        visible: opacity > 0
        Behavior on color { ColorAnimation { duration: 220 } }
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
        Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    }

    Slot {
        shown: root.front
        iconSize: root.iconSize
        color: root.color
        baseOpacity: root.iconOpacity
        source: root.iconA !== "" ? "../assets/ui/" + root.iconA : ""
    }
    Slot {
        shown: !root.front
        iconSize: root.iconSize
        color: root.color
        baseOpacity: root.iconOpacity
        source: root.iconB !== "" ? "../assets/ui/" + root.iconB : ""
    }
}
