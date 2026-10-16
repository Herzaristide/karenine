pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"

// L'onglet « Network » : les autres appareils du réseau Tailscale, une tuile
// chacun, en largeur (anna/src/servers.rs). La liste est celle de Tailscale,
// relue toutes les 3 s : un appareil qui rejoint le réseau apparaît seul.
// Les Linux en ligne sont interrogés par ssh, sans rien installer sur eux ;
// les autres (téléphone…) montrent leur état, leur système et leur adresse.
//
//   ╭ ● gary         45°C ╮ ╭ ● Pixel 9a          ╮
//   │ gary · actif 3 j    │ │ android · 100.71…   │
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


    // Les fichiers d'un appareil : Dolphin sait parler sftp.
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

    // Depuis quand un appareil hors ligne n'a pas été vu.
    function formatSeen(iso) {
        var t = Date.parse(iso || "");
        if (isNaN(t) || t <= 0)
            return "";
        var s = Math.max(0, (Date.now() - t) / 1000);
        if (s < 3600)
            return "vu il y a " + Math.max(1, Math.round(s / 60)) + " min";
        if (s < 86400)
            return "vu il y a " + Math.round(s / 3600) + " h";
        return "vu il y a " + Math.round(s / 86400) + " j";
    }

    // Prêt à montrer ses relevés : en ligne, et ssh a répondu.
    function measured(srv) {
        return srv.online && srv.ssh && !srv.error;
    }

    // La ligne sous le nom.
    function subtitle(srv) {
        if (root.measured(srv))
            return [srv.hostname, root.formatUptime(srv.uptime_s)].filter(t => t).join("  ·  ");
        if (!srv.online)
            return ["Hors ligne", root.formatSeen(srv.last_seen)].filter(t => t).join("  ·  ");
        if (srv.error)
            return root.explain(srv);
        return [srv.os, srv.ip].filter(t => t).join("  ·  ");
    }

    // Les erreurs de ssh les plus courantes, dites simplement.
    function explain(srv) {
        var e = srv.error || "";
        if (e.indexOf("Permission denied") >= 0)
            return "Clé refusée : lance « ssh " + srv.host + " » une fois pour la charger dans l'agent.";
        if (e.indexOf("No route to host") >= 0 || e.indexOf("timed out") >= 0 || e === "délai dépassé")
            return "Injoignable : éteint ou hors du réseau.";
        if (e.indexOf("Could not resolve") >= 0)
            return "Hôte inconnu : vérifie que MagicDNS est actif.";
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
            readonly property bool measured: root.measured(tile.modelData)
            // En ligne pour Tailscale, mais ssh a échoué : son erreur à la place.
            readonly property bool failed: tile.modelData.online && tile.modelData.error !== ""

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
                        color: !tile.modelData.online ? Theme.colorDanger
                             : tile.failed ? Theme.colorWarning : Theme.colorSuccess
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
                        text: tile.measured && tile.modelData.temp > 0 ? tile.modelData.temp + "°C" : ""
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textDim
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: root.subtitle(tile.modelData)
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: tile.failed ? Theme.colorDanger : Theme.textDim
                    elide: Text.ElideRight
                    maximumLineCount: tile.failed ? 3 : 1
                    wrapMode: tile.failed ? Text.Wrap : Text.NoWrap
                }

                Meter {
                    visible: tile.measured
                    label: "Processeur" + (tile.modelData.cores > 0 ? " · " + tile.modelData.cores + " cœurs" : "")
                    value: tile.modelData.cpu_usage + " %"
                    ratio: tile.modelData.cpu_usage / 100
                    tone: Theme.accentColor
                }
                Meter {
                    visible: tile.measured
                    label: "Mémoire"
                    value: root.formatBytes(tile.modelData.ram_used) + " / " + root.formatBytes(tile.modelData.ram_total)
                    ratio: tile.modelData.ram_total > 0 ? tile.modelData.ram_used / tile.modelData.ram_total : 0
                    tone: Theme.colorRam
                }
                Meter {
                    visible: tile.measured && tile.disk !== null
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
                    visible: tile.measured
                    onClicked: {
                        filesProc.target = tile.modelData.host;
                        filesProc.running = true;
                    }
                }
            }
        }
    }

    // Seul sur le réseau, ou Tailscale arrêté.
    Text {
        anchors.centerIn: parent
        visible: root.loaded && root.servers.length === 0
        text: "Aucun autre appareil sur le réseau Tailscale."
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }
}
