pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../services"

// Le volet « alimentation » de la barre : verrouiller, mettre en veille,
// quitter, redémarrer, éteindre, en une rangée. Les deux derniers demandent
// un second clic dans les trois secondes (le premier arme le bouton, qui
// pose sa question).
Row {
    id: root

    // Avant de verrouiller ou de dormir : la barre se vide (champ, volets).
    signal leaving()

    spacing: 4

    property string armed: ""
    Timer {
        running: root.armed !== ""
        interval: 3000
        onTriggered: root.armed = ""
    }

    function run(item) {
        if (item.confirm && root.armed !== item.key) {
            root.armed = item.key;
            return;
        }
        root.armed = "";
        if (item.leave)
            root.leaving();
        Quickshell.execDetached(item.command);
    }

    Repeater {
        model: [
            { key: "lock", icon: "lock.svg", label: "power.lock", leave: true, command: ["loginctl", "lock-session"] },
            { key: "suspend", icon: "suspend.svg", label: "power.suspend", leave: true, command: ["systemctl", "suspend"] },
            { key: "logout", icon: "logout.svg", label: "power.logout", command: ["hyprctl", "dispatch", "hl.dsp.exit()"] },
            { key: "reboot", icon: "reboot.svg", label: "power.reboot", confirm: "power.rebootConfirm", command: ["systemctl", "reboot"] },
            { key: "off", icon: "power.svg", label: "power.off", confirm: "power.offConfirm", command: ["systemctl", "poweroff"] }
        ]

        Rectangle {
            id: cell
            required property var modelData
            readonly property bool armed: root.armed === cell.modelData.key

            width: 72
            height: 64
            radius: Theme.radiusSmall + 2
            color: cell.armed ? Qt.alpha(Theme.colorDanger, 0.18)
                 : cellMa.containsMouse ? Theme.hoverOverlay : "transparent"
            Behavior on color { ColorAnimation { duration: 160 } }
            scale: cellMa.pressed ? 0.95 : 1
            Behavior on scale { NumberAnimation { duration: 120 } }

            Column {
                anchors.centerIn: parent
                spacing: 7

                NixIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    iconSize: 18
                    source: "../assets/ui/" + cell.modelData.icon
                    color: cell.armed ? Theme.colorDanger : Theme.iconColor
                    opacity: cell.armed || cellMa.containsMouse ? 1 : 0.8
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: I18n.tr(cell.armed ? cell.modelData.confirm : cell.modelData.label)
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.weight: cell.armed ? Font.DemiBold : Font.Medium
                    color: cell.armed ? Theme.colorDanger : Theme.textSecondary
                }
            }

            MouseArea {
                id: cellMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(cell.modelData)
            }
        }
    }
}
