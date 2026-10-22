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

// La barre du haut des widgets, la même quel que soit l'onglet. Trois
// groupes posés sur le fond, chacun sur son aplat : l'alimentation à
// gauche, puis le Bluetooth, la capture et l'enregistrement de l'écran, et
// la batterie à droite. Le Bluetooth déplie la liste des appareils
// (widgets/BluetoothMenu.qml). La luminosité et le volume ont leur propre
// barre, en haut de l'écran (panels/LevelsIsland.qml).
//
//   ╭ 🔒 ☾ ⇥ ↻ ⏻ ╮                              ╭ ᛒ ⌗ ● ╮  ╭ [87]▸ ╮
//
// Chaque bouton d'alimentation agit dès le premier clic, sans confirmation.
//
// Au clavier : Tab passe d'un bouton à l'autre, Entrée ou Espace l'actionne.
// Maj+Entrée sur la capture ou l'enregistrement prend l'écran entier, comme
// le clic droit.
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

    // ── L'enregistrement de l'écran ──────────────────────────────
    // anna le tient (services/Recorder.qml) : clic, une région ; clic droit,
    // l'écran qui a le focus ; avec le son de l'ordinateur. Comme pour la
    // capture, la barre disparaît d'abord pour ne pas être filmée. Pendant
    // l'enregistrement, le bouton rougit et compte ; un clic l'arrête.
    function screenRecord(region) {
        if (Recorder.screenOn) {
            Recorder.stop("screen");
            return;
        }
        top.bar.dismiss();
        recTimer.region = region;
        recTimer.restart();
    }

    Timer {
        id: recTimer
        property string region: "area"
        interval: 350
        onTriggered: Recorder.toggleScreen(recTimer.region)
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

        // Le Bluetooth, la capture et l'enregistrement de l'écran.
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
                IconButton {
                    visible: Recorder.available
                    icon: "screen-record.svg"
                    alertColor: Recorder.screenOn ? Theme.colorDanger : "transparent"
                    onClicked: (button) => top.screenRecord(button === Qt.RightButton ? "screen" : "area")
                }
                // Le temps écoulé, tant que l'écran est filmé.
                Text {
                    visible: Recorder.screenOn
                    anchors.verticalCenter: parent.verticalCenter
                    leftPadding: 2
                    rightPadding: 4
                    text: Recorder.elapsed(Recorder.screen)
                    color: Theme.colorDanger
                    font.family: top.bar.uiFont
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
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
