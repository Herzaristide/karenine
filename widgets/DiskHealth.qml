pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

// Les disques de cette machine dans les réglages, chacun avec sa santé :
// ce qu'anna relève pour la flotte (servers_watch, réduit à cette machine),
// les disques de lsblk (node-extras) et leur SMART (smartctl_exporter).
//
//   [disque]  Micron 3400                          ( Bon état )
//             NVMe · / · 412 Go / 1 To · usure 3 % · 41 °C · 2 340 h
//
// La pastille : bon état (vert), à surveiller (usure ≥ 80 %, ou plus de
// 70 °C), défaillant (SMART en échec, rouge), inconnu (pas de SMART : un
// disque USB, ou smartctl_exporter qui ne peut pas le lire).
SettingsSection {
    id: root

    title: I18n.tr("disks.title")

    // Le nom sous lequel anna range cette machine : celui de Tailscale,
    // sinon le hostname.
    property string kernelHost: ""
    readonly property string machine: Tailscale.hostName !== "" ? Tailscale.hostName : root.kernelHost

    property var drives: []
    property bool loaded: false

    FileView {
        path: "/proc/sys/kernel/hostname"
        blockLoading: true
        onLoaded: root.kernelHost = text().trim()
    }

    Socket {
        id: sock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg.servers === undefined)
                        return;
                    var me = msg.servers.find(s => s.local);
                    if (me && me.measured) {
                        root.drives = me.drives || [];
                        root.loaded = true;
                    }
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            // Cette machine seule : anna n'interroge pas les autres.
            if (connected)
                write(JSON.stringify({ cmd: "servers_watch", name: root.machine }) + "\n");
        }
    }

    // Affichée seulement : cachée, plus rien ne tourne.
    readonly property bool active: root.visible && root.machine !== ""
    onActiveChanged: if (!root.active) sock.connected = false
    onMachineChanged: sock.connected = false
    Timer {
        interval: 3000
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!sock.connected) sock.connected = true
    }

    // 412 Go, 1,9 To.
    function bytes(b) {
        var gb = b / 1e9;
        return gb >= 1000 ? I18n.tr("unit.tb", { n: (gb / 1000).toLocaleString(I18n.locale, "f", 1) })
                          : I18n.tr("unit.gb", { n: Math.round(gb) });
    }

    // "ok", "watch", "failing" ou "unknown".
    function health(s) {
        if (!s)
            return "unknown";
        if (!s.ok)
            return "failing";
        if (s.wear >= 80 || s.temp >= 70)
            return "watch";
        return "ok";
    }

    // smartctl_exporter tourne mais ne lit aucun disque fixe : le plus
    // souvent un droit qui manque sur /dev/nvme*.
    readonly property bool noSmart: root.loaded && root.drives.length > 0
                                    && root.drives.every(d => !d.smart || d.removable)
                                    && root.drives.some(d => !d.removable)

    SettingsRow {
        visible: !root.loaded || root.drives.length === 0
        icon: "disk.svg"
        title: !root.loaded ? I18n.tr("common.loading") : I18n.tr("disks.none")
    }

    Repeater {
        model: root.drives

        SettingsRow {
            id: row
            required property var modelData
            readonly property var smart: row.modelData.smart || null
            readonly property string health: root.health(row.smart)
            readonly property color tone: row.health === "failing" ? Theme.colorDanger
                                        : row.health === "watch" ? Theme.colorWarning
                                        : row.health === "ok" ? Theme.colorSuccess
                                        : Theme.textDim
            // Son point de montage principal, comme dans la flotte.
            readonly property string main: (row.modelData.mounts || []).find(
                m => m.indexOf("/boot") !== 0 && m.indexOf("/efi") !== 0
                     && m.indexOf("/nix/store") !== 0) || ""

            icon: "disk.svg"
            title: row.modelData.model
            subtitle: [row.modelData.kind]
                .concat(row.main !== "" ? [row.main] : [])
                .concat([row.modelData.fs_size > 0
                         ? root.bytes(row.modelData.fs_used) + " / " + root.bytes(row.modelData.fs_size)
                         : root.bytes(row.modelData.size)])
                .concat(row.smart && row.smart.wear >= 0 ? [I18n.tr("fleet.wear", { n: row.smart.wear })] : [])
                .concat(row.smart && row.smart.temp >= 0 ? [row.smart.temp + " °C"] : [])
                .concat(row.smart && row.smart.hours > 0
                        ? [I18n.tr("time.hours", { n: row.smart.hours.toLocaleString(I18n.locale, "f", 0) })] : [])
                .join("  ·  ")
            // Un clic le montre dans l'Explorer.
            clickable: row.main !== ""
            onClicked: Widgets.explorerShowDisk("", "", row.main)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: pill.implicitWidth + 16
                implicitHeight: 22
                radius: 11
                color: Qt.alpha(row.tone, 0.16)
                Text {
                    id: pill
                    anchors.centerIn: parent
                    text: row.health === "failing" ? I18n.tr("disks.failing")
                        : row.health === "watch" ? I18n.tr("disks.watch")
                        : row.health === "ok" ? I18n.tr("disks.ok")
                        : I18n.tr("disks.unknown")
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    color: row.tone
                }
            }
        }
    }

    // Sans SMART pour aucun disque fixe : pourquoi, et ce qui le règle.
    Item {
        Layout.fillWidth: true
        visible: root.noSmart
        implicitHeight: hint.implicitHeight + 16
        TextEdit {
            id: hint
            x: 12
            y: 8
            width: parent.width - 24
            readOnly: true
            selectByMouse: true
            text: I18n.tr("disks.noSmart", { cmd: "sudo udevadm trigger --action=add --subsystem-match=nvme" })
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textSecondary
            wrapMode: Text.Wrap
        }
    }
}
