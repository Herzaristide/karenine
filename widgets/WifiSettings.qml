pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"

// Le Wi-Fi, dans la colonne des périphériques des réglages : la radio
// allumée ou coupée, le réseau en cours, et les réseaux visibles à choisir.
//
// Tout passe par NetworkManager (nmcli). Un réseau déjà connu se rejoint
// d'un clic ; un réseau protégé inconnu demande d'abord son mot de passe,
// dans la ligne même. Sans interface sans fil, la section disparaît.
ColumnLayout {
    id: root

    spacing: 6

    // "" : pas d'interface ; sinon son état : « connected »,
    // « disconnected », « unavailable » (radio coupée)…
    property string wifiState: ""
    readonly property bool hasWifi: root.wifiState !== ""
    readonly property bool radioOn: root.wifiState !== "unavailable"

    // [{ ssid, signal, secure, active }], le réseau en cours d'abord puis
    // par signal décroissant.
    property var networks: []
    // Les connexions Wi-Fi enregistrées (leur nom est le SSID).
    property var known: []

    // Le réseau dont on tape le mot de passe, celui qu'on rejoint, et la
    // dernière erreur de nmcli.
    property string asking: ""
    property string joining: ""
    property string error: ""

    // Les lignes de `nmcli -t` : champs séparés par « : », les « : » et
    // « \ » des valeurs échappés d'un « \ ».
    function fields(line) {
        var out = [""];
        for (var i = 0; i < line.length; i++) {
            var c = line[i];
            if (c === "\\" && i + 1 < line.length)
                out[out.length - 1] += line[++i];
            else if (c === ":")
                out.push("");
            else
                out[out.length - 1] += c;
        }
        return out;
    }

    function lines(text) {
        return text.split("\n").filter(l => l !== "").map(root.fields);
    }

    // ── NetworkManager ───────────────────────────────────────────
    Process {
        id: stateProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE", "device"]
        stdout: StdioCollector {
            onStreamFinished: {
                var dev = root.lines(text).find(f => f[0] === "wifi");
                root.wifiState = dev ? dev[1] : "";
            }
        }
    }

    Process {
        id: listProc
        // Le ↻ demande un nouveau balayage ; sinon, la liste que NetworkManager
        // tient déjà.
        property bool rescan: false
        onRunningChanged: if (!running) rescan = false
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list",
                  "--rescan", listProc.rescan ? "yes" : "no"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Un même SSID par point d'accès : on garde le meilleur.
                var by = {};
                root.lines(text).forEach(f => {
                    var ssid = f[1];
                    if (ssid === "")
                        return;
                    var n = { ssid: ssid, signal: parseInt(f[2]) || 0,
                              secure: f[3] !== "" && f[3] !== "--", active: f[0] === "*" };
                    var o = by[ssid];
                    if (!o || n.active || (!o.active && n.signal > o.signal))
                        by[ssid] = n;
                });
                root.networks = Object.values(by).sort((a, b) =>
                    a.active !== b.active ? (a.active ? -1 : 1) : b.signal - a.signal);
            }
        }
    }

    Process {
        id: knownProc
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: root.known = root.lines(text)
                .filter(f => f[1] === "802-11-wireless").map(f => f[0])
        }
    }

    function refresh() {
        if (!stateProc.running)
            stateProc.running = true;
        if (root.radioOn && !listProc.running)
            listProc.running = true;
        if (!knownProc.running)
            knownProc.running = true;
    }

    Process {
        id: actProc
        stderr: StdioCollector {
            onStreamFinished: {
                var t = text.trim();
                // « Error: Connection activation failed: (7) Secrets were required… »
                root.error = t === "" ? "" : t.replace(/^Error:\s*/, "").split("\n")[0];
            }
        }
        onRunningChanged: {
            if (running)
                return;
            root.joining = "";
            root.refresh();
        }
    }

    function run(cmd) {
        if (actProc.running)
            return;
        root.error = "";
        actProc.command = cmd;
        actProc.running = true;
    }

    function toggleRadio() {
        var on = !root.radioOn;
        // L'affichage suit tout de suite ; la relecture corrige.
        root.wifiState = on ? "disconnected" : "unavailable";
        if (!on)
            root.networks = [];
        root.run(["nmcli", "radio", "wifi", on ? "on" : "off"]);
    }

    // Un clic sur un réseau : rien s'il est déjà le bon, le mot de passe
    // s'il en faut un qu'on n'a pas, sinon on le rejoint.
    function choose(n) {
        if (n.active || actProc.running)
            return;
        if (root.known.indexOf(n.ssid) >= 0) {
            root.joining = n.ssid;
            root.run(["nmcli", "connection", "up", "id", n.ssid]);
        } else if (n.secure) {
            root.asking = root.asking === n.ssid ? "" : n.ssid;
            root.error = "";
        } else {
            root.join(n.ssid, "");
        }
    }

    function join(ssid, password) {
        root.asking = "";
        root.joining = ssid;
        var cmd = ["nmcli", "device", "wifi", "connect", ssid];
        if (password !== "")
            cmd.push("password", password);
        root.run(cmd);
    }

    Timer {
        interval: 3000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ── Petits éléments ──────────────────────────────────────────
    component Heading: Text {
        Layout.bottomMargin: 4
        font.family: "Inter"
        font.pixelSize: 12
        font.weight: Font.Medium
        color: Theme.accentMuted
    }

    component Card: Rectangle {
        Layout.fillWidth: true
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, 0.05)
    }

    // Quatre barres, pleines selon le signal.
    component Bars: Row {
        id: bars
        property int level
        property color ink: Theme.textSecondary
        spacing: 2
        Repeater {
            model: 4
            Rectangle {
                required property int index
                anchors.bottom: parent.bottom
                width: 3
                height: 4 + index * 3
                radius: 1
                color: Qt.alpha(bars.ink, bars.level > index * 25 ? 1 : 0.25)
            }
        }
    }

    // ── Les lignes ───────────────────────────────────────────────
    Heading {
        Layout.topMargin: 10
        visible: root.hasWifi
        text: I18n.tr("wifi.title")
    }

    // La radio, et le réseau en cours.
    Card {
        visible: root.hasWifi
        implicitHeight: 46

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: radioBtn.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                text: I18n.tr("wifi.network")
                font.family: "Inter"
                font.pixelSize: 10
                color: Theme.textSecondary
            }
            Text {
                width: parent.width
                text: {
                    if (!root.radioOn)
                        return I18n.tr("wifi.off");
                    var a = root.networks.find(n => n.active);
                    return a ? a.ssid : root.joining !== "" ? I18n.tr("wifi.connecting", { ssid: root.joining }) : I18n.tr("wifi.disconnected");
                }
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: root.radioOn ? Theme.textPrimary : Theme.textDim
                elide: Text.ElideRight
            }
        }

        GlassButton {
            id: radioBtn
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 26
            fontSize: 11
            text: root.radioOn ? I18n.tr("wifi.turnOff") : I18n.tr("wifi.turnOn")
            accent: !root.radioOn
            onClicked: root.toggleRadio()
        }
    }

    // Les réseaux visibles.
    Card {
        visible: root.hasWifi && root.radioOn
        implicitHeight: netCol.implicitHeight + 8

        ColumnLayout {
            id: netCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 4
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 4
                Layout.topMargin: 2
                Text {
                    Layout.fillWidth: true
                    text: listProc.rescan ? I18n.tr("wifi.searching") : I18n.tr("wifi.networks")
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textSecondary
                }
                GlassButton {
                    implicitWidth: 22
                    implicitHeight: 22
                    icon: Qt.resolvedUrl("../assets/icons/refresh.svg")
                    onClicked: {
                        if (listProc.running)
                            return;
                        listProc.rescan = true;
                        listProc.running = true;
                    }
                }
            }

            Text {
                Layout.leftMargin: 8
                Layout.bottomMargin: 6
                visible: root.networks.length === 0
                text: I18n.tr("wifi.none")
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textDim
            }

            Repeater {
                // Les huit meilleurs : la colonne reste lisible.
                model: root.networks.slice(0, 8)

                ColumnLayout {
                    id: net
                    required property var modelData
                    readonly property bool asking: root.asking === net.modelData.ssid
                    Layout.fillWidth: true
                    spacing: 0

                    Rectangle {
                        id: netRow
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: Theme.radiusSmall
                        readonly property bool hovered: netMa.containsMouse || netRow.activeFocus
                        color: Qt.alpha(Theme.textPrimary, net.modelData.active ? 0.08 : netRow.hovered ? 0.06 : 0)

                        activeFocusOnTab: true
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                root.choose(net.modelData);
                                event.accepted = true;
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            Bars {
                                level: net.modelData.signal
                                ink: net.modelData.active ? Theme.accentColor : Theme.textSecondary
                            }
                            Text {
                                Layout.fillWidth: true
                                text: net.modelData.ssid
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: net.modelData.active ? Font.DemiBold : Font.Normal
                                color: Theme.textPrimary
                                elide: Text.ElideRight
                            }
                            Text {
                                visible: root.joining === net.modelData.ssid
                                text: "…"
                                font.family: "Inter"
                                font.pixelSize: 11
                                color: Theme.textDim
                            }
                            // Le réseau actif, coché ; un réseau protégé, cadenassé.
                            NixIcon {
                                visible: root.joining !== net.modelData.ssid
                                         && (net.modelData.active || net.modelData.secure)
                                iconSize: 12
                                source: "../assets/icons/" + (net.modelData.active ? "check.svg" : "lock.svg")
                                color: net.modelData.active ? Theme.accentColor : Theme.textDim
                            }
                        }
                        FocusRing { gap: 1 }
                        MouseArea {
                            id: netMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: net.modelData.active ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: root.choose(net.modelData)
                        }
                    }

                    // Le mot de passe d'un réseau protégé encore inconnu.
                    RowLayout {
                        visible: net.asking
                        Layout.fillWidth: true
                        Layout.leftMargin: 8
                        Layout.rightMargin: 4
                        Layout.topMargin: 2
                        Layout.bottomMargin: 4
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 26
                            radius: 8
                            color: Qt.alpha(Theme.textPrimary, 0.06)
                            border.width: 1
                            border.color: Qt.alpha(Theme.textPrimary, pwInput.activeFocus ? 0.2 : 0.08)

                            TextInput {
                                id: pwInput
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                verticalAlignment: TextInput.AlignVCenter
                                echoMode: TextInput.Password
                                font.family: "Inter"
                                font.pixelSize: 12
                                color: Theme.textPrimary
                                selectByMouse: true
                                activeFocusOnTab: true
                                clip: true
                                onVisibleChanged: {
                                    text = "";
                                    if (visible)
                                        forceActiveFocus();
                                }
                                onAccepted: if (text !== "") root.join(net.modelData.ssid, text)
                                Keys.onEscapePressed: root.asking = ""

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: pwInput.text === ""
                                    text: I18n.tr("wifi.password")
                                    font: pwInput.font
                                    color: Theme.textDim
                                }
                            }
                        }
                        GlassButton {
                            implicitHeight: 26
                            fontSize: 11
                            text: I18n.tr("wifi.join")
                            accent: true
                            onClicked: if (pwInput.text !== "") root.join(net.modelData.ssid, pwInput.text)
                        }
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: root.error !== ""
        text: root.error
        font.family: "Inter"
        font.pixelSize: 10
        color: Theme.colorDanger
        wrapMode: Text.Wrap
    }
}
