pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import "../services"
import "../widgets"

// La barre du haut des widgets, la même quel que soit l'onglet. Quatre
// groupes posés sur le fond, chacun sur son aplat : l'alimentation à
// gauche, les niveaux (luminosité, volume) au milieu, le Bluetooth et la
// capture, puis la batterie à droite. Le Bluetooth déplie la liste des
// appareils (widgets/BluetoothMenu.qml).
//
//   ╭ 🔒 ☾ ⇥ ↻ ⏻ ╮   ╭ ☀ ━━●── 80 %  │  🔊 ━━━●─ 64 % ╮  ╭ ᛒ ⌗ ╮  ╭ [87]▸ ╮
//
// Chaque bouton d'alimentation agit dès le premier clic, sans confirmation.
// Les curseurs se partagent la place qui reste : la barre peut être étroite.
//
// Au clavier : Tab passe d'un bouton à l'autre, Entrée ou Espace l'actionne.
// Maj+Entrée sur la
// capture prend l'écran entier, comme le clic droit. Sur un curseur, ← →
// (ou ↑ ↓) règlent par pas, Début et Fin vont aux bouts.
Item {
    id: top

    // La barre de conversation : sa teinte, sa police.
    required property var bar

    implicitHeight: 38

    // Les boutons dans une pilule : un peu plus petits qu'elle.
    readonly property int btnSize: top.height - 8

    // ── L'alimentation ───────────────────────────────────────────
    Process {
        id: powerProc
    }

    function run(argv, closeFirst) {
        // Verrouiller ou dormir : la barre ne doit pas rester ouverte derrière,
        // même appelée par Super (le champ la retiendrait).
        if (closeFirst)
            top.bar.dismiss();
        powerProc.command = argv;
        powerProc.running = true;
    }

    // ── La capture d'écran ───────────────────────────────────────
    // Clic : une région ; clic droit : l'écran entier. Copiée et enregistrée
    // dans le dossier Images (xdg-user-dirs). La barre se ferme d'abord, et
    // on attend qu'elle ait disparu pour ne pas la capturer.
    readonly property string picturesDir:
        StandardPaths.writableLocation(StandardPaths.PicturesLocation).toString().replace(/^file:\/\//, "")

    function screenshot(region) {
        top.bar.dismiss();
        shotTimer.region = region;
        shotTimer.restart();
    }

    Timer {
        id: shotTimer
        property string region: "area"
        interval: 350
        onTriggered: {
            var path = top.picturesDir + "/capture-"
                     + Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss") + ".png";
            // Détaché et sans shell : la sélection dure le temps qu'il faut.
            Quickshell.execDetached(["grimblast", "--notify", "copysave", shotTimer.region, path]);
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    // Un aplat qui porte un groupe : le panneau, un ton au-dessus du fond.
    component Pill: Rectangle {
        Layout.preferredHeight: top.height
        radius: Theme.radiusSmall
        color: Theme.bgElevated
    }

    // Une icône teinte (les SVG sont blancs).
    component Glyph: Item {
        id: glyph
        property string icon
        property color tint: Theme.iconColor
        property real strength: 0.8

        width: 17
        height: 17

        Image {
            id: glyphSrc
            anchors.fill: parent
            source: "../assets/icons/" + glyph.icon
            sourceSize.width: 48
            sourceSize.height: 48
            visible: false
        }
        MultiEffect {
            anchors.fill: glyphSrc
            source: glyphSrc
            colorization: 1.0
            colorizationColor: glyph.tint
            opacity: glyph.strength
            Behavior on colorizationColor { ColorAnimation { duration: 180 } }
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
    }

    // Un bouton rond, sans fond au repos : le survol le révèle.
    component IconButton: Rectangle {
        id: ib
        property string icon
        property color tint: Theme.iconColor
        // Signale un état (muet…) : teinté en permanence.
        property color alertColor: "transparent"
        readonly property bool alerted: ib.alertColor.a > 0
        readonly property bool hovered: ibMa.containsMouse || ib.activeFocus
        signal clicked(int button)

        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                ib.clicked(event.modifiers & Qt.ShiftModifier ? Qt.RightButton : Qt.LeftButton);
                event.accepted = true;
            }
        }

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: top.btnSize
        implicitHeight: top.btnSize
        radius: Theme.radiusSmall
        color: ib.alerted ? Qt.alpha(ib.alertColor, 0.18)
                          : ib.hovered ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        scale: ibMa.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Glyph {
            anchors.centerIn: parent
            icon: ib.icon
            tint: ib.alerted ? ib.alertColor : ib.tint
            strength: ib.alerted || ib.hovered ? 1 : 0.8
        }
        FocusRing { gap: 1 }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => ib.clicked(mouse.button)
        }
    }

    // Un bouton d'alimentation : un clic, et la commande part.
    component PowerButton: Rectangle {
        id: pb
        property string icon
        property var command: []
        property bool closeFirst: false

        readonly property bool hovered: pbMa.containsMouse || pb.activeFocus

        function press() {
            top.run(pb.command, pb.closeFirst);
        }

        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                pb.press();
                event.accepted = true;
            }
        }

        anchors.verticalCenter: parent.verticalCenter
        height: top.btnSize
        width: top.btnSize
        radius: Theme.radiusSmall
        color: pb.hovered ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
        scale: pbMa.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Glyph {
            anchors.centerIn: parent
            icon: pb.icon
            tint: Theme.iconColor
            strength: pb.hovered ? 1 : 0.8
        }

        MouseArea {
            id: pbMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pb.press()
        }

        FocusRing { gap: 0 }
    }

    // Un curseur fin : il suit la souris pendant le glisser ; la molette
    // règle par pas.
    component LevelSlider: Item {
        id: sl
        // 0–1.
        property real value: 0
        property real minimum: 0
        property color fill: Theme.accentColor
        property real dragValue: -1
        readonly property bool dragging: dragValue >= 0
        readonly property real shown: dragging ? dragValue : Math.max(0, Math.min(1, value))
        signal moved(real v)
        signal stepped(int dir)

        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            var k = event.key;
            if (k === Qt.Key_Right || k === Qt.Key_Up)
                sl.stepped(1);
            else if (k === Qt.Key_Left || k === Qt.Key_Down)
                sl.stepped(-1);
            else if (k === Qt.Key_Home || k === Qt.Key_End)
                sl.moved(k === Qt.Key_Home ? sl.minimum : 1);
            else
                return;
            event.accepted = true;
        }

        Layout.fillWidth: true
        Layout.minimumWidth: 44
        Layout.preferredWidth: 130
        Layout.maximumWidth: 130
        Layout.alignment: Qt.AlignVCenter
        implicitHeight: 16

        Rectangle {
            id: slTrack
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 4
            radius: 2
            color: Qt.alpha(Theme.textPrimary, 0.12)
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(slTrack.height, slTrack.width * sl.shown)
            height: slTrack.height
            radius: slTrack.radius
            color: sl.fill
            Behavior on width { enabled: !sl.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            Behavior on color { ColorAnimation { duration: 180 } }
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: sl.shown * (sl.width - width)
            Behavior on x { enabled: !sl.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            width: 10
            height: 10
            radius: 5
            color: Theme.textPrimary
            // Visible au survol, pendant le glisser et au clavier seulement :
            // au repos, la barre seule suffit.
            opacity: slMa.containsMouse || sl.dragging || sl.activeFocus ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            scale: slMa.pressed ? 1.2 : 1
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
        MouseArea {
            id: slMa
            anchors.fill: parent
            anchors.topMargin: -10
            anchors.bottomMargin: -10
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.PointingHandCursor
            function follow(mx) {
                sl.dragValue = Math.max(sl.minimum, Math.min(1, (mx - 5) / Math.max(1, sl.width - 10)));
                sl.moved(sl.dragValue);
            }
            onPressed: (mouse) => follow(mouse.x)
            onPositionChanged: (mouse) => { if (pressed) follow(mouse.x); }
            onReleased: {
                sl.moved(sl.dragValue);
                sl.dragValue = -1;
            }
        }
        WheelHandler {
            onWheel: (event) => sl.stepped(event.angleDelta.y > 0 ? 1 : -1)
        }
        FocusRing { anchors.leftMargin: -6; anchors.rightMargin: -6 }
    }

    component Percent: Text {
        Layout.preferredWidth: 34
        Layout.alignment: Qt.AlignVCenter
        horizontalAlignment: Text.AlignRight
        font.family: top.bar.uiFont
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
        color: Theme.textSecondary
    }

    // ── Le Bluetooth ─────────────────────────────────────────────
    // Un menu déplié sous son bouton (widgets/BluetoothMenu.qml) ; un clic
    // à côté, ou la capsule qui se referme, le replie.
    property bool btOpen: false
    readonly property bool btPowered: Bluetooth.defaultAdapter !== null && Bluetooth.defaultAdapter.enabled // qmllint disable unresolved-type
    readonly property bool btConnected: top.btPowered
                                        && Bluetooth.defaultAdapter.devices.values.some(d => d.connected) // qmllint disable unresolved-type
    onVisibleChanged: if (!top.visible) top.btOpen = false

    MouseArea {
        visible: top.btOpen
        x: -2000
        y: top.height
        width: top.width + 4000
        height: 4000
        onClicked: top.btOpen = false
    }

    // ── La barre ─────────────────────────────────────────────────
    RowLayout {
        anchors.fill: parent
        spacing: 8

        // L'alimentation.
        Pill {
            Layout.preferredWidth: powerRow.width + 8

            Row {
                id: powerRow
                anchors.centerIn: parent
                spacing: 0

                PowerButton { icon: "lock.svg"; command: ["loginctl", "lock-session"]; closeFirst: true }
                PowerButton { icon: "suspend.svg"; command: ["systemctl", "suspend"]; closeFirst: true }
                PowerButton { icon: "logout.svg"; command: ["hyprctl", "dispatch", "hl.dsp.exit()"] }
                PowerButton { icon: "reboot.svg"; command: ["systemctl", "reboot"] }
                PowerButton { icon: "power.svg"; command: ["systemctl", "poweroff"] }
            }
        }

        Item { Layout.fillWidth: true }

        // Les niveaux : la luminosité (s'il y a un rétroéclairage), le volume.
        Pill {
            Layout.fillWidth: true
            Layout.preferredWidth: levels.implicitWidth + 16
            Layout.maximumWidth: levels.implicitWidth + 16
            Layout.minimumWidth: 200

            RowLayout {
                id: levels
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 12
                spacing: 6

                IconButton {
                    visible: Brightness.present
                    icon: "brightness.svg"
                    // Un clic : pleine luminosité, ou la moitié si on y est.
                    onClicked: Brightness.set(Brightness.level > 0.95 ? 0.5 : 1)
                }
                LevelSlider {
                    id: brightSlider
                    visible: Brightness.present
                    value: Brightness.level
                    minimum: 0.05
                    onMoved: (v) => Brightness.set(v)
                    onStepped: (dir) => Brightness.set(Brightness.level + dir * 0.05)
                }
                Percent {
                    visible: Brightness.present
                    text: Math.round(brightSlider.shown * 100) + " %"
                }

                // Le séparateur.
                Rectangle {
                    visible: Brightness.present
                    Layout.leftMargin: 6
                    Layout.rightMargin: 2
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    color: Qt.alpha(Theme.textPrimary, 0.12)
                }

                IconButton {
                    icon: Audio.muted ? "volume-mute.svg" : "volume.svg"
                    alertColor: Audio.muted ? Theme.colorDanger : "transparent"
                    onClicked: Audio.toggleMute()
                }
                LevelSlider {
                    id: volSlider
                    value: Audio.level
                    fill: Audio.muted ? Theme.textDim : Theme.accentColor
                    onMoved: (v) => Audio.set(v)
                    onStepped: (dir) => dir > 0 ? Audio.up() : Audio.down()
                }
                Percent {
                    text: Audio.muted ? I18n.tr("volume.muted") : I18n.tr("common.percent", { n: Math.round(volSlider.shown * 100) })
                    color: Audio.muted ? Theme.textDim : Theme.textSecondary
                }
            }
        }

        // Le Bluetooth et la capture.
        Pill {
            Layout.preferredWidth: toolsRow.width + 8

            Row {
                id: toolsRow
                anchors.centerIn: parent
                spacing: 0

                // Teinté quand un appareil est connecté, éteint avec
                // l'adaptateur ; absent sans adaptateur.
                IconButton {
                    id: btButton
                    visible: Bluetooth.defaultAdapter !== null // qmllint disable unresolved-type
                    icon: "bluetooth.svg"
                    tint: top.btConnected ? Theme.accentColor
                        : top.btPowered ? Theme.iconColor : Theme.textDim
                    onClicked: top.btOpen = !top.btOpen
                }
                IconButton {
                    icon: "screenshot.svg"
                    onClicked: (button) => top.screenshot(button === Qt.RightButton ? "screen" : "area")
                }
            }

            // Le menu, sous le bouton, aligné sur son bord droit.
            BluetoothMenu {
                id: btMenu
                visible: top.btOpen
                open: top.btOpen
                fontFamily: top.bar.uiFont
                anchors.top: parent.bottom
                anchors.topMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: toolsRow.width - btButton.x - btButton.width
                Keys.onEscapePressed: top.btOpen = false
            }
        }

        // La batterie, tout à droite comme sur un téléphone ; absente sur
        // une machine sans batterie.
        Pill {
            visible: Battery.present
            Layout.preferredWidth: batteryIcon.width + 22

            BatteryIcon {
                id: batteryIcon
                anchors.centerIn: parent
            }
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

        spacing: 3

        // L'éclair, le temps de la charge.
        Canvas {
            id: bolt
            anchors.verticalCenter: parent.verticalCenter
            visible: bat.charging
            width: 7
            height: 11
            property color tint: bat.tone
            onTintChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.fillStyle = bolt.tint;
                ctx.beginPath();
                ctx.moveTo(4.4, 0);
                ctx.lineTo(0, 6.3);
                ctx.lineTo(3.1, 6.3);
                ctx.lineTo(2.4, 11);
                ctx.lineTo(7, 4.5);
                ctx.lineTo(3.9, 4.5);
                ctx.closePath();
                ctx.fill();
            }
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
                font.family: top.bar.uiFont
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
