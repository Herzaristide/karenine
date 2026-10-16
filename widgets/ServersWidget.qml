pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"

// Les serveurs suivis par anna (anna/src/servers.rs) : une tuile chacun, en
// largeur. anna les interroge par ssh toutes les 3 s, sans rien installer sur
// eux. Les ajouter ou les retirer se fait dans les réglages (ServerSettings),
// ou avec `anna servers add <nom> [hôte]`.
//
//   ╭ ● gary         45°C ╮ ╭ ● kafka             ╮
//   │ gary · actif 3 j    │ │ injoignable         │
//   │ Processeur  ▬▬── 12%│ │                     │
//   │ Mémoire     ▬▬▬─ 3 Go│ │                     │
//   │ Disque      ▬─── 24%│ │                     │
//   │ ( Fichiers )        │ │                     │
//   ╰─────────────────────╯ ╰─────────────────────╯
Item {
    id: root

    // [ServerStats] : le dernier relevé d'anna.
    property var servers: []
    // Reçu au moins une fois : avant, la liste vide ne veut rien dire.
    property bool loaded: false

    readonly property int tileW: 214

    // ── Le relevé, en continu ────────────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg.servers !== undefined) {
                        root.servers = msg.servers;
                        root.loaded = true;
                    }
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"servers_watch"}\n');
        }
    }

    // Se connecte tant qu'il est affiché ; réessaie si anna n'est pas là.
    Timer {
        interval: 2000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!watchSock.connected) watchSock.connected = true
    }
    onVisibleChanged: if (!visible) watchSock.connected = false


    // Les fichiers d'un serveur : Dolphin sait parler sftp.
    Process {
        id: filesProc
        property string target: ""
        command: ["dolphin", "--new-window", "sftp://" + filesProc.target + "/"]
    }

    // ── Petits éléments ──────────────────────────────────────────
    function formatBytes(b) {
        if (b <= 0)
            return "0";
        var g = b / (1024 * 1024 * 1024);
        if (g >= 1000)
            return (g / 1024).toFixed(1) + " To";
        if (g >= 0.95)
            return g.toFixed(g >= 100 ? 0 : 1) + " Go";
        return (b / (1024 * 1024)).toFixed(0) + " Mo";
    }

    function formatUptime(s) {
        if (s <= 0)
            return "";
        var d = Math.floor(s / 86400);
        var h = Math.floor((s % 86400) / 3600);
        if (d > 0)
            return "actif " + d + " j " + h + " h";
        var m = Math.floor((s % 3600) / 60);
        return "actif " + h + " h " + m + " min";
    }

    // Les erreurs de ssh les plus courantes, dites simplement.
    function explain(srv) {
        var e = srv.error || "";
        if (e.indexOf("Permission denied") >= 0)
            return "Clé refusée : lance « ssh " + srv.host + " » une fois pour la charger dans l'agent.";
        if (e.indexOf("No route to host") >= 0 || e.indexOf("timed out") >= 0 || e === "délai dépassé")
            return "Injoignable : éteint ou hors du réseau.";
        if (e.indexOf("Could not resolve") >= 0)
            return "Hôte inconnu : vérifie le nom ou ~/.ssh/config.";
        if (e.indexOf("Host key verification failed") >= 0)
            return "Empreinte inconnue : lance « ssh " + srv.host + " » une fois pour l'accepter.";
        return e || "Injoignable.";
    }

    // Le plus grand disque : celui qu'on regarde d'abord.
    function mainDisk(srv) {
        var best = null;
        for (var i = 0; i < (srv.disks || []).length; i++)
            if (!best || srv.disks[i].size > best.size)
                best = srv.disks[i];
        return best;
    }

    component Meter: Item {
        id: meter
        property string label
        property string value
        property real ratio: 0
        property color tone: Theme.glow(0)

        Layout.fillWidth: true
        implicitHeight: 26

        Text {
            text: meter.label
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textSecondary
        }
        Text {
            anchors.right: parent.right
            text: meter.value
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.Medium
            color: Theme.textPrimary
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 5
            radius: 2.5
            color: Qt.alpha(Theme.textPrimary, 0.1)
            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, meter.ratio))
                height: parent.height
                radius: parent.radius
                color: meter.tone
                Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            }
        }
    }

    // ── Les tuiles ───────────────────────────────────────────────
    ListView {
        id: list
        anchors.fill: parent
        orientation: ListView.Horizontal
        spacing: 10
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.servers
        // La molette fait défiler les tuiles de côté.
        WheelHandler {
            onWheel: (event) => {
                list.contentX = Math.max(0, Math.min(list.contentWidth - list.width,
                                                     list.contentX - event.angleDelta.y));
            }
        }

        delegate: Rectangle {
            id: tile
            required property var modelData
            readonly property var disk: root.mainDisk(tile.modelData)

            width: root.tileW
            height: list.height
            radius: 18
            color: Qt.alpha(Theme.textPrimary, 0.05)
            border.width: 1
            border.color: Qt.alpha(Theme.textPrimary, 0.08)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 6

                // Le nom, l'état, la température.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: tile.modelData.online ? Theme.colorSuccess : Theme.colorDanger
                        Behavior on color { ColorAnimation { duration: 300 } }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: tile.modelData.name
                        font.family: "Inter"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        color: Theme.textPrimary
                        elide: Text.ElideRight
                    }
                    Text {
                        text: tile.modelData.temp > 0 ? tile.modelData.temp + "°C" : ""
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textDim
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: tile.modelData.online
                          ? [tile.modelData.hostname, root.formatUptime(tile.modelData.uptime_s)]
                                .filter(t => t).join("  ·  ")
                          : root.explain(tile.modelData)
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: tile.modelData.online ? Theme.textDim : Theme.colorDanger
                    elide: Text.ElideRight
                    maximumLineCount: tile.modelData.online ? 1 : 3
                    wrapMode: tile.modelData.online ? Text.NoWrap : Text.Wrap
                }

                Meter {
                    visible: tile.modelData.online
                    label: "Processeur" + (tile.modelData.cores > 0 ? " · " + tile.modelData.cores + " cœurs" : "")
                    value: tile.modelData.cpu_usage + " %"
                    ratio: tile.modelData.cpu_usage / 100
                    tone: Theme.accentColor
                }
                Meter {
                    visible: tile.modelData.online
                    label: "Mémoire"
                    value: root.formatBytes(tile.modelData.ram_used) + " / " + root.formatBytes(tile.modelData.ram_total)
                    ratio: tile.modelData.ram_total > 0 ? tile.modelData.ram_used / tile.modelData.ram_total : 0
                    tone: Theme.colorRam
                }
                Meter {
                    visible: tile.modelData.online && tile.disk !== null
                    label: "Disque"
                    value: tile.disk ? root.formatBytes(tile.disk.used) + " / " + root.formatBytes(tile.disk.size) : ""
                    ratio: tile.disk && tile.disk.size > 0 ? tile.disk.used / tile.disk.size : 0
                    tone: Theme.colorGpu
                }

                Item { Layout.fillHeight: true }

                GlassButton {
                    Layout.alignment: Qt.AlignLeft
                    implicitHeight: 28
                    fontSize: 11
                    text: "Fichiers"
                    visible: tile.modelData.online
                    onClicked: {
                        filesProc.target = tile.modelData.host;
                        filesProc.running = true;
                    }
                }
            }
        }
    }

    // Aucun serveur : dire où en ajouter.
    Text {
        anchors.centerIn: parent
        visible: root.loaded && root.servers.length === 0
        text: "Aucun serveur suivi : ajoute-en un dans les réglages."
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }
}
