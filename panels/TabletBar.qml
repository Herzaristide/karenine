pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Bluetooth
import "../services"
import "../widgets"

// La barre tactile : une bande toujours là, collée au bord gauche de
// l'écran, sous le pouce de la main qui tient la tablette, l'autre gardant
// le stylet. En portrait, où la largeur manque, elle passe au bord du bas.
//
// Le même dessin que le reste du shell, à la taille du doigt : le fond du
// thème et son filet, des boutons nus comme ceux de la barre du haut des
// widgets, sans fond au repos, que le survol révèle, la pastille de l'accent
// qui glisse d'un workspace à l'autre (comme celle des onglets), et le flocon
// de la barre de conversation.
//
//   ┃ ▮  ┃   la batterie, monochrome, l'éclair dedans pendant la charge ;
//   ┃    ┃   un tap déplie le pourcentage et le temps restant
//   ┃    ┃
//   ┃ 1  ┃   les workspaces 1-5, au milieu exact de la bande : le courant
//   ┃(2) ┃   sur la pastille de l'accent ; ceux qui ont des fenêtres en
//   ┃ 3  ┃   clair, les vides en retrait
//   ┃ 4  ┃
//   ┃ 5  ┃
//   ┃ ❄  ┃   le flocon, juste dessous : fait monter la barre de conversation,
//   ┃    ┃   son champ prêt (comme Super) ; une seconde fois, la renvoie
//   ┃    ┃
//   ┃ ᯤ  ┃   le Wi-Fi, le Bluetooth, l'alimentation : chacun déplie son menu
//   ┃ ᛒ  ┃   à côté de la barre, à sa hauteur (cf. le volet, plus bas) ; un
//   ┃ ⏻  ┃   tap à côté ou sur le même bouton le replie
//
// Elle prend sa place aux fenêtres (exclusiveZone) et reste sous une fenêtre
// en plein écran (couche Top). Elle ne prend jamais le clavier ; le volet,
// lui, le prend à la demande (le mot de passe d'un réseau Wi-Fi).
Scope {
    id: tablet

    property var screen: null

    // Le flocon touché : shell.qml le relaie à la barre de conversation.
    signal askRequested()

    readonly property string uiFont: "Inter"
    // L'épaisseur de la bande ; une cible, assez grande pour un doigt, et son
    // icône (17 px sur les boutons de 30 de la souris, en proportion).
    readonly property int thickness: 56
    readonly property int hit: 44
    readonly property int glyph: 20

    readonly property bool portrait: tablet.screen !== null
                                     && tablet.screen.height > tablet.screen.width

    // ── Le menu déplié ───────────────────────────────────────────
    // "" (aucun), "battery", "wifi", "bluetooth" ou "power" ; `along` : le milieu de son
    // bouton le long de la barre (y en paysage, x en portrait).
    property string menu: ""
    property real along: 0

    function toggleMenu(name, button) {
        if (tablet.menu === name) {
            tablet.menu = "";
            return;
        }
        var p = button.mapToItem(null, button.width / 2, button.height / 2);
        tablet.along = tablet.portrait ? p.x : p.y;
        tablet.menu = name;
    }

    // Une action d'alimentation : le volet se replie d'abord.
    function power(argv) {
        tablet.menu = "";
        Quickshell.execDetached(argv);
    }

    // ── Les workspaces ───────────────────────────────────────────
    // Les principaux (1-5) seulement, attachés à l'écran de l'interface (cf.
    // services/Display.qml) : les autres appartiennent chacun à son écran.
    readonly property var monitor: tablet.screen ? Hyprland.monitorFor(tablet.screen) : null
    readonly property int current: tablet.monitor && tablet.monitor.activeWorkspace
                                   ? tablet.monitor.activeWorkspace.id : -1

    readonly property var workspaceIds: [1, 2, 3, 4, 5]

    function occupied(id) {
        var ws = Hyprland.workspaces.values;
        for (var i = 0; i < ws.length; i++)
            if (ws[i].id === id)
                return ws[i].toplevels.values.length > 0;
        return false;
    }

    // La syntaxe Lua des dispatchers, comme anna (anna/src/claude/desk.rs) :
    // un workspace qui n'existe pas encore est créé.
    function goTo(id) {
        Hyprland.dispatch("hl.dsp.focus({ workspace = " + id + " })");
    }

    // ── Le Wi-Fi et le Bluetooth, pour la teinte de leurs boutons ─
    readonly property bool btPresent: Bluetooth.defaultAdapter !== null // qmllint disable unresolved-type
    readonly property bool btPowered: tablet.btPresent && Bluetooth.defaultAdapter.enabled // qmllint disable unresolved-type
    readonly property bool btConnected: tablet.btPowered
                                        && Bluetooth.defaultAdapter.devices.values.some(d => d.connected) // qmllint disable unresolved-type

    // L'état de l'interface sans fil, comme WifiSettings le lit : "" sans
    // interface, « unavailable » radio coupée, « connected »… Relu à chaque
    // événement de NetworkManager (`nmcli monitor`), sans sondage.
    property string wifiState: ""

    Process {
        id: wifiProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE", "device"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var dev = text.split("\n").map(l => l.split(":")).find(f => f[0] === "wifi");
                tablet.wifiState = dev ? dev[1] : "";
            }
        }
    }

    Process {
        id: wifiWatch
        command: ["nmcli", "monitor"]
        running: true
        stdout: SplitParser {
            onRead: wifiSettle.restart()
        }
        onExited: wifiRetry.start() // qmllint disable signal-handler-parameters
    }

    // NetworkManager parle en rafale : une relecture une fois calmé.
    Timer {
        id: wifiSettle
        interval: 300
        onTriggered: if (!wifiProc.running) wifiProc.running = true
    }

    Timer {
        id: wifiRetry
        interval: 5000
        onTriggered: wifiWatch.running = true
    }

    // ── La bande ─────────────────────────────────────────────────
    PanelWindow { // qmllint disable uncreatable-type
        id: band
        screen: tablet.screen

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-tablet"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: !tablet.portrait
            bottom: true
            left: true
            right: tablet.portrait
        }
        exclusiveZone: tablet.thickness
        implicitWidth: tablet.thickness
        implicitHeight: tablet.thickness
        color: Theme.bgDeep

        // Le filet, côté écran.
        Rectangle {
            color: Theme.dividerColor
            width: tablet.portrait ? parent.width : 1
            height: tablet.portrait ? 1 : parent.height
            anchors.right: parent.right
            anchors.top: parent.top
        }

        // Les deux bouts : la batterie en tête ; le Wi-Fi, le Bluetooth et
        // l'alimentation au pied.
        GridLayout {
            anchors.fill: parent
            anchors.margins: (tablet.thickness - tablet.hit) / 2 - 4
            flow: tablet.portrait ? GridLayout.LeftToRight : GridLayout.TopToBottom
            rows: tablet.portrait ? 1 : -1
            columns: tablet.portrait ? -1 : 1
            rowSpacing: 8
            columnSpacing: 8

            // Absente sur une machine sans batterie. Un tap déplie son menu :
            // le pourcentage et le temps restant.
            Target {
                id: batteryButton
                visible: Battery.present
                Layout.alignment: Qt.AlignCenter
                Layout.topMargin: tablet.portrait ? 0 : 4
                Layout.leftMargin: tablet.portrait ? 4 : 0
                active: tablet.menu === "battery"
                onTapped: tablet.toggleMenu("battery", batteryButton)

                BatteryLevel {
                    anchors.centerIn: parent
                }
            }

            Item { Layout.fillWidth: true; Layout.fillHeight: true }

            Group {
                Layout.alignment: Qt.AlignCenter

                // Coupé : barré ; sans réseau : en retrait ; absent sans
                // interface sans fil.
                IconButton {
                    id: wifiButton
                    visible: tablet.wifiState !== ""
                    icon: tablet.wifiState === "unavailable" ? "wifi-off.svg" : "wifi.svg"
                    tint: tablet.wifiState === "connected" ? Theme.iconColor : Theme.textDim
                    active: tablet.menu === "wifi"
                    onTapped: tablet.toggleMenu("wifi", wifiButton)
                }

                // À l'accent quand un appareil est connecté, en retrait
                // adaptateur éteint ; absent sans adaptateur.
                IconButton {
                    id: btButton
                    visible: tablet.btPresent
                    icon: "bluetooth.svg"
                    tint: tablet.btConnected ? Theme.accentColor
                        : tablet.btPowered ? Theme.iconColor : Theme.textDim
                    active: tablet.menu === "bluetooth"
                    onTapped: tablet.toggleMenu("bluetooth", btButton)
                }

                IconButton {
                    id: powerButton
                    icon: "power.svg"
                    active: tablet.menu === "power"
                    onTapped: tablet.toggleMenu("power", powerButton)
                }
            }

        }

        // ── Les workspaces ───────────────────────────────────────
        // Au milieu exact de la bande, quoi qu'il y ait aux deux bouts ;
        // sans aplat : la pastille du courant suffit à les lier.
        Group {
            id: wsGroup
            anchors.centerIn: parent

            // La pastille du workspace courant, celle des onglets des
            // widgets, qui glisse vers le suivant.
            readonly property Item focusedItem: tablet.current >= 1 && tablet.current <= 5
                                                ? wsRepeater.itemAt(tablet.current - 1) : null
            underlay: Rectangle {
                x: wsGroup.focusedItem ? wsGroup.focusedItem.x : 0
                y: wsGroup.focusedItem ? wsGroup.focusedItem.y : 0
                width: tablet.hit
                height: tablet.hit
                radius: Theme.radiusSmall
                color: Theme.selectedFill
                opacity: wsGroup.focusedItem ? 1 : 0
                Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                Behavior on opacity { NumberAnimation { duration: 160 } }
            }

            Repeater {
                id: wsRepeater
                model: tablet.workspaceIds

                Target {
                    id: wsButton
                    required property int modelData
                    readonly property bool focused: wsButton.modelData === tablet.current

                    // Le voile du survol, pas sur le courant : sa pastille
                    // suffit.
                    revealed: !wsButton.focused
                    onTapped: tablet.goTo(wsButton.modelData)

                    Text {
                        anchors.centerIn: parent
                        text: wsButton.modelData
                        font.family: tablet.uiFont
                        font.pixelSize: 14
                        font.weight: wsButton.focused ? Font.DemiBold : Font.Medium
                        font.features: { "tnum": 1 }
                        color: wsButton.focused ? Theme.accentColor
                             : tablet.occupied(wsButton.modelData) ? Theme.textPrimary
                             : Theme.textDim
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }
                }
            }
        }

        // Le flocon, juste sous les workspaces (à leur droite en portrait).
        Flake {
            x: tablet.portrait ? wsGroup.x + wsGroup.width + 8 : (parent.width - width) / 2
            y: tablet.portrait ? (parent.height - height) / 2 : wsGroup.y + wsGroup.height + 8
        }
    }

    // ── Le volet ─────────────────────────────────────────────────
    // Le menu déplié, contre la barre, à la hauteur de son bouton. Une surface
    // plein écran, cliquable partout sauf sur la bande (son masque) : un tap
    // à côté du menu le replie, un tap sur la bande va à ses boutons.
    PanelWindow { // qmllint disable uncreatable-type
        id: flyout
        screen: tablet.screen
        visible: tablet.menu !== ""

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-tablet-menu"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

        anchors { top: true; bottom: true; left: true; right: true }
        // Par-dessus la place de la bande : les coordonnées sont celles de
        // l'écran.
        exclusiveZone: -1
        color: "transparent"

        mask: Region { item: outside } // qmllint disable unqualified

        // Tout l'écran, sauf la bande.
        Item {
            id: outside
            x: tablet.portrait ? 0 : tablet.thickness
            width: flyout.width - (tablet.portrait ? 0 : tablet.thickness)
            height: flyout.height - (tablet.portrait ? tablet.thickness : 0)

            TapHandler {
                onTapped: tablet.menu = ""
            }
        }

        Item {
            id: menuCard
            readonly property int gap: 8
            width: menuLoader.width
            height: menuLoader.height
            x: tablet.portrait
               ? Math.max(gap, Math.min(flyout.width - width - gap, tablet.along - width / 2))
               : tablet.thickness + gap
            y: tablet.portrait
               ? flyout.height - tablet.thickness - gap - height
               : Math.max(gap, Math.min(flyout.height - height - gap, tablet.along - height / 2))

            // Il arrive comme la barre de conversation : en glissant de
            // quelques pixels depuis la bande, sans rebond.
            property real reveal: flyout.visible ? 1 : 0
            Behavior on reveal { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            opacity: Math.min(1, menuCard.reveal * 1.6)
            transform: Translate {
                x: tablet.portrait ? 0 : -8 * (1 - menuCard.reveal)
                y: tablet.portrait ? 8 * (1 - menuCard.reveal) : 0
            }

            focus: true
            Keys.onEscapePressed: tablet.menu = ""

            Loader {
                id: menuLoader
                sourceComponent: tablet.menu === "battery" ? batteryMenu
                               : tablet.menu === "wifi" ? wifiMenu
                               : tablet.menu === "bluetooth" ? btMenu
                               : tablet.menu === "power" ? powerMenu
                               : null
            }
        }
    }

    // Une durée lisible : « 45 min », « 2 h », « 2 h 15 min ».
    function duration(s) {
        var m = Math.round(s / 60);
        var h = Math.floor(m / 60);
        m = m % 60;
        if (h === 0)
            return I18n.tr("time.minutes", { n: Math.max(1, m) });
        if (m === 0)
            return I18n.tr("time.hours", { n: h });
        return I18n.tr("time.hours", { n: h }) + " " + I18n.tr("time.minutes", { n: m });
    }

    // La batterie : le pourcentage en grand, l'état, et le temps avant
    // qu'elle soit vide ou pleine (cf. Battery.secondsLeft).
    Component {
        id: batteryMenu
        MenuCard {
            implicitWidth: 260

            MenuTitle { text: I18n.tr("battery.app") }

            RowLayout {
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                Layout.bottomMargin: 8
                spacing: 14

                Row {
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        id: bigPercent
                        text: Battery.percent
                        font.family: tablet.uiFont
                        font.pixelSize: 34
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        color: Theme.textPrimary
                    }
                    Text {
                        anchors.baseline: bigPercent.baseline
                        leftPadding: 2
                        text: "%"
                        font.family: tablet.uiFont
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        color: Theme.textSecondary
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2

                    Text {
                        text: Battery.status === "Charging" ? I18n.tr("battery.charging")
                            : Battery.status === "Discharging" ? I18n.tr("battery.discharging")
                            : Battery.status === "Full" ? I18n.tr("battery.full")
                            : I18n.tr("battery.notCharging")
                        font.family: tablet.uiFont
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                    }
                    Text {
                        visible: Battery.status === "Charging" || Battery.status === "Discharging"
                        text: Battery.secondsLeft <= 0 ? I18n.tr("battery.estimating")
                            : Battery.status === "Charging"
                              ? I18n.tr("battery.untilFull", { time: tablet.duration(Battery.secondsLeft) })
                              : I18n.tr("battery.untilEmpty", { time: tablet.duration(Battery.secondsLeft) })
                        font.family: tablet.uiFont
                        font.pixelSize: 11
                        color: Theme.textSecondary
                    }
                }
            }
        }
    }

    Component {
        id: btMenu
        BluetoothMenu {
            open: true
            fontFamily: tablet.uiFont
        }
    }

    Component {
        id: wifiMenu
        MenuCard {
            WifiSettings {
                Layout.fillWidth: true
                Layout.margins: 8
            }
        }
    }

    Component {
        id: powerMenu
        MenuCard {
            MenuTitle { text: I18n.tr("power.title") }
            PowerRow { icon: "lock.svg"; label: I18n.tr("power.lock"); command: ["loginctl", "lock-session"] }
            PowerRow { icon: "suspend.svg"; label: I18n.tr("power.suspend"); command: ["systemctl", "suspend"] }
            PowerRow { icon: "logout.svg"; label: I18n.tr("power.logout"); command: ["hyprctl", "dispatch", "hl.dsp.exit()"] }
            PowerRow { icon: "reboot.svg"; label: I18n.tr("power.reboot"); command: ["systemctl", "reboot"] }
            PowerRow { icon: "power.svg"; label: I18n.tr("power.off"); command: ["systemctl", "poweroff"] }
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    // Des boutons à la suite, dans le sens de la barre, sans aplat.
    // `underlay` se pose sous eux (la pastille qui glisse des workspaces).
    component Group: Item {
        id: group
        default property alias content: buttons.data
        property Item underlay: null

        implicitWidth: buttons.width
        implicitHeight: buttons.height

        onUnderlayChanged: if (group.underlay) group.underlay.parent = under

        // Sous les boutons, à leurs coordonnées : un positionneur placerait
        // la pastille comme un bouton de plus.
        Item {
            id: under
            anchors.fill: buttons
        }

        Grid {
            id: buttons
            columns: tablet.portrait ? 100 : 1
            spacing: 0
        }
    }

    // Une cible au doigt, sans fond au repos : le survol (souris, stylet) et
    // l'appui la voilent, l'appui la tasse un peu.
    component Target: Rectangle {
        id: cell
        // Le voile du survol ; un bouton retenu porte la pastille à la place.
        property bool revealed: true
        property bool active: false
        readonly property bool hovered: hover.hovered || tap.pressed
        signal tapped()

        width: tablet.hit
        height: tablet.hit
        radius: Theme.radiusSmall
        color: cell.active ? Theme.selectedFill
             : cell.revealed && cell.hovered ? Theme.hoverOverlay
             : "transparent"
        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        scale: tap.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            id: tap
            onTapped: cell.tapped()
        }
    }

    // Un bouton à icône : l'icône à 80 % au repos, pleine au survol ; à
    // l'accent sur sa pastille quand son menu est ouvert, comme un onglet.
    component IconButton: Target {
        id: ib
        property string icon
        property color tint: Theme.iconColor

        NixIcon {
            anchors.centerIn: parent
            iconSize: tablet.glyph
            source: "../assets/icons/" + ib.icon
            color: ib.active ? Theme.accentColor : ib.tint
            opacity: ib.active || ib.hovered ? 1 : 0.8
            Behavior on color { ColorAnimation { duration: 180 } }
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
    }

    // Le flocon de la barre de conversation, nu : à 75 % au repos, il grossit
    // un peu au survol ; il tourne pendant que le pilote écoute, transcrit
    // ou travaille et passe alors à l'accent, comme le filet de la barre.
    component Flake: Item {
        id: logo
        readonly property bool turning: Pilot.voicePhase !== "idle" || Pilot.pilotBusy
        readonly property bool glowing: Pilot.voicePhase !== "idle" || Pilot.pilotBusy

        implicitWidth: tablet.hit
        implicitHeight: tablet.hit
        // Revient droit une fois le travail fini.
        onTurningChanged: if (!turning) settle.restart()

        Item {
            id: flake
            anchors.centerIn: parent
            width: 26
            height: 26
            scale: flakeTap.pressed ? 0.92 : flakeHover.hovered ? 1.06 : 1.0
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            RotationAnimation on rotation {
                running: logo.turning
                loops: Animation.Infinite
                from: flake.rotation
                to: flake.rotation + 360
                duration: 4200
            }
            NumberAnimation {
                id: settle
                target: flake
                property: "rotation"
                to: Math.round(flake.rotation / 60) * 60
                duration: 600
                easing.type: Easing.OutCubic
            }

            Image {
                id: flakeSource
                anchors.fill: parent
                source: "../assets/nixos.svg"
                sourceSize.width: 96
                sourceSize.height: 96
                fillMode: Image.PreserveAspectFit
                smooth: true
                visible: false
            }
            MultiEffect {
                anchors.fill: flakeSource
                source: flakeSource
                colorization: 1.0
                colorizationColor: logo.glowing ? Theme.accentColor : Theme.iconColor
                opacity: logo.glowing ? 1.0 : (flakeHover.hovered ? 0.95 : 0.75)
                Behavior on colorizationColor { ColorAnimation { duration: 200 } }
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
        }

        HoverHandler {
            id: flakeHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            id: flakeTap
            onTapped: tablet.askRequested()
        }
    }

    // La carte d'un menu, celle du menu Bluetooth (widgets/BluetoothMenu.qml) :
    // l'aplat, ses coins, son filet, et ses lignes à 8 px du bord.
    component MenuCard: Rectangle {
        default property alias content: column.data

        implicitWidth: 300
        implicitHeight: column.implicitHeight + 16
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: Theme.dividerColor

        ColumnLayout {
            id: column
            anchors.fill: parent
            anchors.margins: 8
            spacing: 2
        }
    }

    // Son en-tête, comme celui du menu Bluetooth.
    component MenuTitle: Text {
        Layout.leftMargin: 8
        Layout.preferredHeight: 34
        verticalAlignment: Text.AlignVCenter
        font.family: tablet.uiFont
        font.pixelSize: 13
        font.weight: Font.DemiBold
        color: Theme.textPrimary
    }

    // Une ligne d'alimentation, comme celles du menu Bluetooth : elle agit
    // dès le premier tap, comme les boutons de la barre du haut des widgets
    // (panels/HubTopBar.qml).
    component PowerRow: Rectangle {
        id: row
        property string icon
        property string label
        property var command: []
        readonly property bool hovered: rowHover.hovered || rowTap.pressed

        Layout.fillWidth: true
        Layout.preferredHeight: tablet.hit
        radius: Theme.radiusSmall
        color: Qt.alpha(Theme.textPrimary, row.hovered ? 0.08 : 0)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: rowTap.pressed ? 0.98 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            x: 10
            spacing: 12

            NixIcon {
                anchors.verticalCenter: parent.verticalCenter
                iconSize: 17
                source: "../assets/icons/" + row.icon
                color: Theme.iconColor
                opacity: row.hovered ? 1 : 0.8
                Behavior on opacity { NumberAnimation { duration: 160 } }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.label
                font.family: tablet.uiFont
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textPrimary
            }
        }

        HoverHandler {
            id: rowHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            id: rowTap
            onTapped: tablet.power(row.command)
        }
    }

    // La batterie de la barre du haut des widgets, debout et monochrome : le
    // corps à 25 %, le niveau qui le remplit depuis le bas (depuis la gauche
    // en portrait), la borne pleine une fois chargée ; l'éclair dedans
    // pendant la charge, clair sur le vide, sombre sur le plein. Sous le
    // seuil d'alerte (Battery.lowAt), sans chargeur, elle bat doucement.
    component BatteryLevel: Item {
        id: bat
        readonly property real level: Math.max(0, Math.min(100, Battery.percent)) / 100
        readonly property bool charging: Battery.status === "Charging"
                                         || (Battery.status === "Full" && Battery.percent >= 99)
        readonly property bool low: Battery.status === "Discharging"
                                    && Battery.percent <= Battery.lowAt

        width: tablet.portrait ? 30 : 14
        height: tablet.portrait ? 14 : 30

        SequentialAnimation on opacity {
            running: bat.low
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
            onRunningChanged: if (!running) bat.opacity = 1
        }

        // La borne.
        Rectangle {
            x: tablet.portrait ? parent.width - 2 : (parent.width - width) / 2
            y: tablet.portrait ? (parent.height - height) / 2 : 0
            width: tablet.portrait ? 2 : 5
            height: tablet.portrait ? 5 : 2
            radius: 1
            color: Qt.alpha(Theme.textPrimary, bat.level >= 0.99 ? 0.9 : 0.25)
        }

        // Le corps.
        Rectangle {
            id: shell
            y: tablet.portrait ? 0 : 2
            width: tablet.portrait ? parent.width - 2 : parent.width
            height: tablet.portrait ? parent.height : parent.height - 2
            radius: 3.5
            color: Qt.alpha(Theme.textPrimary, 0.25)

            // L'éclair sur le vide.
            NixIcon {
                anchors.centerIn: parent
                visible: bat.charging
                iconSize: 10
                source: "../assets/icons/bolt.svg"
                color: Theme.textPrimary
            }

            // Le niveau, arrondi comme le corps, et l'éclair sombre qu'il
            // découpe.
            Item {
                readonly property real fill: tablet.portrait ? shell.width * bat.level
                                                             : shell.height * bat.level
                y: tablet.portrait ? 0 : shell.height - height
                width: tablet.portrait ? Math.round(fill) : shell.width
                height: tablet.portrait ? shell.height : Math.round(fill)
                clip: true
                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

                Item {
                    y: tablet.portrait ? 0 : parent.height - shell.height
                    width: shell.width
                    height: shell.height

                    Rectangle {
                        anchors.fill: parent
                        radius: shell.radius
                        color: Qt.alpha(Theme.textPrimary, 0.9)
                    }
                    NixIcon {
                        anchors.centerIn: parent
                        visible: bat.charging
                        iconSize: 10
                        source: "../assets/icons/bolt.svg"
                        color: Theme.bgDeep
                    }
                }
            }
        }
    }
}
