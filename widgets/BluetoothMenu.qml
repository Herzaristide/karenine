pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Bluetooth
import Quickshell.Io
import "../services"

// Le menu Bluetooth, déplié sous son bouton dans la barre du haut des
// widgets (HubTopBar). En tête, l'interrupteur de l'adaptateur ; puis les
// appareils : les connectés d'abord, les appairés, puis ceux qu'on découvre.
//
//   ╭ Bluetooth                         recherche…  (●━) ╮
//   │ Casque WH-1000           ╭ Musique │ Appel ╮      │
//   │ Connecté · 80 %          ╰───────────────╯      │
//   │ Souris MX                Appairé                  │
//   │ JBL Flip                 Disponible               │
//   ╰───────────────────────────────────────────────────╯
//
// Un clic sur un appareil : connecté, il se déconnecte ; appairé, il se
// connecte ; nouveau, il s'appaire, devient de confiance (il se reconnectera
// seul) et se connecte. Le menu ouvert, l'adaptateur cherche les appareils
// autour ; fermé, il arrête.
//
// Un casque connecté qui a un micro offre deux profils : Musique (A2DP, le
// son en haute qualité, sans micro) et Appel (HFP, le micro, le son en
// qualité téléphone) — le Bluetooth classique ne fait pas les deux à la
// fois. Les profils sont ceux de la carte PipeWire (`pactl list cards`).
// Le casque ne change de mode que par ce choix : la bascule automatique de
// WirePlumber (passer en Appel dès qu'un programme enregistre) est coupée
// dans la config NixOS (modules/audio.nix) — le mot d'éveil d'anna écoute
// en continu, et le casque basculait au hasard des captures.
//
// BlueZ, par le module Quickshell.Bluetooth (D-Bus). Pas d'agent : les
// appareils sans code (casques, souris, manettes) s'appairent ; un clavier
// qui demande un code passe par `bluetoothctl`.
Rectangle {
    id: menu

    property string fontFamily: "Inter"
    // Ouvert : il cherche les appareils.
    property bool open: false

    readonly property BluetoothAdapter adapter: Bluetooth.defaultAdapter // qmllint disable unresolved-type
    readonly property bool powered: menu.adapter !== null && menu.adapter.enabled

    // L'appareil qu'on appaire : une fois appairé, on lui fait confiance et
    // on le connecte.
    property BluetoothDevice pending: null

    // Les connectés, les appairés, puis les autres — chacun par nom. Les
    // appareils sans nom (des balises, pour la plupart) n'encombrent pas.
    readonly property var devices: {
        if (!menu.adapter)
            return [];
        var list = menu.adapter.devices.values.filter(d => d.paired || d.deviceName !== ""); // qmllint disable unresolved-type
        function rank(d) { return d.connected ? 0 : d.paired ? 1 : 2; }
        return list.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
    }

    function flip() {
        if (menu.adapter)
            menu.adapter.enabled = !menu.adapter.enabled;
    }

    function activate(dev) {
        if (dev.state === BluetoothDeviceState.Connecting || dev.state === BluetoothDeviceState.Disconnecting)
            return;
        if (dev.connected) {
            dev.disconnect();
        } else if (dev.paired) {
            dev.connect();
        } else if (!dev.pairing) {
            menu.pending = dev;
            dev.pair();
        }
    }

    Connections {
        target: menu.pending
        function onPairedChanged() {
            var dev = menu.pending;
            if (!dev.paired)
                return;
            dev.trusted = true;
            dev.connect();
            menu.pending = null;
        }
        function onPairingChanged() {
            // Fini sans être appairé : refusé, ou un code était demandé.
            if (!menu.pending.pairing && !menu.pending.paired)
                menu.pending = null;
        }
    }

    // ── Les profils audio ────────────────────────────────────────
    // { "B4:84:…": { card, active, music, call } } : pour chaque casque, sa
    // carte PipeWire, le profil actif, et le meilleur profil de chaque sorte
    // (vide s'il n'y en a pas).
    property var cards: ({})

    function parseCards(text) {
        var out = {};
        var list = [];
        try { list = JSON.parse(text); } catch (e) { return out; }
        for (var i = 0; i < list.length; i++) {
            var c = list[i];
            var addr = (c.properties || {})["api.bluez5.address"];
            if (!addr)
                continue;
            var best = { music: "", call: "" };
            var prio = { music: -1, call: -1 };
            for (var key in c.profiles) {
                var p = c.profiles[key];
                if (!p.available)
                    continue;
                var kind = key.indexOf("a2dp-sink") === 0 ? "music"
                         : key.indexOf("headset-head-unit") === 0 && p.sources > 0 ? "call" : "";
                if (kind !== "" && p.priority > prio[kind]) {
                    prio[kind] = p.priority;
                    best[kind] = key;
                }
            }
            out[addr] = { card: c.name, active: c.active_profile, music: best.music, call: best.call };
        }
        return out;
    }

    Process {
        id: cardsProc
        command: ["pactl", "-f", "json", "list", "cards"]
        stdout: StdioCollector {
            onStreamFinished: menu.cards = menu.parseCards(text)
        }
    }

    Process {
        id: profileProc
        onRunningChanged: if (!running) cardsProc.running = true
    }

    // En Appel, le micro du casque devient l'entrée par défaut : sans ça, les
    // applications (et le mot d'éveil d'anna) resteraient sur le micro de
    // l'ordinateur, et le mode Appel ne servirait à rien. PipeWire crée sa
    // source un instant après le changement de profil : on l'attend (5 s au
    // plus). On la reconnaît à l'adresse du casque, `bluez_input.B4_84_…`.
    // Revenu en Musique, elle disparaît et WirePlumber reprend seul le micro
    // de l'ordinateur ; elle redevient la bonne au prochain passage en Appel.
    readonly property string callScript:
        "pactl set-card-profile \"$1\" \"$2\" || exit 1; " +
        "a=$(printf %s \"$3\" | tr : _); i=0; " +
        "while [ $i -lt 20 ]; do " +
        "n=$(pactl list short sources | awk -v p=\"bluez_input.$a\" " +
        "'index($2, p) == 1 && $2 !~ /\\.monitor$/ { print $2; exit }'); " +
        "[ -n \"$n\" ] && exec pactl set-default-source \"$n\"; " +
        "sleep 0.25; i=$((i + 1)); done"

    function setProfile(dev, kind) {
        var c = menu.cards[dev.address];
        if (!c || c[kind] === "" || c.active === c[kind] || profileProc.running)
            return;
        profileProc.command = kind === "call"
            ? ["sh", "-c", menu.callScript, "sh", c.card, c[kind], dev.address]
            : ["pactl", "set-card-profile", c.card, c[kind]];
        profileProc.running = true;
    }

    // Le profil peut changer ailleurs (pavucontrol, une application d'appel
    // qui le demande) : relu tant que le menu est ouvert.
    Timer {
        interval: 2000
        repeat: true
        running: menu.open && menu.powered
        triggeredOnStart: true
        onTriggered: if (!cardsProc.running) cardsProc.running = true
    }

    // La recherche suit l'ouverture du menu.
    function scan() {
        if (menu.adapter && menu.adapter.enabled)
            menu.adapter.discovering = menu.open;
    }
    onOpenChanged: menu.scan()
    onPoweredChanged: menu.scan()

    function status(dev) {
        if (dev.pairing)
            return I18n.tr("bluetooth.pairing");
        switch (dev.state) {
            case BluetoothDeviceState.Connecting:    return I18n.tr("bluetooth.connecting");
            case BluetoothDeviceState.Disconnecting: return I18n.tr("bluetooth.disconnecting");
        }
        if (dev.connected)
            return dev.batteryAvailable
                ? I18n.tr("bluetooth.connectedBattery", { n: Math.round(dev.battery * 100) })
                : I18n.tr("bluetooth.connected");
        return dev.paired ? I18n.tr("bluetooth.paired") : I18n.tr("bluetooth.available");
    }

    implicitWidth: 320
    implicitHeight: column.implicitHeight + 16
    radius: 18
    color: Qt.alpha(Theme.bgDeep, 0.94)
    border.width: 1
    border.color: Qt.alpha(Theme.textPrimary, 0.1)

    // Les clics sur le menu ne traversent pas jusqu'au widget dessous.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onWheel: (wheel) => wheel.accepted = true
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: 8
        spacing: 2

        // ── L'en-tête ────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.preferredHeight: 34
            spacing: 8

            Text {
                text: I18n.tr("bluetooth.title")
                font.family: menu.fontFamily
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: Theme.textPrimary
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: menu.powered && menu.adapter.discovering
                text: I18n.tr("bluetooth.searching")
                font.family: menu.fontFamily
                font.pixelSize: 10
                color: Theme.textDim
            }
            Item { Layout.fillWidth: true; visible: !(menu.powered && menu.adapter.discovering) }

            // L'interrupteur.
            Rectangle {
                id: toggle
                readonly property bool hovered: toggleMa.containsMouse || toggle.activeFocus
                Layout.alignment: Qt.AlignVCenter
                Layout.rightMargin: 4
                implicitWidth: 34
                implicitHeight: 20
                radius: height / 2
                color: menu.powered ? Theme.accentColor : Qt.alpha(Theme.textPrimary, toggle.hovered ? 0.2 : 0.14)
                Behavior on color { ColorAnimation { duration: 180 } }

                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        menu.flip();
                        event.accepted = true;
                    }
                }

                Rectangle {
                    y: 3
                    x: menu.powered ? parent.width - width - 3 : 3
                    Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    width: 14
                    height: 14
                    radius: 7
                    color: "#ffffff"
                }
                MouseArea {
                    id: toggleMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: menu.flip()
                }
                FocusRing { gap: 2 }
            }
        }

        // ── Les appareils ────────────────────────────────────────
        Text {
            Layout.fillWidth: true
            Layout.margins: 8
            visible: !menu.powered || menu.devices.length === 0
            text: !menu.adapter ? I18n.tr("bluetooth.noAdapter")
                : !menu.powered ? I18n.tr("bluetooth.off")
                : I18n.tr("bluetooth.none")
            font.family: menu.fontFamily
            font.pixelSize: 11
            color: Theme.textDim
            wrapMode: Text.Wrap
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 4 * 44)
            visible: menu.powered && menu.devices.length > 0
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: menu.devices

            delegate: Rectangle {
                id: row
                required property BluetoothDevice modelData
                readonly property BluetoothDevice dev: row.modelData
                readonly property bool busy: row.dev.pairing
                                             || row.dev.state === BluetoothDeviceState.Connecting // qmllint disable unresolved-type
                                             || row.dev.state === BluetoothDeviceState.Disconnecting // qmllint disable unresolved-type
                readonly property bool hovered: rowMa.containsMouse || row.activeFocus
                // Ses profils, s'il en a deux à choisir.
                readonly property var card: menu.cards[row.dev.address] || null
                readonly property bool switchable: row.dev.connected && row.card !== null
                                                   && row.card.music !== "" && row.card.call !== ""

                width: list.width
                height: 42
                radius: 12
                color: row.dev.connected ? Qt.alpha(Theme.accentColor, row.hovered ? 0.22 : 0.15)
                                         : Qt.alpha(Theme.textPrimary, row.hovered ? 0.08 : 0)
                Behavior on color { ColorAnimation { duration: 160 } }

                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        menu.activate(row.dev);
                        event.accepted = true;
                    }
                }

                // Au-dessus de la ligne : un clic ici change le profil, il ne
                // déconnecte pas.
                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: menu.activate(row.dev)
                }

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.right: row.switchable ? profiles.left : parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        width: parent.width
                        text: row.dev.name
                        elide: Text.ElideRight
                        font.family: menu.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                    }
                    Text {
                        width: parent.width
                        text: menu.status(row.dev)
                        elide: Text.ElideRight
                        font.family: menu.fontFamily
                        font.pixelSize: 10
                        color: row.dev.connected ? Theme.accentMuted : Theme.textSecondary
                        opacity: row.busy ? 0.6 : 1
                        SequentialAnimation on opacity {
                            running: row.busy
                            loops: Animation.Infinite
                            NumberAnimation { to: 1; duration: 500 }
                            NumberAnimation { to: 0.4; duration: 500 }
                        }
                    }
                }

                // Musique │ Appel : le profil actif est teinté.
                Rectangle {
                    id: profiles
                    visible: row.switchable
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: segments.width + 4
                    height: 26
                    radius: height / 2
                    color: Qt.alpha(Theme.textPrimary, 0.06)
                    border.width: 1
                    border.color: Qt.alpha(Theme.textPrimary, 0.1)

                    Row {
                        id: segments
                        anchors.centerIn: parent

                        Repeater {
                            model: ["music", "call"]

                            Rectangle {
                                id: seg
                                required property string modelData
                                readonly property bool active: row.card !== null
                                                               && row.card.active === row.card[seg.modelData]
                                readonly property bool hovered: segMa.containsMouse || seg.activeFocus

                                width: segLabel.implicitWidth + 18
                                height: 22
                                radius: height / 2
                                color: seg.active ? Qt.alpha(Theme.accentColor, 0.35)
                                                  : Qt.alpha(Theme.textPrimary, seg.hovered ? 0.08 : 0)
                                Behavior on color { ColorAnimation { duration: 160 } }

                                activeFocusOnTab: true
                                Keys.onPressed: (event) => {
                                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        menu.setProfile(row.dev, seg.modelData);
                                        event.accepted = true;
                                    }
                                }

                                Text {
                                    id: segLabel
                                    anchors.centerIn: parent
                                    text: seg.modelData === "music" ? I18n.tr("bluetooth.profile.music")
                                                                  : I18n.tr("bluetooth.profile.call")
                                    font.family: menu.fontFamily
                                    font.pixelSize: 10
                                    font.weight: seg.active ? Font.DemiBold : Font.Normal
                                    color: seg.active ? Theme.textPrimary : Theme.textSecondary
                                }
                                MouseArea {
                                    id: segMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: menu.setProfile(row.dev, seg.modelData)
                                }
                                FocusRing { gap: 0 }
                            }
                        }
                    }
                }
                FocusRing { gap: 0 }
            }
        }
    }

    // Le menu fermé ne garde pas la recherche allumée.
    Component.onDestruction: if (menu.adapter && menu.adapter.discovering) menu.adapter.discovering = false
}
