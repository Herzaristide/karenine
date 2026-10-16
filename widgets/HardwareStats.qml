pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "../services"

Item {
    id: hwPanel

    // ── Hardware data ────────────────────────────────────────────────────
    property string cpuName: "Chargement..."
    property int cpuUsage: 0
    property real ramTotalBytes: 0
    property real ramUsedBytes: 0
    property string gpuName: "Chargement..."
    property string gpuUsage: ""
    property var diskData: []
    property string openTarget: ""

    // ── Historique des courbes : 80 points à 2 Hz, soit 40 s ──
    // (les trois courbes sont des Canvas redessinés en JS à chaque mesure :
    // 2 Hz suffit à l'œil, 4 Hz doublait le travail pour rien)
    readonly property int historySize: 80
    property var cpuHistory: []
    property var ramHistory: []
    property var gpuHistory: []
    property int gpuUsagePercent: 0
    property string cpuTemp: ""
    property string gpuTemp: ""

    // RAM brand info (loaded once, provided by the daemon)
    property string ramBrand: ""

    // ── Disques physiques ────────────────────────────────────────────────
    // anna liste les systèmes de fichiers montés : sur btrfs, chaque
    // sous-volume (/, /nix, /home…) revient avec la taille du volume entier.
    // lsblk relie chaque source (partition, volume chiffré) à son disque :
    // chaque système de fichiers compte une fois, puis on additionne par
    // disque.
    property var blockDevices: ({})   // chemin de la source → { disk, model }
    property var disks: []            // [{ name, label, used, size, mount }]
    // Les sources déjà cherchées dans lsblk sans succès (tmpfs, réseau…).
    property var unknownSources: ({})
    readonly property var diskColors: Theme.diskSeriesColors

    Process {
        id: lsblkProc
        command: ["lsblk", "-J", "-o", "NAME,PATH,TYPE,MODEL"]
        stdout: StdioCollector {
            onStreamFinished: hwPanel.applyLsblk(text)
        }
    }
    Component.onCompleted: lsblkProc.running = true

    function applyLsblk(text) {
        const map = {};
        try {
            const tree = JSON.parse(text).blockdevices || [];
            for (const d of tree) {
                if (d.type !== "disk" || d.name.startsWith("zram"))
                    continue;
                // « Micron_3400_MTFDKBA1T0TFH » → « Micron 3400 ».
                const model = (d.model || "").trim().replace(/_/g, " ").split(/\s+/).slice(0, 2).join(" ");
                const info = { disk: d.name, model: model };
                const walk = (n) => {
                    map[n.path] = info;
                    (n.children || []).forEach(walk);
                };
                walk(d);
            }
        } catch (e) { /* lsblk absent ou sortie inattendue : on garde les sources */ }
        hwPanel.blockDevices = map;
        hwPanel.groupDisks();
    }

    function groupDisks() {
        // Un système de fichiers par source : le point de montage le plus court.
        const bySource = {};
        for (const d of hwPanel.diskData) {
            const prev = bySource[d.source];
            if (!prev || d.mount.length < prev.mount.length)
                bySource[d.source] = d;
        }
        const byDisk = {};
        let missing = false;
        for (const src of Object.keys(bySource)) {
            const fs = bySource[src];
            const dev = hwPanel.blockDevices[src];
            if (!dev && !hwPanel.unknownSources[src]) {
                missing = true;
                hwPanel.unknownSources[src] = true;
            }
            const key = dev ? dev.disk : src;
            if (!byDisk[key])
                byDisk[key] = { name: key, label: dev && dev.model ? dev.model : key.replace(/^\/dev\//, ""),
                                used: 0, size: 0, mount: fs.mount };
            const g = byDisk[key];
            g.used += fs.used;
            g.size += fs.size;
            if (fs.mount.length < g.mount.length)
                g.mount = fs.mount;
        }
        hwPanel.disks = Object.keys(byDisk).sort().map(k => byDisk[k]);
        // Un disque branché depuis : lsblk ne le connaissait pas encore.
        if (missing && !lsblkProc.running)
            lsblkProc.running = true;
    }

    onDiskDataChanged: groupDisks()

    // Combined series for the merged CPU/RAM/GPU graph
    readonly property var combinedSeries: {
        const s = [];
        if (hwPanel.cpuHistory.length > 0)
            s.push({ values: hwPanel.cpuHistory, color: Theme.accentColor });
        if (hwPanel.ramHistory.length > 0)
            s.push({ values: hwPanel.ramHistory, color: Theme.colorRam });
        if (hwPanel.gpuHistory.length > 0 && hwPanel.gpuUsage.length > 0)
            s.push({ values: hwPanel.gpuHistory, color: Theme.colorGpu });
        return s;
    }

    // ── Helpers ──────────────────────────────────────────────────────────
    function formatGiB(bytes) {
        if (bytes <= 0) return "0 Mo";
        const gib = bytes / (1024 * 1024 * 1024);
        if (gib >= 0.95) return gib.toFixed(1) + " Go";
        return (bytes / (1024 * 1024)).toFixed(0) + " Mo";
    }

    function pushHistory(arr, value) {
        const copy = arr.slice();
        copy.push(Math.max(0, Math.min(100, Math.round(value))));
        if (copy.length > hwPanel.historySize) copy.splice(0, 1);
        return copy;
    }

    // ── Live stats from the anna daemon ──────────────────────────────────
    // All hardware polling (CPU/RAM/GPU/temps/disks) moved out of QML into the
    // native `anna` engine. We open one Unix socket, subscribe with
    // `hwstats_watch`, and receive one JSON snapshot every 250 ms (GPU and
    // disks refresh slower on the daemon side, they cost a process). The derived
    // state below (histories, disk grouping, formatting) stays here.
    function applyStats(s) {
        // CPU
        if (s.cpu_name && s.cpu_name.length > 0) hwPanel.cpuName = s.cpu_name;
        hwPanel.cpuUsage   = s.cpu_usage;
        hwPanel.cpuHistory = hwPanel.pushHistory(hwPanel.cpuHistory, s.cpu_usage);
        hwPanel.cpuTemp    = s.cpu_temp > 0 ? s.cpu_temp + "°C" : "";

        // RAM
        hwPanel.ramTotalBytes = s.ram_total;
        hwPanel.ramUsedBytes  = s.ram_used;
        if (s.ram_brand && s.ram_brand.length > 0) hwPanel.ramBrand = s.ram_brand;
        if (s.ram_total > 0)
            hwPanel.ramHistory = hwPanel.pushHistory(hwPanel.ramHistory,
                (s.ram_used / s.ram_total) * 100);

        // GPU
        hwPanel.gpuName = (s.gpu_name && s.gpu_name.length > 0) ? s.gpu_name : "Non détecté";
        if (s.gpu_present) {
            hwPanel.gpuUsagePercent = s.gpu_usage;
            hwPanel.gpuUsage = s.gpu_usage + "% — " + s.gpu_mem_used_mib
                             + " Mio / " + s.gpu_mem_total_mib + " Mio";
            hwPanel.gpuHistory = hwPanel.pushHistory(hwPanel.gpuHistory, s.gpu_usage);
        } else {
            hwPanel.gpuUsage = "";
        }
        hwPanel.gpuTemp = s.gpu_temp > 0 ? s.gpu_temp + "°C" : "";

        // Disks — remap to the {source,size,used,avail,mount} shape the UI and
        // onDiskDataChanged expect (sizes in whole Go, as before).
        const disks = s.disks || [];
        const result = [];
        for (let i = 0; i < disks.length; i++) {
            const d = disks[i];
            result.push({
                source: d.source,
                size:   d.size_gb,
                used:   d.used_gb,
                avail:  d.avail_gb,
                mount:  d.mount
            });
        }
        hwPanel.diskData = result;
    }

    Socket {
        id: statsSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try { hwPanel.applyStats(JSON.parse(line)); }
                catch (e) { /* ignore malformed / partial line */ }
            }
        }
        onConnectedChanged: {
            if (connected) write('{"cmd":"hwstats_watch","interval_ms":500}\n');
        }
    }

    // Connect while visible; retry every 2 s if the daemon isn't up yet.
    Timer {
        interval: 2000
        running: hwPanel.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!statsSock.connected) statsSock.connected = true;
    }

    onVisibleChanged: {
        if (!visible) statsSock.connected = false;
    }

    // ── Open folder in Dolphin ────────────────────────────────────────────
    Process {
        id: openFolderProc
        command: ["dolphin", hwPanel.openTarget]
    }

    // ── UI : trois cartes, le pourcentage en grand, la courbe derrière ───
    //   ╭ ● PROCESSEUR   45°C ╮ ╭ ● MÉMOIRE   ╮ ╭ ● GPU      47°C ╮
    //   │ 8%                  │ │ 27%        │ │ 5%              │
    //   │ i7-11800H      ~~~~~│ │ 4,2 / 15 Go│ │ 907 / 8192 Mio  │
    //   │~~~~~~~~~~~~~~~~~~~~~│ │~~~~~~~~~~~~│ │~~~~~~~~~~~~~~~~~│
    //   ╰─────────────────────╯ ╰────────────╯ ╰─────────────────╯
    //   ( Micron 3400   232 / 953 Go · 24 % ▬▬▬───── )  (un disque, un autre…)
    readonly property int tileH: 150

    component Tile: Rectangle {
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

        Layout.fillWidth: true
        Layout.preferredHeight: hwPanel.tileH
        radius: 20
        color: Qt.alpha(Theme.textPrimary, 0.05)
        border.width: 1
        border.color: Qt.alpha(Theme.textPrimary, 0.08)

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
                fillOpacity: 0.32
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
                font.pixelSize: 60
                font.weight: Font.Light
                font.letterSpacing: -2.5
                font.features: { "tnum": 1 }
                color: Theme.textPrimary
            }
            Text {
                visible: tile.percent >= 0
                anchors.baseline: bigNumber.baseline
                leftPadding: 3
                text: "%"
                font.family: "Inter Display"
                font.pixelSize: 24
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

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Tile {
                label: "Processeur"
                extra: hwPanel.cpuTemp
                percent: hwPanel.cpuUsage
                detail: hwPanel.cpuName
                history: hwPanel.cpuHistory
                tone: Theme.accentColor
            }
            Tile {
                label: "Mémoire"
                extra: hwPanel.ramBrand
                percent: hwPanel.ramTotalBytes > 0
                         ? Math.round(hwPanel.ramUsedBytes / hwPanel.ramTotalBytes * 100) : -1
                detail: hwPanel.formatGiB(hwPanel.ramUsedBytes) + " / " + hwPanel.formatGiB(hwPanel.ramTotalBytes)
                history: hwPanel.ramHistory
                tone: Theme.colorRam
            }
            Tile {
                label: "Carte graphique"
                extra: hwPanel.gpuTemp
                percent: hwPanel.gpuUsage.length > 0 ? hwPanel.gpuUsagePercent : -1
                detail: hwPanel.gpuUsage.length > 0
                        ? hwPanel.gpuUsage.substring(hwPanel.gpuUsage.indexOf("—") + 2)
                        : hwPanel.gpuName
                history: hwPanel.gpuHistory
                tone: Theme.colorGpu
            }
        }

        // Les disques physiques : une pastille chacun ; un clic ouvre son
        // point de montage principal dans Dolphin.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: hwPanel.disks.slice(0, 4)

                Rectangle {
                    id: disk
                    required property var modelData
                    required property int index
                    readonly property real pct: disk.modelData.size > 0 ? disk.modelData.used / disk.modelData.size : 0

                    Layout.fillWidth: true
                    Layout.preferredHeight: 52
                    radius: 16
                    color: Qt.alpha(Theme.textPrimary, diskMa.containsMouse ? 0.09 : 0.05)
                    border.width: 1
                    border.color: Qt.alpha(Theme.textPrimary, 0.08)
                    Behavior on color { ColorAnimation { duration: 140 } }

                    Column {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 9
                        spacing: 6

                        Item {
                            width: parent.width
                            height: mountText.implicitHeight
                            Text {
                                id: mountText
                                width: parent.width - pctText.implicitWidth - 6
                                text: disk.modelData.label
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: Theme.textPrimary
                                elide: Text.ElideMiddle
                            }
                            Text {
                                id: pctText
                                anchors.right: parent.right
                                text: disk.modelData.used + " / " + disk.modelData.size + " Go  ·  " + Math.round(disk.pct * 100) + " %"
                                font.family: "Inter"
                                font.pixelSize: 10
                                color: Theme.textDim
                            }
                        }
                        Rectangle {
                            width: parent.width
                            height: 5
                            radius: 2.5
                            color: Qt.alpha(Theme.textPrimary, 0.1)
                            Rectangle {
                                width: parent.width * disk.pct
                                height: parent.height
                                radius: parent.radius
                                color: hwPanel.diskColors[disk.index % hwPanel.diskColors.length]
                            }
                        }
                    }

                    MouseArea {
                        id: diskMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            hwPanel.openTarget = disk.modelData.mount;
                            openFolderProc.running = true;
                        }
                    }
                }
            }
        }
    }
}
