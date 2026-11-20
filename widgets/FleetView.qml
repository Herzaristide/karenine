pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

// La vue Système du panneau de droite : toute la flotte, une carte par
// machine. Celle-ci d'abord (hwstats_watch, deux fois par seconde), puis
// celles du tailnet (servers_watch : node_exporter, sinon ssh, chaque seconde). Sur
// chaque carte : le processeur, la mémoire et la carte graphique ; puis ses
// disques physiques, un par un, remplis à l'accent ; puis ses services
// d'IA (ComfyUI, Ollama), actifs ou non, et ce qu'ils font.
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

    // ── Cette machine ────────────────────────────────────────────
    property var hw: null
    // { hostname, drives, services }, venu avec les serveurs.
    property var local: null
    // ── Les autres ───────────────────────────────────────────────
    property var servers: []
    property bool serversLoaded: false

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
        id: hwSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var s = JSON.parse(line);
                    if (s.cpu_usage === undefined)
                        return;
                    root.hw = s;
                    root.remember("", s.cpu_usage);
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: if (connected) write('{"cmd":"hwstats_watch","interval_ms":1000}\n')
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
                    root.servers = msg.servers.filter(s => s.os === "linux");
                    root.local = msg.local || null;
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
            if (!hwSock.connected)
                hwSock.connected = true;
            if (!serversSock.connected)
                serversSock.connected = true;
        }
    }
    onVisibleChanged: if (!visible) { hwSock.connected = false; serversSock.connected = false; }

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

    function act(args) {
        Quickshell.execDetached(["anna", "servers"].concat(args));
    }

    // Une carte de machine, la même pour celle-ci et pour les autres.
    // `m` : { name, online, error, uptime, cpu, temp, ramUsed, ramTotal,
    //         gpu: { asleep, usage, used, total } | null, drives, services,
    //         host, canWake, lastSeen, remote }
    component MachineCard: Rectangle {
        id: card
        required property var m
        readonly property bool up: card.m.online && !card.m.error

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
                // Une session dans le terminal, et l'alimentation.
                BarButton {
                    visible: card.m.remote && card.up
                    size: 26
                    icon: "terminal.svg"
                    onClicked: DefaultApps.runInTerminal("", ["ssh", card.m.host])
                }
                BarButton {
                    visible: card.m.remote && card.up
                    size: 26
                    icon: "power.svg"
                    onClicked: powerMenu.visible = !powerMenu.visible
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
                                root.act([pw.modelData.a, card.m.name]);
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
                    curve: root.history[card.m.remote ? card.m.name : ""] || []
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
                          : card.m.gpu.total > 0 ? root.bytes(card.m.gpu.used) + " / " + root.bytes(card.m.gpu.total) : ""
                    tone: Theme.accentColor
                    hot: value >= 80
                }
            }

            // ── Les disques physiques ──
            ColumnLayout {
                visible: card.up && card.m.drives.length > 0
                Layout.fillWidth: true
                spacing: 9

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.dividerColor }

                Repeater {
                    model: card.m.drives

                    ColumnLayout {
                        id: drive
                        required property var modelData
                        readonly property real pct: drive.modelData.fs_size > 0
                                                    ? drive.modelData.fs_used / drive.modelData.fs_size : 0
                        Layout.fillWidth: true
                        spacing: 5

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            NixIcon {
                                iconSize: 15
                                source: "../assets/ui/disk.svg"
                                color: Theme.textSecondary
                            }
                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                textFormat: Text.StyledText
                                text: drive.modelData.model + "  <font color='" + Theme.textDim + "'>"
                                      + [drive.modelData.kind].concat(drive.modelData.mounts.slice(0, 1)).join(" · ")
                                      + "</font>"
                                font.family: "Inter"
                                font.pixelSize: 12
                                color: Theme.textPrimary
                            }
                            Text {
                                text: drive.modelData.fs_size > 0
                                      ? root.bytes(drive.modelData.fs_used) + " / " + root.bytes(drive.modelData.fs_size)
                                      : root.bytes(drive.modelData.size)
                                font.family: "Inter"
                                font.pixelSize: 11
                                font.features: { "tnum": 1 }
                                color: Theme.textDim
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 6
                            radius: 3
                            color: Theme.dividerColor
                            Rectangle {
                                width: parent.width * drive.pct
                                height: parent.height
                                radius: 3
                                // Presque plein : l'alerte plutôt que l'accent.
                                color: drive.pct >= 0.9 ? Theme.colorDanger : Theme.accentColor
                            }
                        }
                    }
                }
            }

            // ── Les services d'IA ──
            Flow {
                visible: card.up && card.m.services.length > 0
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                    model: card.m.services

                    Rectangle {
                        id: svc
                        required property var modelData
                        readonly property bool active: svc.modelData.state === "active"
                        readonly property string what: svc.modelData.name === "comfyui"
                            ? (svc.modelData.queue > 0 ? I18n.tr("fleet.queue", { n: svc.modelData.queue }) : "")
                            : svc.modelData.models.join(", ")

                        width: svcRow.implicitWidth + 16
                        height: 26
                        radius: 7
                        color: Theme.bgDeep

                        Row {
                            id: svcRow
                            anchors.centerIn: parent
                            spacing: 6
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: svc.active ? Theme.colorSuccess
                                     : svc.modelData.state === "failed" ? Theme.colorDanger : Theme.textDim
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: svc.modelData.name === "comfyui" ? "ComfyUI" : "Ollama"
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: svc.active ? Theme.textPrimary : Theme.textSecondary
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: (svc.active ? I18n.tr("fleet.active") : svc.modelData.state === "failed"
                                       ? I18n.tr("fleet.failed") : I18n.tr("fleet.stopped"))
                                      + (svc.what !== "" ? " · " + svc.what : "")
                                font.family: "Inter"
                                font.pixelSize: 11
                                color: Theme.textDim
                            }
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
                    n: root.servers.length + 1,
                    up: root.servers.filter(s => s.online).length + 1
                })
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textDim
            }
        }

        // Cette machine.
        MachineCard {
            m: ({
                name: root.local && root.local.hostname ? root.local.hostname : "localhost",
                remote: false,
                online: true,
                error: "",
                uptime: 0,
                cpu: root.hw ? root.hw.cpu_usage : -1,
                temp: root.hw ? root.hw.cpu_temp : 0,
                ramUsed: root.hw ? root.hw.ram_used : 0,
                ramTotal: root.hw ? root.hw.ram_total : 0,
                gpu: root.hw && root.hw.gpu_present
                     ? { asleep: root.hw.gpu_asleep, usage: root.hw.gpu_usage,
                         used: root.hw.gpu_mem_used_mib * 1048576, total: root.hw.gpu_mem_total_mib * 1048576 }
                     : (root.hw && root.hw.gpu_asleep ? { asleep: true, usage: 0, used: 0, total: 0 } : null),
                drives: root.local ? root.local.drives : [],
                services: root.local ? root.local.services : []
            })
        }

        // Les autres, dans l'ordre du tailnet.
        Repeater {
            model: root.servers

            MachineCard {
                required property var modelData
                m: ({
                    name: modelData.name,
                    remote: true,
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
                                           used: modelData.gpu.mem_used, total: modelData.gpu.mem_total } : null,
                    drives: modelData.drives || [],
                    services: modelData.services || []
                })
            }
        }
    }
}
