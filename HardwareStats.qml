import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io

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

    // RAM brand info (loaded once)
    property string ramBrand: ""
    property bool ramBrandLoaded: false

    // CPU delta state
    property real prevCpuTotal: 0
    property real prevCpuActive: 0
    property bool cpuNameLoaded: false

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

    // ── Refresh timer ────────────────────────────────────────────────────
    Timer {
        id: refreshTimer
        interval: 1000
        running: hwPanel.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!hwPanel.cpuNameLoaded && !cpuNameProc.running)
                cpuNameProc.running = true;
            if (!hwPanel.ramBrandLoaded && !ramBrandProc.running)
                ramBrandProc.running = true;
            if (!cpuStatProc.running) cpuStatProc.running = true;
            if (!ramProc.running) ramProc.running = true;
            if (!gpuProc.running) gpuProc.running = true;
            if (!diskProc.running) diskProc.running = true;
            if (!tempProc.running) tempProc.running = true;
        }
    }

    onVisibleChanged: {
        if (!visible) {
            prevCpuTotal = 0;
            prevCpuActive = 0;
        }
    }

    // ── CPU model name (run once) ────────────────────────────────────────
    Process {
        id: cpuNameProc
        command: ["sh", "-c", "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//'"]
        stdout: StdioCollector { id: cpuNameOut }
        onRunningChanged: {
            if (!running) {
                const n = cpuNameOut.text.trim();
                if (n.length > 0) {
                    hwPanel.cpuName = n;
                    hwPanel.cpuNameLoaded = true;
                }
            }
        }
    }

    // ── RAM brand (run once via dmidecode) ──────────────────────────────
    Process {
        id: ramBrandProc
        command: [
            "sh", "-c",
            "sudo dmidecode -t memory 2>/dev/null | awk '"
            + "/Memory Device/ {found=1; pn=\"\"; typ=\"\"; spd=\"\"; hasmod=0} "
            + "found && /^\\s*Size:/ && !/No Module/ {hasmod=1} "
            + "found && hasmod && /Part Number:/ && !/Not Specified/ {sub(/.*Part Number:[[:space:]]*/,\"\"); pn=$0} "
            + "found && hasmod && /^[[:space:]]+Type:/ && !/Unknown/ {sub(/.*Type:[[:space:]]*/,\"\"); typ=$0} "
            + "found && hasmod && /Configured.*Speed:/ && !/Unknown/ {sub(/.*Configured.*Speed:[[:space:]]*/,\"\"); spd=$0} "
            + "found && /^$/ {if(hasmod && pn) {printf \"%s %s %s\\n\", pn, typ, spd; found=0; hasmod=0}} "
            + "' | sort -u | head -1 | sed 's/[[:space:]]*$//'"
        ]
        stdout: StdioCollector { id: ramBrandOut }
        onRunningChanged: {
            if (!running) {
                const n = ramBrandOut.text.trim();
                if (n.length > 0) {
                    hwPanel.ramBrand = n;
                    hwPanel.ramBrandLoaded = true;
                }
            }
        }
    }

    // ── CPU usage ───────────────────────────────────────────────────────
    Process {
        id: cpuStatProc
        command: ["sh", "-c", "head -1 /proc/stat"]
        stdout: StdioCollector { id: cpuStatOut }
        onRunningChanged: {
            if (!running) {
                const parts = cpuStatOut.text.trim().split(/\s+/);
                const user    = parseFloat(parts[1]) || 0;
                const nice    = parseFloat(parts[2]) || 0;
                const system  = parseFloat(parts[3]) || 0;
                const idle    = parseFloat(parts[4]) || 0;
                const iowait  = parseFloat(parts[5]) || 0;
                const irq     = parseFloat(parts[6]) || 0;
                const softirq = parseFloat(parts[7]) || 0;
                const total   = user + nice + system + idle + iowait + irq + softirq;
                const active  = total - idle - iowait;
                if (hwPanel.prevCpuTotal > 0) {
                    const dTotal  = total - hwPanel.prevCpuTotal;
                    const dActive = active - hwPanel.prevCpuActive;
                    hwPanel.cpuUsage = dTotal > 0 ? Math.round((dActive / dTotal) * 100) : 0;
                    hwPanel.cpuHistory = hwPanel.pushHistory(hwPanel.cpuHistory, hwPanel.cpuUsage);
                }
                hwPanel.prevCpuTotal  = total;
                hwPanel.prevCpuActive = active;
            }
        }
    }

    // ── RAM ──────────────────────────────────────────────────────────────
    Process {
        id: ramProc
        command: ["sh", "-c", "grep -E '^(MemTotal|MemAvailable):' /proc/meminfo"]
        stdout: StdioCollector { id: ramOut }
        onRunningChanged: {
            if (!running) {
                const lines = ramOut.text.trim().split('\n');
                let total = 0, available = 0;
                for (const line of lines) {
                    const m = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/);
                    if (m) {
                        if (m[1] === "MemTotal")     total     = parseInt(m[2]) * 1024;
                        else                         available = parseInt(m[2]) * 1024;
                    }
                }
                hwPanel.ramTotalBytes = total;
                hwPanel.ramUsedBytes  = total - available;
                if (total > 0)
                    hwPanel.ramHistory = hwPanel.pushHistory(hwPanel.ramHistory,
                        (hwPanel.ramUsedBytes / total) * 100);
            }
        }
    }

    // ── GPU ──────────────────────────────────────────────────────────────
    Process {
        id: gpuProc
        command: [
            "sh", "-c",
            "out=$(nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null); " +
            "if [ -n \"$out\" ]; then echo \"$out\"; " +
            "else " +
            "name=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | head -1 | sed 's/.*: //' | sed 's/ (.*//'); " +
            "dev=''; for h in /sys/class/hwmon/hwmon*; do [ \"$(cat $h/name 2>/dev/null)\" = 'amdgpu' ] && dev=\"$h/device\" && break; done; " +
            "if [ -n \"$dev\" ]; then " +
            "util=$(cat \"$dev/gpu_busy_percent\"); " +
            "vram_used_b=$(cat \"$dev/mem_info_vram_used\" 2>/dev/null || echo 0); " +
            "vram_total_b=$(cat \"$dev/mem_info_vram_total\" 2>/dev/null || echo 0); " +
            "vram_used=$(( vram_used_b / 1048576 )); " +
            "vram_total=$(( vram_total_b / 1048576 )); " +
            "echo \"$name,$util,$vram_used,$vram_total\"; " +
            "else echo \"$name\"; fi; fi"
        ]
        stdout: StdioCollector { id: gpuOut }
        onRunningChanged: {
            if (!running) {
                const text = gpuOut.text.trim();
                if (text.length === 0) {
                    hwPanel.gpuName  = "Non détecté";
                    hwPanel.gpuUsage = "";
                    return;
                }
                const parts = text.split(',');
                if (parts.length >= 4) {
                    hwPanel.gpuName  = parts.slice(0, parts.length - 3).join(',').trim();
                    const util       = parseInt(parts[parts.length - 3]) || 0;
                    const memUsed    = parseInt(parts[parts.length - 2]) || 0;
                    const memTotal   = parseInt(parts[parts.length - 1]) || 0;
                    hwPanel.gpuUsage        = util + "% — " + memUsed + " Mio / " + memTotal + " Mio";
                    hwPanel.gpuUsagePercent = util;
                    hwPanel.gpuHistory      = hwPanel.pushHistory(hwPanel.gpuHistory, util);
                } else {
                    hwPanel.gpuName  = text;
                    hwPanel.gpuUsage = "";
                }
            }
        }
    }

    // ── Open folder in Dolphin ────────────────────────────────────────────
    Process {
        id: openFolderProc
        command: ["dolphin", hwPanel.openTarget]
    }

    // ── Temperatures ─────────────────────────────────────────────────────
    Process {
        id: tempProc
        command: [
            "sh", "-c",
            "cpu_t=''; " +
            "for d in /sys/class/hwmon/hwmon*; do " +
            "  n=$(cat \"$d/name\" 2>/dev/null); " +
            "  if [ \"$n\" = 'k10temp' ] || [ \"$n\" = 'coretemp' ]; then " +
            "    raw=$(cat \"$d/temp2_input\" 2>/dev/null || cat \"$d/temp1_input\" 2>/dev/null); " +
            "    [ -n \"$raw\" ] && cpu_t=$(( raw / 1000 )); break; " +
            "  fi; " +
            "done; " +
            "gpu_t=''; " +
            "for d in /sys/class/hwmon/hwmon*; do " +
            "  n=$(cat \"$d/name\" 2>/dev/null); " +
            "  if [ \"$n\" = 'amdgpu' ]; then " +
            "    raw=$(cat \"$d/temp2_input\" 2>/dev/null || cat \"$d/temp1_input\" 2>/dev/null); " +
            "    [ -n \"$raw\" ] && gpu_t=$(( raw / 1000 )); break; " +
            "  fi; " +
            "done; " +
            "[ -z \"$gpu_t\" ] && gpu_t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); " +
            "echo \"${cpu_t},${gpu_t}\""
        ]
        stdout: StdioCollector { id: tempOut }
        onRunningChanged: {
            if (!running) {
                const parts = tempOut.text.trim().split(',');
                const c = parts[0] ? parts[0].trim() : "";
                const g = parts[1] ? parts[1].trim() : "";
                hwPanel.cpuTemp = (c.length > 0 && c !== "0") ? c + "°C" : "";
                hwPanel.gpuTemp = (g.length > 0 && g !== "0") ? g + "°C" : "";
            }
        }
    }

    // ── Disques ──────────────────────────────────────────────────────────
    Process {
        id: diskProc
        command: [
            "sh", "-c",
            "df -BG --output=source,size,used,avail,target -x tmpfs -x devtmpfs -x efivarfs -x overlay 2>/dev/null | tail -n +2"
        ]
        stdout: StdioCollector { id: diskOut }
        onRunningChanged: {
            if (!running) {
                const lines = diskOut.text.trim().split('\n');
                const result = [];
                for (const line of lines) {
                    const trimmed = line.trim();
                    if (!trimmed) continue;
                    const p = trimmed.split(/\s+/);
                    if (p.length >= 5) {
                        const mount = p[4];
                        if (mount === "/boot" || mount.startsWith("/boot/")) continue;
                        const size = parseInt(p[1]) || 0;
                        const used = parseInt(p[2]) || 0;
                        if (size > 0) {
                            result.push({
                                source: p[0],
                                size:   size,
                                used:   used,
                                avail:  parseInt(p[3]) || 0,
                                mount:  mount
                            });
                        }
                    }
                }
                hwPanel.diskData = result;
            }
        }
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
