pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Io
import "../services"

// La barre du haut des widgets, la même quel que soit l'onglet. Trois
// groupes posés sur le verre, chacun dans sa pilule : l'alimentation à
// gauche, les niveaux (luminosité, volume) au milieu, la capture à droite.
//
//   ╭ 🔒 ☾ ⇥ ↻ ⏻ ╮     ╭ ☀ ━━●── 80 %  │  🔊 ━━━●─ 64 % ╮  ╭ ⌗ ╮
//
// Verrouiller et mettre en veille partent d'un clic. Se déconnecter,
// redémarrer et éteindre demandent une confirmation : le premier clic
// élargit le bouton en rouge (« Éteindre ? ») pendant 3 s, le second agit.
// Les curseurs se partagent la place qui reste : la barre peut être étroite.
Item {
    id: top

    // La barre de conversation : sa teinte, sa police.
    required property var bar
    // Affichée : volume et luminosité se rafraîchissent.
    property bool live: false

    implicitHeight: 38

    // Les boutons dans une pilule : un peu plus petits qu'elle.
    readonly property int btnSize: top.height - 8

    // ── L'alimentation ───────────────────────────────────────────
    Process {
        id: powerProc
    }

    function run(argv, closeFirst) {
        // Verrouiller ou dormir : la barre ne doit pas rester ouverte derrière.
        if (closeFirst)
            Widgets.hubOpen = false;
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
        Widgets.hubOpen = false;
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

    // ── La luminosité ────────────────────────────────────────────
    // Le rétroéclairage (brightnessctl) : l'écran du portable. Le réglage
    // disparaît là où il n'y en a pas.
    // 0–1 ; -1 : pas de rétroéclairage.
    property real brightness: -1
    readonly property bool hasBacklight: top.brightness >= 0

    Process {
        id: brightProc
        command: ["brightnessctl", "-m", "-c", "backlight"]
        stdout: StdioCollector {
            // « intel_backlight,backlight,96000,100%,96000 »
            onStreamFinished: {
                var f = text.trim().split("\n")[0].split(",");
                top.brightness = f.length >= 5 && parseInt(f[4]) > 0
                                 ? parseInt(f[2]) / parseInt(f[4]) : -1;
            }
        }
    }

    Process {
        id: setBrightProc
    }

    function setBrightness(v) {
        // Jamais tout à fait noir : 5 % au minimum.
        v = Math.max(0.05, Math.min(1, v));
        top.brightness = v;
        if (setBrightProc.running)
            return;
        setBrightProc.command = ["brightnessctl", "-c", "backlight", "set", Math.round(v * 100) + "%"];
        setBrightProc.running = true;
    }

    // Volume (service Audio, wpctl) et luminosité relus toutes les 2 s tant
    // que c'est affiché.
    Timer {
        interval: 2000
        repeat: true
        running: top.live
        triggeredOnStart: true
        onTriggered: {
            Audio.refresh();
            if (!brightProc.running && !brightSlider.dragging)
                brightProc.running = true;
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    // Une pilule de verre qui porte un groupe.
    component Pill: Rectangle {
        Layout.preferredHeight: top.height
        radius: height / 2
        color: Qt.alpha(Theme.textPrimary, 0.05)
        border.width: 1
        border.color: Qt.alpha(Theme.textPrimary, 0.08)
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
        readonly property bool hovered: ibMa.containsMouse
        signal clicked(int button)

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: top.btnSize
        implicitHeight: top.btnSize
        radius: height / 2
        color: ib.alerted ? Qt.alpha(ib.alertColor, 0.18)
                          : Qt.alpha(Theme.textPrimary, ib.hovered ? 0.1 : 0)
        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        scale: ibMa.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Glyph {
            anchors.centerIn: parent
            icon: ib.icon
            tint: ib.alerted ? ib.alertColor : ib.tint
            strength: ib.alerted || ib.hovered ? 1 : 0.8
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

    // Un bouton d'alimentation : à confirmer s'il a un `confirmLabel`.
    component PowerButton: Rectangle {
        id: pb
        property string icon
        property string confirmLabel: ""
        property var command: []
        property bool closeFirst: false
        // En attente du second clic.
        property bool armed: false

        readonly property bool hovered: pbMa.containsMouse
        readonly property color danger: Theme.colorDanger

        anchors.verticalCenter: parent.verticalCenter
        height: top.btnSize
        width: pb.armed ? confirmText.implicitWidth + top.btnSize + 10 : top.btnSize
        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
        radius: height / 2
        color: pb.armed ? Qt.alpha(pb.danger, 0.22)
                        : Qt.alpha(Theme.textPrimary, pb.hovered ? 0.1 : 0)
        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
        scale: pbMa.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        clip: true

        Glyph {
            id: pbGlyph
            x: (top.btnSize - width) / 2
            anchors.verticalCenter: parent.verticalCenter
            icon: pb.icon
            tint: pb.armed ? pb.danger : Theme.iconColor
            strength: pb.armed || pb.hovered ? 1 : 0.8
        }

        Text {
            id: confirmText
            anchors.left: pbGlyph.right
            anchors.leftMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: pb.confirmLabel
            font.family: top.bar.uiFont
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: pb.danger
            opacity: pb.armed ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        Timer {
            id: disarm
            interval: 3000
            onTriggered: pb.armed = false
        }

        MouseArea {
            id: pbMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (pb.confirmLabel !== "" && !pb.armed) {
                    pb.armed = true;
                    disarm.restart();
                    return;
                }
                pb.armed = false;
                disarm.stop();
                top.run(pb.command, pb.closeFirst);
            }
        }
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
            color: "#ffffff"
            // Visible au survol et pendant le glisser seulement : au repos,
            // la barre seule suffit.
            opacity: slMa.containsMouse || sl.dragging ? 1 : 0
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
                PowerButton { icon: "logout.svg"; confirmLabel: "Se déconnecter ?"; command: ["hyprctl", "dispatch", "hl.dsp.exit()"] }
                PowerButton { icon: "reboot.svg"; confirmLabel: "Redémarrer ?"; command: ["systemctl", "reboot"] }
                PowerButton { icon: "power.svg"; confirmLabel: "Éteindre ?"; command: ["systemctl", "poweroff"] }
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
                    visible: top.hasBacklight
                    icon: "brightness.svg"
                    // Un clic : pleine luminosité, ou la moitié si on y est.
                    onClicked: top.setBrightness(top.brightness > 0.95 ? 0.5 : 1)
                }
                LevelSlider {
                    id: brightSlider
                    visible: top.hasBacklight
                    value: top.brightness
                    minimum: 0.05
                    onMoved: (v) => top.setBrightness(v)
                    onStepped: (dir) => top.setBrightness(top.brightness + dir * 0.05)
                }
                Percent {
                    visible: top.hasBacklight
                    text: Math.round(brightSlider.shown * 100) + " %"
                }

                // Le séparateur.
                Rectangle {
                    visible: top.hasBacklight
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
                    text: Audio.muted ? "muet" : Math.round(volSlider.shown * 100) + " %"
                    color: Audio.muted ? Theme.textDim : Theme.textSecondary
                }
            }
        }

        // La capture.
        Pill {
            Layout.preferredWidth: top.height

            IconButton {
                anchors.centerIn: parent
                icon: "screenshot.svg"
                onClicked: (button) => top.screenshot(button === Qt.RightButton ? "screen" : "area")
            }
        }
    }
}
