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
    property string cpuName: I18n.tr("common.loading")
    property int cpuUsage: 0
    property real ramTotalBytes: 0
    property real ramUsedBytes: 0
    property string gpuName: I18n.tr("common.loading")
    property string gpuUsage: ""
    property bool gpuAsleep: false

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

    // ── La machine relevée ───────────────────────────────────────────────
    // Celle-ci (hwstats_watch), ou un serveur du tailnet : son relevé vient
    // d'anna (servers_watch, par ssh, toutes les 3 s).
    // Le choix est celui de tous les onglets (Widgets.machine).
    readonly property string machine: Widgets.machineName
    readonly property bool remote: hwPanel.machine !== ""
    // Le dernier relevé du serveur ([ServerStats] d'anna), null avant le
    // premier.
    property var server: null

    // Un relevé du serveur est là (en ligne, ssh a répondu).
    readonly property bool measured: !hwPanel.remote
        || (hwPanel.server !== null && hwPanel.server.online && hwPanel.server.ssh && !hwPanel.server.error)

    // Une autre machine : rien de ce qu'on montrait ne vaut pour elle.
    function reset() {
        hwPanel.server = null;
        hwPanel.notice = "";
        hwPanel.cpuHistory = [];
        hwPanel.ramHistory = [];
        hwPanel.gpuHistory = [];
        hwPanel.cpuUsage = 0;
        hwPanel.ramTotalBytes = 0;
        hwPanel.ramUsedBytes = 0;
        hwPanel.cpuTemp = "";
        hwPanel.gpuTemp = "";
        hwPanel.gpuUsagePercent = 0;
    }

    // « actif 3 j », « actif 5 h », « actif 12 min ».
    function formatUptime(s) {
        if (s >= 86400) return I18n.tr("stats.up", { time: I18n.tr("time.days", { n: Math.floor(s / 86400) }) });
        if (s >= 3600) return I18n.tr("stats.up", { time: I18n.tr("time.hours", { n: Math.floor(s / 3600) }) });
        return I18n.tr("stats.up", { time: I18n.tr("time.minutes", { n: Math.max(1, Math.floor(s / 60)) }) });
    }

    // Ce qui s'affiche à droite du choix de la machine.
    readonly property string machineStatus: {
        if (!hwPanel.remote)
            return "";
        if (hwPanel.notice !== "")
            return hwPanel.notice;
        const s = hwPanel.server;
        if (s === null)
            return I18n.tr("stats.measuring");
        if (!s.online)
            return I18n.tr("stats.offline");
        if (s.error)
            return s.error;
        return [s.hostname, hwPanel.formatUptime(s.uptime_s),
I18n.tr("stats.load", { n: s.load1.toLocaleString(I18n.locale, "f", 2) })].filter(x => x).join("  ·  ");
    }

    function applyServer(s) {
        hwPanel.server = s;
        if (!s.online || !s.ssh || s.error)
            return;
        hwPanel.cpuUsage = s.cpu_usage;
        hwPanel.cpuHistory = hwPanel.pushHistory(hwPanel.cpuHistory, s.cpu_usage);
        hwPanel.cpuTemp = s.temp > 0 ? s.temp + "°C" : "";
        hwPanel.ramTotalBytes = s.ram_total;
        hwPanel.ramUsedBytes = s.ram_used;
        if (s.ram_total > 0)
            hwPanel.ramHistory = hwPanel.pushHistory(hwPanel.ramHistory, s.ram_used / s.ram_total * 100);
        // Sa carte graphique : en veille, rien n'est lu (la lire la
        // réveillerait) ; éveillée, anna la relit toutes les 15 s au plus.
        const g = s.gpu;
        hwPanel.gpuTemp = g && !g.asleep && g.temp > 0 ? g.temp + "°C" : "";
        if (g && !g.asleep && g.usage >= 0) {
            hwPanel.gpuUsagePercent = g.usage;
            hwPanel.gpuHistory = hwPanel.pushHistory(hwPanel.gpuHistory, g.usage);
        }
    }

    // Ce que dit la carte graphique du serveur, sous le pourcentage.
    readonly property string serverGpuDetail: {
        const g = hwPanel.server && hwPanel.measured ? hwPanel.server.gpu : null;
        if (!g)
            return "";
        if (g.asleep)
            return I18n.tr("stats.asleep") + " · " + g.name;
        if (g.mem_total > 0 && g.mem_used > 0)
            return hwPanel.formatGiB(g.mem_used) + " / " + hwPanel.formatGiB(g.mem_total) + " · " + g.name;
        return g.name;
    }
    readonly property bool serverGpuLive: hwPanel.remote && hwPanel.measured && !!hwPanel.server.gpu
        && !hwPanel.server.gpu.asleep && hwPanel.server.gpu.usage >= 0

    Socket {
        id: serversSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    const msg = JSON.parse(line);
                    const s = (msg.servers || []).find(x => x.name === hwPanel.machine);
                    if (s)
                        hwPanel.applyServer(s);
                    else if (msg.servers)
                        hwPanel.server = { online: false };
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            // Seulement celui qu'on montre : anna n'interroge pas les autres.
            if (connected) write(JSON.stringify({ cmd: "servers_watch", name: hwPanel.machine }) + "\n");
        }
    }

    // ── Les actions sur le serveur ───────────────────────────────────────
    // Une session ssh dans le terminal du système ; allumer (Wake-on-LAN),
    // éteindre ou redémarrer (ssh), par le client d'anna
    // (anna/src/servers.rs::power). Refusé faute de sudo sans mot de passe :
    // la même commande s'ouvre dans le terminal, pour le taper.
    readonly property var powerSays: ({ on: I18n.tr("power.wakeSent"), off: I18n.tr("power.shuttingDown"), reboot: I18n.tr("power.rebooting") })
    readonly property var powerCommand: ({ off: "sudo systemctl poweroff", reboot: "sudo systemctl reboot" })

    // Ce que la dernière action a donné : il remplace l'état un moment.
    property string notice: ""
    function notify(text) {
        hwPanel.notice = text;
        noticeTimer.restart();
    }
    Timer {
        id: noticeTimer
        interval: 20000
        onTriggered: hwPanel.notice = ""
    }

    function openTerminal() {
        DefaultApps.runInTerminal("", ["ssh", Widgets.machine.host]);
    }

    function power(action) {
        if (powerProc.running || !Widgets.machine)
            return;
        hwPanel.notify(hwPanel.powerSays[action]);
        powerProc.server = Widgets.machine;
        powerProc.action = action;
        powerProc.command = ["anna", "servers", action, Widgets.machine.name];
        powerProc.running = true;
    }

    Process {
        id: powerProc
        property var server: null
        property string action: ""
        stdout: StdioCollector { id: powerOut }
        onRunningChanged: {
            if (running)
                return;
            // Passé à une autre machine entre-temps : la réponse ne la concerne pas.
            const here = powerProc.server.name === hwPanel.machine;
            let r = null;
            try { r = JSON.parse(powerOut.text); } catch (e) { /* anna absent */ }
            let say = "";
            if (!r && powerOut.text.indexOf("Usage") >= 0) {
                // Le client répond par son aide : un anna d'avant ces actions.
                say = I18n.tr("anna.tooOld");
            } else if (!r) {
                say = I18n.tr("anna.noAnswer");
            } else if (!r.ok && hwPanel.powerCommand[powerProc.action] && (r.error || "").indexOf("sudo") >= 0) {
                say = I18n.tr("power.sudoPassword");
                DefaultApps.runInTerminal("", ["ssh", "-t", powerProc.server.host, hwPanel.powerCommand[powerProc.action]]);
            } else if (!r.ok) {
                say = r.error || I18n.tr("common.failedSentence");
            }
            if (here && say !== "")
                hwPanel.notify(say);
        }
    }

    // Redémarrer ou éteindre : le premier appui arme le bouton (en rouge,
    // avec `confirm`) 3 s, le second agit.
    component PowerAction: GlassButton {
        id: pa
        property string action
        property string confirm
        property bool armed: false
        implicitHeight: hwPanel.pickerH
        fontSize: 11
        text: pa.armed ? pa.confirm : ""
        danger: pa.armed
        onActiveFocusChanged: if (!activeFocus) pa.armed = false
        onVisibleChanged: if (!visible) pa.armed = false
        onClicked: {
            if (!pa.armed) {
                pa.armed = true;
                paDisarm.restart();
                return;
            }
            pa.armed = false;
            paDisarm.stop();
            hwPanel.power(pa.action);
        }
        Timer {
            id: paDisarm
            interval: 3000
            onTriggered: pa.armed = false
        }
    }

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
        if (bytes <= 0) return I18n.tr("unit.mb", { n: 0 });
        const gib = bytes / (1024 * 1024 * 1024);
        if (gib >= 0.95) return I18n.tr("unit.gb", { n: gib.toLocaleString(I18n.locale, "f", 1) });
        return I18n.tr("unit.mb", { n: (bytes / (1024 * 1024)).toFixed(0) });
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
    // `hwstats_watch`, and receive one JSON snapshot every 500 ms (the GPU
    // refreshes slower on the daemon side, and not at all while it sleeps). The derived
    // state below (histories, formatting) stays here; the disks are shown by
    // the Explorer (FileExplorer.qml).
    function applyStats(s) {
        // Une ligne arrivée juste après le passage à un serveur.
        if (hwPanel.remote) return;
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
        hwPanel.gpuName = (s.gpu_name && s.gpu_name.length > 0) ? s.gpu_name : I18n.tr("stats.notDetected");
        if (s.gpu_present) {
            hwPanel.gpuUsagePercent = s.gpu_usage;
            hwPanel.gpuUsage = s.gpu_usage + "% — " + I18n.tr("unit.mib", { n: s.gpu_mem_used_mib })
                             + " / " + I18n.tr("unit.mib", { n: s.gpu_mem_total_mib });
            hwPanel.gpuHistory = hwPanel.pushHistory(hwPanel.gpuHistory, s.gpu_usage);
        } else {
            hwPanel.gpuUsage = "";
        }
        // Endormie, anna la laisse dormir : rien n'est lu (la lire la réveillerait).
        hwPanel.gpuAsleep = s.gpu_asleep === true;
        hwPanel.gpuTemp = s.gpu_temp > 0 ? s.gpu_temp + "°C" : "";
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

    // Connect while visible, to the feed of the machine shown (the other one
    // closed); retry every 2 s if the daemon isn't up yet.
    Timer {
        id: connectTimer
        interval: 2000
        running: hwPanel.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const sock = hwPanel.remote ? serversSock : statsSock;
            if (!sock.connected) sock.connected = true;
        }
    }

    onVisibleChanged: {
        if (!visible) {
            statsSock.connected = false;
            serversSock.connected = false;
        }
    }
    // Un autre serveur, ou celle-ci : le flux suivi change.
    onMachineChanged: {
        hwPanel.reset();
        statsSock.connected = false;
        serversSock.connected = false;
        if (hwPanel.visible) connectTimer.restart();
    }

    // ── UI : trois cartes, le pourcentage en grand, la courbe derrière ───
    //   (▣ gary       ▾)       gary · actif 3 j · charge 0,42  (>_) (↻) (⏻)
    //   ╭ ● PROCESSEUR   45°C ╮ ╭ ● MÉMOIRE   ╮ ╭ ● GPU      47°C ╮
    //   │ 8%                  │ │ 27%        │ │ 5%              │
    //   │ i7-11800H      ~~~~~│ │ 4,2 / 15 Go│ │ 907 / 8192 Mio  │
    //   │~~~~~~~~~~~~~~~~~~~~~│ │~~~~~~~~~~~~│ │~~~~~~~~~~~~~~~~~│
    //   ╰─────────────────────╯ ╰────────────╯ ╰─────────────────╯
    //   ╭ ● Pixel 9a  Connecté · 5G ▂▄▆█    (Écran) (Sonner) (Presse-papier) ╮
    //   ╰                                             ━━━━━━━━━━━━  82 % ⚡ ╯
    readonly property int tileH: 150
    readonly property int pickerH: 30
    // La carte du téléphone (PhoneWidget), sous les trois autres.
    readonly property int phoneH: 76

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

    // ── La machine, au-dessus des cartes ─────────────────────────────────
    MachinePicker {
        id: picker
        z: 1
        width: 150
        height: hwPanel.pickerH
    }

    Text {
        anchors.left: picker.right
        anchors.leftMargin: 12
        anchors.right: actions.left
        anchors.rightMargin: 10
        anchors.verticalCenter: picker.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: hwPanel.machineStatus
        elide: Text.ElideRight
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.Medium
        font.features: { "tnum": 1 }
        color: hwPanel.notice === "" && hwPanel.server && hwPanel.server.error ? Theme.colorDanger : Theme.textDim
    }

    // Sur un serveur : en ligne, une session ssh, redémarrer et éteindre (à
    // confirmer) ; hors ligne, le réveil, si son adresse MAC est connue.
    Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: picker.verticalCenter
        spacing: 6
        visible: hwPanel.remote

        GlassButton {
            implicitHeight: hwPanel.pickerH
            fontSize: 11
            icon: Qt.resolvedUrl("../assets/icons/terminal.svg")
            // Aussi quand ssh échoue : on y tape la phrase de passe.
            visible: hwPanel.server !== null && hwPanel.server.online === true
            onClicked: hwPanel.openTerminal()
        }
        PowerAction {
            icon: Qt.resolvedUrl("../assets/icons/reboot.svg")
            confirm: I18n.tr("power.rebootConfirm")
            action: "reboot"
            visible: hwPanel.remote && hwPanel.measured
        }
        PowerAction {
            icon: Qt.resolvedUrl("../assets/icons/power.svg")
            confirm: I18n.tr("power.offConfirm")
            action: "off"
            visible: hwPanel.remote && hwPanel.measured
        }
        GlassButton {
            implicitHeight: hwPanel.pickerH
            fontSize: 11
            icon: Qt.resolvedUrl("../assets/icons/power.svg")
            accent: true
            visible: hwPanel.server !== null && hwPanel.server.online === false
                     && hwPanel.server.can_wake === true
            onClicked: hwPanel.power("on")
        }
    }

    ColumnLayout {
        anchors.topMargin: hwPanel.pickerH + 10
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Tile {
                label: I18n.tr("stats.cpu")
                extra: hwPanel.cpuTemp
                percent: hwPanel.measured ? hwPanel.cpuUsage : -1
                detail: !hwPanel.remote ? hwPanel.cpuName
                      : hwPanel.measured && hwPanel.server.cores > 0 ? I18n.trn("stats.cores", hwPanel.server.cores) : ""
                history: hwPanel.cpuHistory
                tone: Theme.accentColor
            }
            Tile {
                label: I18n.tr("stats.memory")
                extra: hwPanel.remote ? "" : hwPanel.ramBrand
                percent: hwPanel.measured && hwPanel.ramTotalBytes > 0
                         ? Math.round(hwPanel.ramUsedBytes / hwPanel.ramTotalBytes * 100) : -1
                detail: !hwPanel.measured ? ""
                        : hwPanel.formatGiB(hwPanel.ramUsedBytes) + " / " + hwPanel.formatGiB(hwPanel.ramTotalBytes)
                history: hwPanel.ramHistory
                tone: Theme.colorRam
            }
            Tile {
                // Un serveur sans carte graphique (ou pas encore relevé) : rien.
                visible: !hwPanel.remote || (hwPanel.measured && hwPanel.server !== null && !!hwPanel.server.gpu)
                label: I18n.tr("stats.gpu")
                extra: hwPanel.gpuTemp
                percent: hwPanel.remote ? (hwPanel.serverGpuLive ? hwPanel.gpuUsagePercent : -1)
                       : hwPanel.gpuUsage.length > 0 ? hwPanel.gpuUsagePercent : -1
                detail: hwPanel.remote ? hwPanel.serverGpuDetail
                      : hwPanel.gpuUsage.length > 0
                        ? hwPanel.gpuUsage.substring(hwPanel.gpuUsage.indexOf("—") + 2)
                        : hwPanel.gpuAsleep? I18n.tr("stats.asleep") + " · " + hwPanel.gpuName
                        : hwPanel.gpuName
                history: hwPanel.gpuHistory
                tone: Theme.colorGpu
            }
        }

        // Le téléphone, sous les cartes, quelle que soit la machine choisie :
        // c'est celui relié à ce PC.
        PhoneWidget {
            Layout.fillWidth: true
            Layout.preferredHeight: hwPanel.phoneH
        }
    }
}
