pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Bluetooth
import "../services"

// Le menu Bluetooth, déplié sous son bouton dans la barre du haut des
// widgets (HubTopBar). En tête, l'interrupteur de l'adaptateur ; puis les
// appareils : les connectés d'abord, les appairés, puis ceux qu'on découvre.
//
//   ╭ Bluetooth                         recherche…  (●━) ╮
//   │ Casque WH-1000           Connecté · 80 %          │
//   │ Souris MX                Appairé                  │
//   │ JBL Flip                 Disponible               │
//   ╰───────────────────────────────────────────────────╯
//
// Un clic sur un appareil : connecté, il se déconnecte ; appairé, il se
// connecte ; nouveau, il s'appaire, devient de confiance (il se reconnectera
// seul) et se connecte. Le menu ouvert, l'adaptateur cherche les appareils
// autour ; fermé, il arrête.
//
// BlueZ, par le module Quickshell.Bluetooth (D-Bus). Pas d'agent : les
// appareils sans code (casques, souris, manettes) s'appairent ; un clavier
// qui demande un code passe par `bluetoothctl`.
Rectangle {
    id: menu

    property string fontFamily: "Inter"
    // Ouvert : il cherche les appareils.
    property bool open: false

    readonly property BluetoothAdapter adapter: Bluetooth.defaultAdapter
    readonly property bool powered: menu.adapter !== null && menu.adapter.enabled

    // L'appareil qu'on appaire : une fois appairé, on lui fait confiance et
    // on le connecte.
    property BluetoothDevice pending: null

    // Les connectés, les appairés, puis les autres — chacun par nom. Les
    // appareils sans nom (des balises, pour la plupart) n'encombrent pas.
    readonly property var devices: {
        if (!menu.adapter)
            return [];
        var list = menu.adapter.devices.values.filter(d => d.paired || d.deviceName !== "");
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

    implicitWidth: 300
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
                                             || row.dev.state === BluetoothDeviceState.Connecting
                                             || row.dev.state === BluetoothDeviceState.Disconnecting
                readonly property bool hovered: rowMa.containsMouse || row.activeFocus

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

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.right: parent.right
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

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: menu.activate(row.dev)
                }
                FocusRing { gap: 0 }
            }
        }
    }

    // Le menu fermé ne garde pas la recherche allumée.
    Component.onDestruction: if (menu.adapter && menu.adapter.discovering) menu.adapter.discovering = false
}
