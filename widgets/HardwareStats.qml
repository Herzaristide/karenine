import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
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

    // ── History buffers for sparkline graphs (40 samples) ──
    readonly property int historySize: 40
    property var cpuHistory: []
    property var ramHistory: []
    property var gpuHistory: []
    property int gpuUsagePercent: 0
    property string cpuTemp: ""
    property string gpuTemp: ""

    // RAM brand info (loaded once, provided by the daemon)
    property string ramBrand: ""

    // Disk grouping and per-disk history
    property var diskHistories: ({})
    property var diskGroups: []   // [{disk, usedPct, history}]
    readonly property var diskColors: Theme.diskSeriesColors

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

    // One series entry per physical disk for the combined disk graph
    readonly property var diskSeries: {
        return hwPanel.diskGroups.map(function(g, i) {
            return { values: g.history, color: hwPanel.diskColors[i % hwPanel.diskColors.length] };
        });
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

    // Extract the physical disk from a partition path
    // e.g. /dev/nvme0n1p2 → /dev/nvme0n1 ; /dev/sda1 → /dev/sda
    function getPhysicalDisk(source) {
        let m = source.match(/^(\/dev\/nvme\d+n\d+)p\d+$/);
        if (m) return m[1];
        m = source.match(/^(\/dev\/[shv]d[a-z]+)\d+$/);
        if (m) return m[1];
        return source;
    }

    onDiskDataChanged: {
        // Aggregate used/total by physical disk
        const groups = {};
        for (const d of diskData) {
            const key = getPhysicalDisk(d.source);
            if (!groups[key]) groups[key] = { usedBytes: 0, totalBytes: 0 };
            groups[key].usedBytes  += d.used;
            groups[key].totalBytes += d.size;
        }
        // Push a new sample into each disk's history
        const histories = Object.assign({}, hwPanel.diskHistories);
        const newGroups = [];
        for (const disk of Object.keys(groups).sort()) {
            const g   = groups[disk];
            const pct = g.totalBytes > 0 ? Math.round((g.usedBytes / g.totalBytes) * 100) : 0;
            const hist = (histories[disk] || []).slice();
            hist.push(Math.max(0, Math.min(100, pct)));
            if (hist.length > hwPanel.historySize) hist.splice(0, 1);
            histories[disk] = hist;
            newGroups.push({ disk: disk, usedPct: pct, history: hist.slice() });
        }
        hwPanel.diskHistories = histories;
        hwPanel.diskGroups    = newGroups;
    }

    // ── Live stats from the anna daemon ──────────────────────────────────
    // All hardware polling (CPU/RAM/GPU/temps/disks) moved out of QML into the
    // native `anna` engine. We open one Unix socket, subscribe with
    // `hwstats_watch`, and receive one JSON snapshot per second. The derived
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
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/anna.sock"
        parser: SplitParser {
            onRead: (line) => {
                try { hwPanel.applyStats(JSON.parse(line)); }
                catch (e) { /* ignore malformed / partial line */ }
            }
        }
        onConnectedChanged: {
            if (connected) write('{"cmd":"hwstats_watch"}\n');
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

    // ── Scrollable content ──────────────────────────────────────────────
    Flickable {
        anchors.fill: parent
        contentHeight: cardColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        ColumnLayout {
            id: cardColumn
            width: parent.width
            spacing: 14

            // ── CPU ──────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "CPU"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                        color: Theme.accentMuted
                        Layout.fillWidth: true
                    }
                    Text {
                        visible: hwPanel.cpuTemp.length > 0
                        text: hwPanel.cpuTemp
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        color: {
                            const v = parseInt(hwPanel.cpuTemp) || 0;
                            return v > 90 ? Theme.colorDanger : v > 70 ? Theme.colorWarning : Theme.colorSuccess;
                        }
                    }
                }

                Text {
                    text: hwPanel.cpuName
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.textPrimary
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        height: 6
                        radius: 3
                        color: Theme.bgDeep
                        Rectangle {
                            width: parent.width * Math.min(hwPanel.cpuUsage / 100.0, 1.0)
                            height: parent.height
                            radius: parent.radius
                            color: hwPanel.cpuUsage > 80 ? Theme.colorDanger
                                 : hwPanel.cpuUsage > 60 ? Theme.colorWarning
                                 : Theme.accentColor
                            Behavior on width { NumberAnimation { duration: 400 } }
                        }
                    }

                    Text {
                        text: hwPanel.cpuUsage + "%"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                    }
                }

            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.bgElevated }

            // ── RAM ──────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "RAM"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 1.5
                    color: Theme.accentMuted
                }

                Text {
                    visible: hwPanel.ramBrand.length > 0
                    text: hwPanel.ramBrand
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    color: Theme.textSecondary
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        height: 6
                        radius: 3
                        color: Theme.bgDeep
                        property real ratio: hwPanel.ramTotalBytes > 0
                            ? hwPanel.ramUsedBytes / hwPanel.ramTotalBytes : 0
                        Rectangle {
                            width: parent.width * Math.min(parent.ratio, 1.0)
                            height: parent.height
                            radius: parent.radius
                            color: parent.ratio > 0.85 ? Theme.colorDanger
                                 : parent.ratio > 0.65 ? Theme.colorWarning
                                 : Theme.colorRam
                            Behavior on width { NumberAnimation { duration: 400 } }
                        }
                    }

                    Text {
                        text: hwPanel.ramTotalBytes > 0
                            ? hwPanel.formatGiB(hwPanel.ramUsedBytes) + " / " + hwPanel.formatGiB(hwPanel.ramTotalBytes)
                            : "..."
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        Layout.preferredWidth: 140
                        horizontalAlignment: Text.AlignRight
                    }
                }

            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.bgElevated }

            // ── GPU ──────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "GPU"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                        color: Theme.accentMuted
                        Layout.fillWidth: true
                    }
                    Text {
                        visible: hwPanel.gpuTemp.length > 0
                        text: hwPanel.gpuTemp
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        color: {
                            const v = parseInt(hwPanel.gpuTemp) || 0;
                            return v > 95 ? Theme.colorDanger : v > 75 ? Theme.colorWarning : Theme.colorSuccess;
                        }
                    }
                }

                Text {
                    text: hwPanel.gpuName
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.textPrimary
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                Text {
                    visible: hwPanel.gpuUsage.length > 0
                    text: hwPanel.gpuUsage
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    color: Theme.textSecondary
                }

                RowLayout {
                    visible: hwPanel.gpuUsage.length > 0
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        height: 6
                        radius: 3
                        color: Theme.bgDeep
                        Rectangle {
                            width: parent.width * Math.min(hwPanel.gpuUsagePercent / 100.0, 1.0)
                            height: parent.height
                            radius: parent.radius
                            color: hwPanel.gpuUsagePercent > 80 ? Theme.colorDanger
                                 : hwPanel.gpuUsagePercent > 60 ? Theme.colorWarning
                                 : Theme.colorGpu
                            Behavior on width { NumberAnimation { duration: 400 } }
                        }
                    }

                    Text {
                        text: hwPanel.gpuUsagePercent + "%"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                    }
                }

            }

            // ── CPU / RAM / GPU — combined graph ─────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: hwPanel.combinedSeries.length > 0

                MiniGraph {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 72
                    series: hwPanel.combinedSeries
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16

                    Repeater {
                        model: [
                            { label: "CPU", value: hwPanel.cpuUsage + "%",
                              color: Theme.accentColor },
                            { label: "RAM", value: hwPanel.ramTotalBytes > 0
                                ? hwPanel.formatGiB(hwPanel.ramUsedBytes) : "...",
                              color: Theme.colorRam },
                            { label: "GPU", value: hwPanel.gpuUsage.length > 0
                                ? hwPanel.gpuUsagePercent + "%" : "—",
                              color: Theme.colorGpu }
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            spacing: 4
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                color: modelData.color
                            }
                            Text {
                                text: modelData.label + " " + modelData.value
                                font.family: "JetBrains Mono"
                                font.pixelSize: 10
                                color: Theme.textSecondary
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.bgElevated }

            // ── Disques ──────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: "Disques"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 1.5
                    color: Theme.accentMuted
                }

                Text {
                    visible: hwPanel.diskData.length === 0
                    text: "Chargement..."
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.textSecondary
                }

                Repeater {
                    model: hwPanel.diskData
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 4

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: modelData.mount
                                font.family: "JetBrains Mono"
                                font.pixelSize: 12
                                color: Theme.textPrimary
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            Text {
                                text: modelData.used + " Go / " + modelData.size + " Go"
                                font.family: "JetBrains Mono"
                                font.pixelSize: 11
                                color: Theme.textSecondary
                            }

                            Text {
                                property real ratio: modelData.size > 0 ? modelData.used / modelData.size : 0
                                text: Math.round(ratio * 100) + "%"
                                font.family: "JetBrains Mono"
                                font.pixelSize: 11
                                color: ratio > 0.85 ? Theme.colorDanger : ratio > 0.65 ? Theme.colorWarning : Theme.textPrimary
                                Layout.preferredWidth: 36
                                horizontalAlignment: Text.AlignRight
                            }

                            Rectangle {
                                width: 22
                                height: 22
                                radius: 4
                                color: openBtn.containsMouse ? Theme.accentDark : "transparent"
                                border.color: openBtn.containsMouse ? Theme.accentColor : Theme.bgElevated
                                border.width: 1

                                Text {
                                    anchors.centerIn: parent
                                    text: "↗"
                                    font.pixelSize: 12
                                    color: openBtn.containsMouse ? Theme.textPrimary : Theme.textSecondary
                                }

                                MouseArea {
                                    id: openBtn
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        hwPanel.openTarget = modelData.mount;
                                        openFolderProc.running = true;
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 5
                            radius: 3
                            color: Theme.bgDeep
                            property real ratio: modelData.size > 0
                                ? modelData.used / modelData.size : 0
                            Rectangle {
                                width: parent.width * Math.min(parent.ratio, 1.0)
                                height: parent.height
                                radius: parent.radius
                                color: parent.ratio > 0.85 ? Theme.colorDanger
                                     : parent.ratio > 0.65 ? Theme.colorWarning
                                     : Theme.colorAltBlue
                            }
                        }

                        Text {
                            text: modelData.source
                            font.family: "JetBrains Mono"
                            font.pixelSize: 10
                            color: Theme.textDim
                        }
                    }
                }

            }

            Item { height: 8 }
        }
    }
}
