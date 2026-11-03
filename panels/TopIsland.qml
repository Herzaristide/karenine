pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Bluetooth
import "../services"
import "../widgets"

// La barre du haut : une pilule collée au milieu du bord du haut, la sœur
// de celle des niveaux (LevelsIsland, au bord droit). Cachée la plupart du
// temps, elle descend du bord avec les widgets (le flocon, Super, anna) ou
// quand la souris approche du bord du haut, au milieu, et repart avec eux,
// ou un instant après la souris. Cachée, la fenêtre ne garde qu'un fil de
// quelques pixels contre le bord : c'est lui qui sent la souris arriver.
//
//   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ bord
//   ╰ ⏻ 🔔³ [87]▸ │ 1 (2) 3 4 5 │ ᛒ ⌗ ● ╯
//
// Au milieu exact, les workspaces 1-5 de l'écran : le courant sur la
// pastille de l'accent, ceux qui ont des fenêtres en clair ; les deux côtés
// ont la même largeur. À gauche l'alimentation, qui déplie son menu
// (verrouiller, mettre en veille, se déconnecter, redémarrer, éteindre ;
// les deux derniers demandent un second clic), les notifications (leur
// nombre en pastille ; la cloche déplie la liste,
// widgets/NotificationCenter.qml, centrée sous la barre) et la batterie. À
// droite le Bluetooth (widgets/BluetoothMenu.qml), la capture et
// l'enregistrement de l'écran.
//
// Pendant un enregistrement (le micro ou l'écran, services/Recorder.qml),
// elle reste là, même widgets fermés, réduite à l'enregistrement en cours :
// son icône rouge qui bat, le temps écoulé, et ■ pour l'arrêter.
//
//   ╰ ⏺ 1:05 ■ ╯
//
// Les menus se déplient sous leur bouton (les notifications, au milieu) ;
// ils se replient sur le même bouton, quand un autre s'ouvre, ou avec la
// barre.
PanelWindow { // qmllint disable uncreatable-type
    id: island

    // Verrouiller, dormir, capturer : la barre de conversation doit partir
    // d'abord (shell.qml la renvoie).
    signal dismissRequested()

    readonly property string uiFont: "Inter"
    // La hauteur visible de la barre ; elle dépasse en plus du bord de son
    // arrondi, pour que seuls les coins du bas soient ronds.
    readonly property int pillH: 46
    readonly property int btnSize: 30
    // Les menus ne descendent pas jusqu'à la capsule des widgets.
    readonly property int menuMaxH: Math.min(420, Math.round((island.screen ? island.screen.height : 900) * 0.42))

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-top"
    // Le clavier seulement pour un menu ouvert (répondre à une notification).
    WlrLayershell.keyboardFocus: island.menu === "bluetooth" || Widgets.notificationsOpen
                                 ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // Ancrée en haut seulement : la surface se centre sur la largeur.
    anchors { top: true }
    exclusiveZone: 0
    implicitWidth: 960
    implicitHeight: island.pillH + 8 + island.menuMaxH + 16
    color: "transparent"

    // Le fil qui guette la souris : sa largeur, au milieu du bord, et son
    // épaisseur.
    readonly property int hotW: 480
    readonly property int hotT: 6

    mask: Region { // qmllint disable unqualified
        Region { item: island.reveal > 0 ? zone : null }
        Region { item: island.shown ? null : hotStrip }
        Region { item: island.menu === "bluetooth" ? btMenu : null }
        Region { item: island.menu === "power" ? powerMenu : null }
        Region { item: Widgets.notificationsOpen && island.reveal > 0 ? notifMenu : null }
    }

    // ── Quand se montrer ─────────────────────────────────────────
    readonly property bool recording: Recorder.audioOn || Recorder.screenOn
    readonly property bool shown: Widgets.hubOpen || island.recording || island.hoverHold
    // Seulement l'enregistrement : la barre réduite.
    readonly property bool compact: island.recording && !Widgets.hubOpen && !island.hoverHold

    // La souris survole le fil, la barre ou un menu ; elle a un peu de
    // temps pour revenir avant que la barre ne reparte.
    property bool hoverHold: false
    readonly property bool hovered: hover.hovered
    onHoveredChanged: {
        if (island.hovered) {
            leave.stop();
            island.hoverHold = true;
        } else {
            leave.restart();
        }
    }
    Timer {
        id: leave
        interval: 700
        onTriggered: island.hoverHold = false
    }

    // De 0 (cachée, derrière le bord du haut) à 1 (là).
    property real reveal: island.shown ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: island.shown ? 320 : 220
            easing.type: island.shown ? Easing.OutQuint : Easing.InCubic
        }
    }

    // La souris sur la barre ou un menu : la barre de conversation ne la
    // croit pas partie (cf. ConversationBar.pointerInside).
    Binding {
        target: Widgets
        property: "topIslandHovered"
        value: hover.hovered && island.reveal > 0
    }

    // ── Les menus ────────────────────────────────────────────────
    // "" (aucun), "power" ou "bluetooth" ici ; les notifications dans
    // Widgets (anna les ouvre). L'un chasse l'autre ; réduite ou repartie,
    // la barre n'en garde aucun (avec les widgets ouverts, les
    // notifications suivent la capsule).
    property string menu: ""
    onMenuChanged: {
        island.armed = "";
        if (island.menu !== "")
            Widgets.notificationsOpen = false;
    }
    onCompactChanged: if (island.compact) island.menu = ""
    onShownChanged: {
        if (island.shown)
            return;
        island.menu = "";
        if (!Widgets.hubOpen)
            Widgets.notificationsOpen = false;
    }
    Connections {
        target: Widgets
        function onNotificationsOpenChanged() {
            if (Widgets.notificationsOpen)
                island.menu = "";
        }
    }

    function toggleMenu(name) {
        island.menu = island.menu === name ? "" : name;
    }

    // Le x d'un menu de largeur `w` sous `button`, aligné sur son bord
    // droit (gauche avec `fromLeft`), sans sortir de la surface.
    function menuX(button, w, fromLeft) {
        var p = button.mapToItem(root, fromLeft ? 0 : button.width, 0);
        return Math.max(8, Math.min(fromLeft ? p.x : p.x - w, root.width - w - 8));
    }

    // ── Les workspaces ───────────────────────────────────────────
    // Les principaux (1-5) seulement, attachés à l'écran de l'interface (cf.
    // services/Display.qml) : les autres appartiennent chacun à son écran.
    readonly property var monitor: island.screen ? Hyprland.monitorFor(island.screen) : null
    readonly property int current: island.monitor && island.monitor.activeWorkspace
                                   ? island.monitor.activeWorkspace.id : -1
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

    readonly property int notifCount: Notifications.all.length
    // La largeur commune des deux côtés de la barre, autour des workspaces.
    readonly property real sideW: Math.max(leftGroup.implicitWidth, rightGroup.implicitWidth)

    // ── L'alimentation ───────────────────────────────────────────
    // Verrouiller ou dormir : la barre de conversation ne doit pas rester
    // ouverte derrière, même appelée par Super (le champ la retiendrait).
    function power(argv, closeFirst) {
        island.menu = "";
        if (closeFirst)
            island.dismissRequested();
        Quickshell.execDetached(argv);
    }

    // Redémarrer ou éteindre : un premier clic arme la ligne (« Éteindre ? »),
    // un second, dans les trois secondes, agit.
    property string armed: ""
    Timer {
        running: island.armed !== ""
        interval: 3000
        onTriggered: island.armed = ""
    }

    // ── La capture d'écran ───────────────────────────────────────
    // Clic : une région ; clic droit : l'écran entier. Copiée et enregistrée
    // dans le dossier Images (xdg-user-dirs). Les widgets se ferment
    // d'abord, et on attend que tout ait disparu pour ne pas le capturer.
    readonly property string picturesDir:
        StandardPaths.writableLocation(StandardPaths.PicturesLocation).toString().replace(/^file:\/\//, "")

    function screenshot(region) {
        island.dismissRequested();
        shotTimer.region = region;
        shotTimer.restart();
    }

    Timer {
        id: shotTimer
        property string region: "area"
        interval: 350
        onTriggered: {
            var path = island.picturesDir + "/capture-"
                     + Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss") + ".png";
            // Détaché et sans shell : la sélection dure le temps qu'il faut.
            Quickshell.execDetached(["grimblast", "--notify", "copysave", shotTimer.region, path]);
        }
    }

    // ── L'enregistrement de l'écran ──────────────────────────────
    // anna le tient (services/Recorder.qml) : clic, une région ; clic droit,
    // l'écran qui a le focus ; avec le son de l'ordinateur. Les widgets
    // disparaissent d'abord pour ne pas être filmés ; la barre, réduite,
    // reste pour l'arrêter.
    function screenRecord(region) {
        island.dismissRequested();
        recTimer.region = region;
        recTimer.restart();
    }

    Timer {
        id: recTimer
        property string region: "area"
        interval: 350
        onTriggered: Recorder.toggleScreen(recTimer.region)
    }

    // ── Le Bluetooth, pour la teinte de son bouton ───────────────
    readonly property bool btPowered: Bluetooth.defaultAdapter !== null && Bluetooth.defaultAdapter.enabled // qmllint disable unresolved-type
    readonly property bool btConnected: island.btPowered
                                        && Bluetooth.defaultAdapter.devices.values.some(d => d.connected) // qmllint disable unresolved-type

    Item {
        id: root
        anchors.fill: parent

        HoverHandler { id: hover }

        // Le fil qui guette la souris, collé au bord du haut.
        Item {
            id: hotStrip
            anchors.horizontalCenter: parent.horizontalCenter
            width: island.hotW
            height: island.hotT
        }

        // La barre et un peu de marge dessous : la zone qui reçoit la souris
        // une fois la barre là, pour ne pas la perdre au moindre écart.
        Item {
            id: zone
            anchors.horizontalCenter: parent.horizontalCenter
            width: pill.width + 24
            height: island.pillH + 12
        }

        Rectangle {
            id: pill
            anchors.horizontalCenter: parent.horizontalCenter
            y: -Theme.radius - (island.pillH + 4) * (1 - island.reveal)
            opacity: island.reveal
            visible: island.reveal > 0
            width: row.implicitWidth + 20
            height: island.pillH + Theme.radius
            radius: Theme.radius
            color: Theme.bgDeep
            border.width: 1
            border.color: island.recording ? Qt.alpha(Theme.colorDanger, 0.45) : Theme.dividerColor
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            Behavior on border.color { ColorAnimation { duration: 200 } }
            clip: true

            RowLayout {
                id: row
                anchors.horizontalCenter: parent.horizontalCenter
                y: Theme.radius
                height: island.pillH
                spacing: 2

                // ── À gauche : l'alimentation, les notifications, la batterie ──
                // Aussi large que le groupe de droite : les workspaces
                // tombent au milieu exact de la barre.
                RowLayout {
                    id: leftGroup
                    visible: !island.compact
                    Layout.preferredWidth: island.sideW
                    spacing: 2

                    Item { Layout.fillWidth: true }
                    IconButton {
                        id: powerButton
                        icon: "power.svg"
                        tint: island.menu === "power" ? Theme.accentColor : Theme.iconColor
                        onClicked: island.toggleMenu("power")
                    }
                    IconButton {
                        id: bellButton
                        icon: "bell.svg"
                        tint: Widgets.notificationsOpen ? Theme.accentColor : Theme.iconColor
                        onClicked: Widgets.notificationsOpen = !Widgets.notificationsOpen

                        // Le nombre, en pastille dans le coin ; rien sans notification.
                        Rectangle {
                            visible: island.notifCount > 0
                            x: parent.width - width + 2
                            y: -2
                            width: Math.max(height, badgeText.implicitWidth + 8)
                            height: 14
                            radius: height / 2
                            color: Theme.accentColor

                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: island.notifCount > 99 ? "99+" : island.notifCount
                                font.family: island.uiFont
                                font.pixelSize: 9
                                font.weight: Font.Bold
                                font.features: { "tnum": 1 }
                                color: Theme.bgDeep
                            }
                        }
                    }
                    BatteryIcon {
                        visible: Battery.present
                        Layout.leftMargin: 6
                        Layout.rightMargin: 4
                    }
                }

                Separator { visible: !island.compact }

                // ── Les workspaces ──
                Item {
                    id: wsGroup
                    visible: !island.compact
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: wsRow.implicitWidth
                    implicitHeight: island.btnSize

                    // La pastille du workspace courant, celle des onglets des
                    // widgets, qui glisse vers le suivant.
                    readonly property Item focusedItem: island.current >= 1 && island.current <= 5
                                                        ? wsRepeater.itemAt(island.current - 1) : null
                    Rectangle {
                        x: wsGroup.focusedItem ? wsGroup.focusedItem.x : 0
                        width: island.btnSize
                        height: island.btnSize
                        radius: Theme.radiusSmall
                        color: Theme.selectedFill
                        opacity: wsGroup.focusedItem ? 1 : 0
                        Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                        Behavior on opacity { NumberAnimation { duration: 160 } }
                    }

                    Row {
                        id: wsRow
                        spacing: 2

                        Repeater {
                            id: wsRepeater
                            model: island.workspaceIds

                            Rectangle {
                                id: wsButton
                                required property int modelData
                                readonly property bool focused: wsButton.modelData === island.current

                                width: island.btnSize
                                height: island.btnSize
                                radius: Theme.radiusSmall
                                // Le voile du survol, pas sur le courant : sa
                                // pastille suffit.
                                color: wsMa.containsMouse && !wsButton.focused ? Theme.hoverOverlay : "transparent"
                                Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                scale: wsMa.pressed ? 0.92 : 1
                                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                                Text {
                                    anchors.centerIn: parent
                                    text: wsButton.modelData
                                    font.family: island.uiFont
                                    font.pixelSize: 13
                                    font.weight: wsButton.focused ? Font.DemiBold : Font.Medium
                                    font.features: { "tnum": 1 }
                                    color: wsButton.focused ? Theme.accentColor
                                         : island.occupied(wsButton.modelData) ? Theme.textPrimary
                                         : Theme.textDim
                                    Behavior on color { ColorAnimation { duration: 220 } }
                                }
                                MouseArea {
                                    id: wsMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: island.goTo(wsButton.modelData)
                                }
                            }
                        }
                    }
                }

                Separator { visible: !island.compact }

                // ── À droite : le Bluetooth, la capture, l'enregistrement ──
                RowLayout {
                    id: rightGroup
                    Layout.preferredWidth: island.compact ? -1 : island.sideW
                    spacing: 2

                    // Teinté quand un appareil est connecté, éteint avec
                    // l'adaptateur ; absent sans adaptateur.
                    IconButton {
                        id: btButton
                        visible: !island.compact && Bluetooth.defaultAdapter !== null // qmllint disable unresolved-type
                        icon: "bluetooth.svg"
                        tint: island.btConnected ? Theme.accentColor
                            : island.btPowered ? Theme.iconColor : Theme.textDim
                        onClicked: island.toggleMenu("bluetooth")
                    }
                    IconButton {
                        visible: !island.compact
                        icon: "screenshot.svg"
                        onClicked: (button) => island.screenshot(button === Qt.RightButton ? "screen" : "area")
                    }
                    // Pendant l'enregistrement, son étiquette prend sa place.
                    IconButton {
                        visible: !island.compact && Recorder.available && !Recorder.screenOn
                        icon: "screen-record.svg"
                        onClicked: (button) => island.screenRecord(button === Qt.RightButton ? "screen" : "area")
                    }

                    // ── Les enregistrements en cours ──
                    Separator { visible: !island.compact && island.recording }
                    RecordingTag {
                        visible: Recorder.screenOn
                        kind: "screen"
                        icon: "screen-record.svg"
                        track: Recorder.screen
                    }
                    Separator { visible: Recorder.screenOn && Recorder.audioOn }
                    RecordingTag {
                        visible: Recorder.audioOn
                        kind: "audio"
                        icon: "mic.svg"
                        track: Recorder.audio
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // ── Les menus, sous leur bouton ──────────────────────────
        Rectangle {
            id: powerMenu
            visible: island.menu === "power"
            y: island.pillH + 8
            width: 220
            height: powerColumn.implicitHeight + 16
            radius: Theme.radius
            color: Theme.bgElevated
            border.width: 1
            border.color: Theme.dividerColor
            onVisibleChanged: if (visible) powerMenu.x = island.menuX(powerButton, powerMenu.width, true)

            // Les clics sur le menu ne traversent pas.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            ColumnLayout {
                id: powerColumn
                anchors.fill: parent
                anchors.margins: 8
                spacing: 2

                Text {
                    Layout.leftMargin: 8
                    Layout.preferredHeight: 34
                    verticalAlignment: Text.AlignVCenter
                    text: I18n.tr("power.title")
                    font.family: island.uiFont
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    color: Theme.textPrimary
                }
                PowerRow { icon: "lock.svg"; label: I18n.tr("power.lock"); command: ["loginctl", "lock-session"]; closeFirst: true }
                PowerRow { icon: "suspend.svg"; label: I18n.tr("power.suspend"); command: ["systemctl", "suspend"]; closeFirst: true }
                PowerRow { icon: "logout.svg"; label: I18n.tr("power.logout"); command: ["hyprctl", "dispatch", "hl.dsp.exit()"] }
                PowerRow {
                    key: "reboot"
                    icon: "reboot.svg"
                    label: I18n.tr("power.reboot")
                    confirm: I18n.tr("power.rebootConfirm")
                    command: ["systemctl", "reboot"]
                }
                PowerRow {
                    key: "off"
                    icon: "power.svg"
                    label: I18n.tr("power.off")
                    confirm: I18n.tr("power.offConfirm")
                    command: ["systemctl", "poweroff"]
                }
            }
        }

        BluetoothMenu {
            id: btMenu
            visible: island.menu === "bluetooth"
            open: island.menu === "bluetooth"
            fontFamily: island.uiFont
            y: island.pillH + 8
            Keys.onEscapePressed: island.menu = ""
            onVisibleChanged: if (visible) btMenu.x = island.menuX(btButton, btMenu.width)
        }

        Rectangle {
            id: notifMenu
            visible: Widgets.notificationsOpen && island.reveal > 0
            y: island.pillH + 8
            width: 380
            height: Math.min(island.menuMaxH, notifCenter.implicitHeight + 24)
            radius: Theme.radius
            color: Theme.bgElevated
            border.width: 1
            border.color: Theme.dividerColor

            // Au milieu, sous la barre.
            anchors.horizontalCenter: parent.horizontalCenter

            // Les clics sur le menu ne traversent pas.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: (wheel) => wheel.accepted = true
            }

            NotificationCenter {
                id: notifCenter
                anchors.fill: parent
                anchors.margins: 12
            }
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    component Separator: Rectangle {
        Layout.leftMargin: 6
        Layout.rightMargin: 6
        Layout.preferredWidth: 1
        Layout.preferredHeight: 18
        Layout.alignment: Qt.AlignVCenter
        color: Qt.alpha(Theme.textPrimary, 0.12)
    }

    // Un bouton rond, sans fond au repos : le survol le révèle.
    component IconButton: Rectangle {
        id: ib
        property string icon
        property color tint: Theme.iconColor
        signal clicked(int button)

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: island.btnSize
        implicitHeight: island.btnSize
        radius: Theme.radiusSmall
        color: ibMa.containsMouse ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        scale: ibMa.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        NixIcon {
            anchors.centerIn: parent
            iconSize: 17
            source: "../assets/icons/" + ib.icon
            color: ib.tint
            opacity: ibMa.containsMouse ? 1 : 0.8
            Behavior on color { ColorAnimation { duration: 180 } }
        }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => ib.clicked(mouse.button)
        }
    }

    // Une ligne du menu d'alimentation, comme celles du menu Bluetooth. Avec
    // `confirm`, le premier clic l'arme (teintée, sa question à la place du
    // nom) et le second agit.
    component PowerRow: Rectangle {
        id: pr
        property string key
        property string icon
        property string label
        property string confirm
        property var command: []
        property bool closeFirst: false
        readonly property bool armed: pr.key !== "" && island.armed === pr.key

        function press() {
            if (pr.confirm !== "" && !pr.armed) {
                island.armed = pr.key;
                return;
            }
            island.power(pr.command, pr.closeFirst);
        }

        Layout.fillWidth: true
        Layout.preferredHeight: 34
        radius: Theme.radiusSmall
        color: pr.armed ? Qt.alpha(Theme.colorDanger, 0.18)
             : prMa.containsMouse ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: prMa.pressed ? 0.98 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            x: 10
            spacing: 12

            NixIcon {
                anchors.verticalCenter: parent.verticalCenter
                iconSize: 17
                source: "../assets/icons/" + pr.icon
                color: pr.armed ? Theme.colorDanger : Theme.iconColor
                opacity: pr.armed || prMa.containsMouse ? 1 : 0.8
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pr.armed ? pr.confirm : pr.label
                font.family: island.uiFont
                font.pixelSize: 12
                font.weight: pr.armed ? Font.DemiBold : Font.Medium
                color: pr.armed ? Theme.colorDanger : Theme.textPrimary
            }
        }

        MouseArea {
            id: prMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pr.press()
        }
    }

    // Un enregistrement en cours : son icône rouge qui bat, le temps
    // écoulé, et ■ pour l'arrêter.
    component RecordingTag: RowLayout {
        id: tag
        property string kind
        property string icon
        property var track: null

        Layout.alignment: Qt.AlignVCenter
        spacing: 6

        NixIcon {
            Layout.alignment: Qt.AlignVCenter
            Layout.leftMargin: 6
            iconSize: 16
            source: "../assets/icons/" + tag.icon
            color: Theme.colorDanger
            SequentialAnimation on opacity {
                running: tag.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
        Text {
            Layout.alignment: Qt.AlignVCenter
            text: Recorder.elapsed(tag.track)
            font.family: island.uiFont
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: Theme.colorDanger
        }
        IconButton {
            icon: "stop.svg"
            onClicked: Recorder.stop(tag.kind)
        }
    }

    // La batterie d'un téléphone : un corps arrondi, sa borne à droite, le
    // niveau qui le remplit et le pourcentage gravé dedans — clair sur la
    // partie vide, sombre sur la partie pleine. Verte en charge (avec
    // l'éclair), rouge sous 20 %.
    component BatteryIcon: Row {
        id: bat
        readonly property real level: Math.max(0, Math.min(100, Battery.percent)) / 100
        readonly property bool charging: Battery.status === "Charging"
                                         || (Battery.status === "Full" && Battery.percent >= 99)
        readonly property color tone: bat.charging ? Theme.colorSuccess
                                    : Battery.percent <= 20 ? Theme.colorDanger
                                    : Theme.textPrimary

        Layout.alignment: Qt.AlignVCenter
        spacing: 3

        // L'éclair, le temps de la charge.
        NixIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: bat.charging
            iconSize: 12
            source: "../assets/icons/bolt.svg"
            color: bat.tone
        }

        // Le corps.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 25
            height: 12

            Rectangle {
                id: shell
                anchors.fill: parent
                radius: 3.5
                color: Qt.alpha(Theme.textPrimary, 0.25)
            }

            // Le niveau, arrondi comme le corps.
            Item {
                id: fillClip
                width: Math.round(shell.width * bat.level)
                height: shell.height
                clip: true
                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

                Rectangle {
                    width: shell.width
                    height: shell.height
                    radius: shell.radius
                    color: bat.tone
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
            }

            // Le pourcentage : deux fois le même texte, l'un sur le vide,
            // l'autre — sombre — découpé à la largeur du niveau.
            Text {
                id: pctLabel
                anchors.centerIn: parent
                text: Battery.percent
                font.family: island.uiFont
                font.pixelSize: 9
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
                color: Theme.textPrimary
            }
            Item {
                width: fillClip.width
                height: shell.height
                clip: true

                Text {
                    x: pctLabel.x
                    y: pctLabel.y
                    text: pctLabel.text
                    font: pctLabel.font
                    color: Theme.bgDeep
                }
            }
        }

        // La borne.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 2
            height: 4
            radius: 1
            color: bat.level >= 0.99 ? bat.tone : Qt.alpha(Theme.textPrimary, 0.25)
        }
    }
}
