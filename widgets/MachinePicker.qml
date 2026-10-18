pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../services"

// Le choix de la machine, partagé par l'Explorer et l'onglet Système :
// celle-ci, ou un serveur du tailnet qu'on atteint par ssh (la liste
// d'anna, `anna servers list`). Une pastille au nom de la machine
// montrée ; un clic déroule la liste des autres, un clic ailleurs la
// referme.
//
//   (▣ zola       ▾)
//   ╭──────────────────╮
//   │ ● zola     local │
//   │ ● gary     linux │
//   │ ● nas  hors ligne│
//   ╰──────────────────╯
//
// Le choix est le même pour tous les onglets (Widgets.machine) : chacun le
// suit de son côté (monter le serveur, suivre ses relevés…).
Item {
    id: picker

    // Le serveur montré (son nom), "" pour cette machine.
    readonly property string current: Widgets.machineName
    // Le serveur en train d'être rejoint (son nom), ou "" : la pastille
    // l'annonce et la liste attend.
    property string busy: ""
    // Où poser la liste et la zone qui la referme : tout le widget, pour
    // qu'un clic n'importe où dedans la ferme.
    property Item overlay: picker.parent
    property int menuWidth: picker.width + 40

    property bool open: false
    property string localName: ""
    // Les serveurs qu'on atteint par ssh ([Server] d'anna).
    property var servers: []

    readonly property string localLabel: picker.localName || "Cet ordinateur"

    function choose(entry) {
        picker.open = false;
        Widgets.machine = entry.local ? null : { name: entry.name, host: entry.host };
    }

    // La liste des serveurs, relue à chaque ouverture.
    Process {
        id: serversProc
        command: ["anna", "servers", "list"]
        running: true
        stdout: StdioCollector {
            id: serversOut
            onStreamFinished: {
                try {
                    picker.servers = JSON.parse(serversOut.text).filter(s => s.host !== "");
                } catch (e) { /* anna absent */ }
            }
        }
    }
    Process {
        command: ["cat", "/proc/sys/kernel/hostname"]
        running: true
        stdout: StdioCollector {
            id: hostOut
            onStreamFinished: picker.localName = hostOut.text.trim()
        }
    }

    // ── La pastille ──────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.alpha(Theme.glow(0), switchMa.containsMouse || picker.open ? 0.24 : 0.16)
        border.width: 1
        border.color: Qt.alpha(Theme.glow(0), 0.38)
        Behavior on color { ColorAnimation { duration: 140 } }

        Image {
            id: switchIcon
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            height: 18
            source: Quickshell.iconPath(picker.current !== "" ? "network-server" : "computer", true)
                    || Quickshell.iconPath("folder", true)
            sourceSize.width: 36
            sourceSize.height: 36
            asynchronous: true
        }

        Text {
            anchors.left: switchIcon.right
            anchors.leftMargin: 8
            anchors.right: chevron.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: picker.busy !== "" ? picker.busy + "…"
                : picker.current !== "" ? picker.current : picker.localLabel
            elide: Text.ElideRight
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: Theme.textPrimary
        }

        Text {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "▾"
            rotation: picker.open ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textSecondary
        }

        MouseArea {
            id: switchMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                picker.open = !picker.open;
                if (picker.open && !serversProc.running)
                    serversProc.running = true;
            }
        }
    }

    // ── La liste des machines ────────────────────────────────────
    // Un clic ailleurs la referme.
    MouseArea {
        parent: picker.overlay
        anchors.fill: parent
        z: 9
        visible: picker.open
        onClicked: picker.open = false
    }

    Rectangle {
        id: machineMenu
        parent: picker.overlay
        z: 10
        x: picker.x
        y: picker.y + picker.height + 4
        width: picker.menuWidth
        height: Math.min(menuList.contentHeight + 12, picker.overlay.height - y)
        visible: picker.open
        radius: 16
        color: Qt.alpha(Theme.bgDeep, 0.96)
        border.width: 1
        border.color: Qt.alpha(Theme.textPrimary, 0.12)

        // Celle-ci d'abord, puis les serveurs.
        readonly property var entries: [{ name: picker.localLabel, local: true, online: true }]
            .concat(picker.servers)

        ListView {
            id: menuList
            anchors.fill: parent
            anchors.margins: 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: machineMenu.entries

            delegate: Item {
                id: entry
                required property var modelData
                readonly property bool local: entry.modelData.local === true
                readonly property bool here: entry.local ? picker.current === ""
                                                         : picker.current === entry.modelData.name
                readonly property bool reachable: entry.local || entry.modelData.online
                width: ListView.view.width
                height: 32
                opacity: entry.reachable ? 1 : 0.45

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: entry.here ? Qt.alpha(Theme.glow(0), 0.16)
                                      : Qt.alpha(Theme.textPrimary, entryMa.containsMouse && entry.reachable ? 0.07 : 0)
                    border.width: entry.here ? 1 : 0
                    border.color: Qt.alpha(Theme.glow(0), 0.38)
                }

                // En ligne ou non.
                Rectangle {
                    id: entryDot
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7
                    height: 7
                    radius: 3.5
                    color: entry.reachable ? Theme.colorSuccess : Theme.textDim
                }

                Text {
                    anchors.left: entryDot.right
                    anchors.leftMargin: 9
                    anchors.right: entryKind.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    text: entry.modelData.name
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: entry.here ? Font.DemiBold : Font.Medium
                    color: entry.here ? Theme.textPrimary : Theme.textSecondary
                }

                Text {
                    id: entryKind
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: entry.local ? "local" : entry.modelData.online ? (entry.modelData.os || "") : "hors ligne"
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }

                MouseArea {
                    id: entryMa
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: entry.reachable && picker.busy === ""
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picker.choose(entry.modelData)
                }
            }
        }
    }
}
