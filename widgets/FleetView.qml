pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

// La vue Système du panneau de droite : toute la flotte, une carte par
// machine, celle-ci d'abord, toutes relevées de la même façon par leur
// node_exporter (servers_watch, chaque seconde ; celle-ci sur 127.0.0.1). Sur
// chaque carte : le processeur, la mémoire et la carte graphique ; puis ses
// disques physiques, un par un, remplis à l'accent.
//
//   ╭ ● zola  ce PC                                   ╮
//   │ CPU 4 %      RAM 31 %      GPU —               │
//   │ ▭ Micron 3400  NVMe · /             280 / 953 Go │
//   │ ━━━━━━━━──────────────────────────────────────── │
//   │ ● ComfyUI arrêté   ● Ollama actif                │
//   ╰─────────────────────────────────────────────────╯
Flickable {
    id: root

    contentHeight: column.implicitHeight + 8
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    // Les machines Linux du tailnet, celle-ci d'abord (`local`).
    property var servers: []
    property bool serversLoaded: false
    // Les cartes suivent les machines par leur nom : un relevé met à jour
    // celles qui restent sans les recréer (cf. KeyedModel). Le survol, le
    // focus et la liste des services dépliée tiennent.
    property var byName: ({})
    KeyedModel { id: cards }
    function setServers(list) {
        var map = {};
        list.forEach(s => map[s.name] = s);
        root.servers = list;
        cards.sync(list.map(s => s.name), () => root.byName = map);
    }

    // Les dernières valeurs du processeur, par machine, pour la courbe.
    property var history: ({})
    function remember(name, v) {
        var h = root.history;
        var list = (h[name] || []).concat([v]);
        if (list.length > 40)
            list = list.slice(list.length - 40);
        h[name] = list;
        root.history = h;
    }

    Socket {
        id: serversSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg.servers === undefined)
                        return;
                    root.setServers(msg.servers.filter(s => s.os === "linux"));
                    root.serversLoaded = true;
                    msg.servers.forEach(s => {
                        if (s.measured && !s.error)
                            root.remember(s.name, s.cpu_usage);
                    });
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: if (connected) write('{"cmd":"servers_watch"}\n')
    }

    // Affichée seulement : cachée, plus rien ne tourne.
    Timer {
        interval: 3000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!serversSock.connected)
                serversSock.connected = true;
        }
    }
    onVisibleChanged: if (!visible) serversSock.connected = false

    // « actif 3 j », « actif 5 h », « actif 12 min ».
    function uptime(s) {
        if (!s)
            return "";
        if (s >= 86400) return I18n.tr("stats.up", { time: I18n.tr("time.days", { n: Math.floor(s / 86400) }) });
        if (s >= 3600) return I18n.tr("stats.up", { time: I18n.tr("time.hours", { n: Math.floor(s / 3600) }) });
        return I18n.tr("stats.up", { time: I18n.tr("time.minutes", { n: Math.max(1, Math.floor(s / 60)) }) });
    }

    // 280 Go, 1,9 To.
    function bytes(b) {
        var gb = b / 1e9;
        return gb >= 1000 ? I18n.tr("unit.tb", { n: (gb / 1000).toLocaleString(I18n.locale, "f", 1) })
                          : I18n.tr("unit.gb", { n: Math.round(gb) });
    }

    // 230 Mo, 1,4 Go : la mémoire d'un conteneur.
    function mem(b) {
        return b >= 1e9 ? I18n.tr("unit.gb", { n: (b / 1e9).toLocaleString(I18n.locale, "f", 1) })
                        : I18n.tr("unit.mb", { n: Math.round(b / 1e6) });
    }

    // « 21 nov. 2026 » d'une date « 2026-11-21 ».
    function day(iso) {
        var p = (iso || "").split("-").map(Number);
        return p.length === 3 ? new Date(p[0], p[1] - 1, p[2]).toLocaleDateString(I18n.locale, "d MMM yyyy") : "";
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function act(args) {
        Quickshell.execDetached(["anna", "servers"].concat(args));
    }

    // Une carte de machine, la même pour celle-ci et pour les autres.
    // `m` : { name, online, error, uptime, cpu, temp, ramUsed, ramTotal,
    //         gpu: { asleep, usage, used, total } | null, drives, osName, nixpkgsRev, nixpkgsDate,
    //         onBattery, watts, containers, failed: ["backup.service"], systemd,
    //         host, canWake, lastSeen, remote }
    component MachineCard: Rectangle {
        id: card
        required property var m
        readonly property bool up: card.m.online && !card.m.error
        // La liste des services en échec, dépliée par leur bouton.
        property bool showFailed: false

        Layout.fillWidth: true
        implicitHeight: cardCol.implicitHeight + 26
        radius: Theme.radius
        color: Theme.bgElevated
        opacity: card.m.online ? 1 : 0.7

        ColumnLayout {
            id: cardCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 13
            spacing: 11

            // ── L'en-tête : l'état, le nom, depuis quand ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Rectangle {
                    implicitWidth: 8
                    implicitHeight: 8
                    radius: 4
                    color: card.up ? Theme.colorSuccess : card.m.online ? Theme.colorWarning : Theme.textDim
                }
                Text {
                    text: card.m.name
                    font.family: "Inter"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: Theme.textPrimary
                }
                Item { Layout.fillWidth: true }
                Text {
                    Layout.maximumWidth: cardCol.width * 0.5
                    elide: Text.ElideRight
                    text: !card.m.online ? I18n.tr("stats.offline")
                        : card.m.error ? card.m.error
                        : root.uptime(card.m.uptime)
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: card.m.error ? Theme.colorWarning : Theme.textSecondary
                }
                // Ses services systemd : une pastille verte à zéro, rouge
                // avec le nombre en échec, qui déplie leur liste sous
                // l'en-tête. Cachée sans le collecteur systemd (inconnu).
                Rectangle {
                    id: failedPill
                    readonly property int n: card.m.failed.length
                    readonly property color tone: n > 0 ? Theme.colorDanger : Theme.colorSuccess
                    visible: card.up && card.m.systemd
                    implicitWidth: Math.max(implicitHeight, failedText.implicitWidth + 14)
                    implicitHeight: 20
                    radius: implicitHeight / 2
                    color: Qt.alpha(tone, failedMa.containsMouse && n > 0 ? 0.32 : 0.2)
                    Behavior on color { ColorAnimation { duration: 180 } }
                    Text {
                        id: failedText
                        anchors.centerIn: parent
                        text: failedPill.n
                        font.family: "Inter"
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.features: { "tnum": 1 }
                        color: failedPill.tone
                    }
                    MouseArea {
                        id: failedMa
                        anchors.fill: parent
                        enabled: failedPill.n > 0
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.showFailed = !card.showFailed
                    }
                }
                // Une session dans le terminal, et l'alimentation : en ssh
                // pour une autre machine, ici même pour celle-ci.
                BarButton {
                    visible: card.up
                    size: 26
                    icon: "terminal.svg"
                    onClicked: {
                        if (card.m.remote)
                            DefaultApps.runInTerminal("", ["ssh", card.m.host]);
                        else
                            DefaultApps.openInTerminal(Quickshell.env("HOME") || "");
                    }
                }
                BarButton {
                    visible: card.up
                    size: 26
                    icon: "power.svg"
                    onClicked: powerMenu.visible = !powerMenu.visible
                }
            }

            // ── Le système et ce qu'il consomme ──
            // « NixOS 26.11 (Zokor) · nixpkgs 2786a2a · 21 nov. 2026 », et à
            // droite les watts : la batterie quand elle se décharge (toute la
            // machine), sinon le processeur (RAPL).
            RowLayout {
                visible: card.up && (card.m.osName !== "" || card.m.watts >= 0)
                Layout.fillWidth: true
                Layout.topMargin: -6
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: [card.m.osName].concat(card.m.nixpkgsRev !== ""
                              ? [I18n.tr("fleet.nixpkgs", { rev: card.m.nixpkgsRev }), root.day(card.m.nixpkgsDate)]
                              : []).filter(x => x).join("  ·  ")
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textDim
                }
                Text {
                    visible: card.m.watts >= 0
                    text: I18n.tr(card.m.onBattery ? "fleet.wattsBattery" : "fleet.wattsCpu",
                                  { n: Math.round(card.m.watts) })
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: Theme.textSecondary
                }
            }

            // ── Les services en échec ──
            //   ● backup.service
            // Un clic ouvre son journal (depuis le démarrage) dans le terminal.
            ColumnLayout {
                visible: card.up && card.showFailed && card.m.failed.length > 0
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: I18n.tr("fleet.failed")
                    font.family: "Inter"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.8
                    font.capitalization: Font.AllUppercase
                    color: Theme.colorDanger
                }

                Repeater {
                    model: card.m.failed

                    RowLayout {
                        id: unit
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        HoverHandler {
                            id: unitHover
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            onTapped: {
                                var argv = ["journalctl", "-b", "-e", "-u", unit.modelData];
                                DefaultApps.runInTerminal("", card.m.remote
                                    ? ["ssh", "-t", card.m.host].concat(argv) : argv);
                            }
                        }
                        Rectangle {
                            implicitWidth: 6
                            implicitHeight: 6
                            radius: 3
                            color: Theme.colorDanger
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: unit.modelData
                            font.family: "Inter"
                            font.pixelSize: 12
                            color: unitHover.hovered ? Theme.accentColor : Theme.textPrimary
                        }
                    }
                }
            }

            // Éteindre ou redémarrer, un clic de plus.
            RowLayout {
                id: powerMenu
                visible: false
                Layout.fillWidth: true
                spacing: 6
                Item { Layout.fillWidth: true }
                Repeater {
                    model: [{ a: "reboot", k: "power.reboot" }, { a: "off", k: "power.off" }]
                    Rectangle {
                        id: pw
                        required property var modelData
                        implicitWidth: pwText.implicitWidth + 20
                        implicitHeight: 28
                        radius: Theme.radiusSmall
                        color: Qt.alpha(Theme.colorDanger, pwMa.containsMouse ? 0.26 : 0.16)
                        Text {
                            id: pwText
                            anchors.centerIn: parent
                            text: I18n.tr(pw.modelData.k)
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.colorDanger
                        }
                        MouseArea {
                            id: pwMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (card.m.remote)
                                    root.act([pw.modelData.a, card.m.name]);
                                else
                                    Quickshell.execDetached(["systemctl", pw.modelData.a === "off" ? "poweroff" : "reboot"]);
                                powerMenu.visible = false;
                            }
                        }
                    }
                }
            }

            // Hors ligne : le réveiller, si on connaît son adresse.
            Rectangle {
                visible: !card.m.online && card.m.canWake
                implicitWidth: wakeText.implicitWidth + 22
                implicitHeight: 30
                radius: Theme.radiusSmall
                color: wakeMa.containsMouse ? Theme.selectedFill : Theme.hoverOverlay
                Text {
                    id: wakeText
                    anchors.centerIn: parent
                    text: I18n.tr("fleet.wake")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                }
                MouseArea {
                    id: wakeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.act(["on", card.m.name])
                }
            }

            // ── Les mesures ──
            RowLayout {
                visible: card.up
                Layout.fillWidth: true
                spacing: 12

                Metric {
                    label: "CPU"
                    value: card.m.cpu
                    detail: card.m.temp > 0 ? card.m.temp + " °C" : ""
                    curve: root.history[card.m.name] || []
                    tone: Theme.colorCoral
                }
                Metric {
                    label: "RAM"
                    value: card.m.ramTotal > 0 ? Math.round(card.m.ramUsed / card.m.ramTotal * 100) : -1
                    detail: card.m.ramTotal > 0 ? root.bytes(card.m.ramUsed) + " / " + root.bytes(card.m.ramTotal) : ""
                    tone: Theme.colorSuccess
                }
                Metric {
                    label: "GPU"
                    value: !card.m.gpu || card.m.gpu.asleep ? -1 : card.m.gpu.usage
                    detail: !card.m.gpu ? I18n.tr("stats.notDetected")
                          : card.m.gpu.asleep ? I18n.tr("stats.asleep")
                          : [card.m.gpu.total > 0 ? root.bytes(card.m.gpu.used) + " / " + root.bytes(card.m.gpu.total) : "",
                             card.m.gpu.temp > 0 ? card.m.gpu.temp + " °C" : ""].filter(x => x).join(" · ")
                    tone: Theme.accentColor
                    hot: value >= 80
                }
            }

            // ── Les disques physiques : les mêmes cases que dans l'Explorer ──
            // (DiskTiles). Un clic le montre dans l'Explorer, sur sa machine
            // (montée au besoin) ; un disque amovible d'ici s'éjecte.
            ColumnLayout {
                visible: card.up && card.m.drives.length > 0
                Layout.fillWidth: true
                spacing: 9

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.dividerColor }

                DiskTiles {
                    id: tiles
                    Layout.fillWidth: true
                    disks: Disks.fromDrives(card.m.drives, card.m.remote ? card.m.name : "",
                                            card.m.host || "", card.m.name, false)
                    blockHeight: 76
                    onOpened: (d) => Widgets.explorerShowDisk(d.machine, d.host, d.main)
                    onOpenedHome: (d, path) => Widgets.explorerShowDisk(d.machine, d.host, path)
                }

                // Une éjection ratée sur cette machine : pourquoi (un clic l'efface).
                Text {
                    Layout.fillWidth: true
                    visible: !card.m.remote && Disks.error !== ""
                    text: Disks.error
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.colorDanger
                    TapHandler { onTapped: Disks.error = "" }
                }
            }

            // ── Les conteneurs Docker (cAdvisor), les plus actifs d'abord ──
            //   ● db       postgres:16              12 %   230 Mo
            ColumnLayout {
                visible: card.up && card.m.containers.length > 0
                Layout.fillWidth: true
                spacing: 6

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.dividerColor }

                Text {
                    text: I18n.tr("fleet.containers")
                    font.family: "Inter"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.8
                    font.capitalization: Font.AllUppercase
                    color: Theme.textDim
                }

                Repeater {
                    model: card.m.containers

                    RowLayout {
                        id: ctr
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle {
                            implicitWidth: 6
                            implicitHeight: 6
                            radius: 3
                            color: Theme.colorSuccess
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            textFormat: Text.StyledText
                            text: root.escapeHtml(ctr.modelData.name) + "  <font color='" + Theme.textDim + "'>"
                                  + root.escapeHtml(ctr.modelData.image) + "</font>"
                            font.family: "Inter"
                            font.pixelSize: 12
                            color: Theme.textPrimary
                        }
                        Text {
                            text: (ctr.modelData.cpu >= 0 ? I18n.tr("common.percent", { n: ctr.modelData.cpu }) + "  " : "")
                                  + root.mem(ctr.modelData.mem)
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                            color: Theme.textDim
                        }
                    }
                }
            }
        }
    }

    // Une mesure : son nom, sa valeur en grand, une courbe ou une barre,
    // et un détail dessous.
    component Metric: ColumnLayout {
        id: metric
        property string label
        property int value: -1
        property string detail
        property var curve: []
        property color tone: Theme.accentColor
        property bool hot: false

        Layout.fillWidth: true
        Layout.preferredWidth: 1
        spacing: 4

        Text {
            text: metric.label
            font.family: "Inter"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
            color: Theme.textDim
        }
        Text {
            textFormat: Text.StyledText
            text: metric.value < 0 ? "—"
                : metric.value + "<font size='2' color='" + Theme.textSecondary + "'> %</font>"
            font.family: "Inter"
            font.pixelSize: 22
            font.weight: Font.Medium
            font.features: { "tnum": 1 }
            color: metric.value < 0 ? Theme.textDim : metric.hot ? Theme.accentColor : Theme.textPrimary
        }
        // La courbe (le processeur), sinon la barre.
        Item {
            Layout.fillWidth: true
            implicitHeight: 14
            Canvas {
                id: spark
                anchors.fill: parent
                visible: metric.curve.length > 1
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.reset();
                    var c = metric.curve;
                    if (c.length < 2)
                        return;
                    ctx.strokeStyle = metric.tone;
                    ctx.lineWidth = 1.5;
                    ctx.beginPath();
                    for (var i = 0; i < c.length; i++) {
                        var x = i / (c.length - 1) * width;
                        var y = height - 1 - Math.min(100, c[i]) / 100 * (height - 2);
                        if (i === 0)
                            ctx.moveTo(x, y);
                        else
                            ctx.lineTo(x, y);
                    }
                    ctx.stroke();
                }
                Connections {
                    target: metric
                    function onCurveChanged() { spark.requestPaint(); }
                }
            }
            Rectangle {
                visible: metric.curve.length <= 1
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: Theme.dividerColor
                Rectangle {
                    width: parent.width * Math.max(0, metric.value) / 100
                    height: parent.height
                    radius: 2
                    color: metric.tone
                }
            }
        }
        Text {
            Layout.fillWidth: true
            text: metric.detail
            elide: Text.ElideRight
            font.family: "Inter"
            font.pixelSize: 11
            font.features: { "tnum": 1 }
            color: Theme.textDim
        }
    }

    ColumnLayout {
        id: column
        width: root.width
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: I18n.tr("fleet.title")
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
                color: Theme.textDim
            }
            Item { Layout.fillWidth: true }
            Text {
                visible: root.serversLoaded
                text: I18n.tr("fleet.count", {
                    n: root.servers.length,
                    up: root.servers.filter(s => s.online).length
                })
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textDim
            }
        }

        // Celle-ci, puis les autres dans l'ordre du tailnet.
        Repeater {
            model: cards

            MachineCard {
                required property string key
                readonly property var modelData: root.byName[key] || ({ name: key })
                m: ({
                    name: modelData.name,
                    remote: !modelData.local,
                    host: modelData.host,
                    online: modelData.online,
                    error: modelData.error,
                    canWake: modelData.can_wake,
                    uptime: modelData.uptime_s,
                    cpu: modelData.measured && !modelData.error ? modelData.cpu_usage : -1,
                    temp: modelData.temp,
                    ramUsed: modelData.ram_used,
                    ramTotal: modelData.ram_total,
                    gpu: modelData.gpu ? { asleep: modelData.gpu.asleep, usage: modelData.gpu.usage,
                                           used: modelData.gpu.mem_used, total: modelData.gpu.mem_total,
                                           temp: modelData.gpu.temp } : null,
                    drives: modelData.drives || [],
                    osName: modelData.os_name || "",
                    nixpkgsRev: modelData.nixpkgs_rev || "",
                    nixpkgsDate: modelData.nixpkgs_date || "",
                    // La batterie qui se décharge dit toute la machine ; sinon
                    // le processeur seul.
                    onBattery: modelData.battery_watts >= 0,
                    watts: modelData.battery_watts >= 0 ? modelData.battery_watts
                         : modelData.cpu_watts !== undefined ? modelData.cpu_watts : -1,
                    containers: modelData.containers || [],
                    failed: modelData.failed || [],
                    systemd: modelData.systemd === true
                })
            }
        }
    }
}
