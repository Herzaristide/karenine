pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

// La petite barre verticale au milieu du bord droit, collée à l'écran : la
// luminosité et le volume. Cachée la plupart du temps, elle glisse du bord
// quand l'un des deux change (touches du clavier, anna, pavucontrol…) ou
// quand la souris approche du bord droit, au milieu, et repart un instant
// après.
//
//          ╭─────┃         Pendant un enregistrement (le micro ou l'écran,
//          │  ☀  ┃         services/Recorder.qml), elle reste là, réduite à
//          │  ┃  ┃         l'enregistrement en cours : son icône rouge qui
//          │  ●  ┃         bat, le temps écoulé, et ■ pour l'arrêter.
//          │ 80% ┃
//          │ ─── ┃                   ╭─────┃
//          │  🔊 ┃                   │  ⏺  ┃
//          │  ┃  ┃                   │ 1:05┃
//          │  ●  ┃                   │  ■  ┃
//          │ 64% ┃                   ╰─────┃
//          ╰─────┃ bord
//
// Cachée, la fenêtre ne garde qu'un fil de quelques pixels contre le bord
// droit : c'est lui qui sent la souris arriver, sans presque rien prendre
// aux fenêtres.
PanelWindow { // qmllint disable uncreatable-type
    id: island

    readonly property string uiFont: "Inter"
    // La largeur visible de la barre ; elle dépasse en plus du bord de son
    // arrondi, pour que seuls les coins de gauche soient ronds.
    readonly property int pillW: 50
    readonly property int sliderH: 120
    // Le fil qui guette la souris : sa hauteur, au milieu du bord, et son
    // épaisseur.
    readonly property int hotH: 480
    readonly property int hotT: 8

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-levels"
    // Rien à taper : jamais le clavier.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Ancrée à droite seulement : la surface se centre sur la hauteur.
    anchors { right: true }
    exclusiveZone: 0
    implicitWidth: island.pillW + 40
    implicitHeight: Math.max(island.hotH, 2 * island.sliderH + 260)
    color: "transparent"

    mask: Region { // qmllint disable unqualified
        Region { item: island.shown ? zone : null }
        Region { item: island.shown ? null : hotStrip }
    }

    // ── Quand se montrer ─────────────────────────────────────────
    readonly property bool recording: Recorder.audioOn || Recorder.screenOn
    // Les curseurs : la souris dessus (ou qui vient de partir), un niveau
    // qui vient de changer, un glisser en cours.
    readonly property bool levelsWanted: island.hoverHold || flash.running
                                         || brightSlider.dragging || volSlider.dragging
    readonly property bool shown: island.levelsWanted || island.recording
    // Seulement l'enregistrement : la barre réduite.
    readonly property bool compact: island.recording && !island.levelsWanted

    // Au démarrage, les niveaux arrivent (−1 → la valeur lue, PipeWire qui
    // se renseigne) : ce n'est pas un changement à montrer.
    property bool armed: false
    Timer {
        interval: 2500
        running: true
        onTriggered: island.armed = true
    }

    Timer {
        id: flash
        interval: 1800
    }

    function bump() {
        if (island.armed)
            flash.restart();
    }

    Connections {
        target: Brightness
        function onLevelChanged() { island.bump(); }
    }
    Connections {
        target: Audio
        function onLevelChanged() { island.bump(); }
        function onMutedChanged() { island.bump(); }
    }

    // La souris survole le fil ou la barre ; elle a un peu de temps pour
    // revenir avant que la barre ne reparte.
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

    // De 0 (cachée, derrière le bord droit) à 1 (là).
    property real reveal: island.shown ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: island.shown ? 320 : 220
            easing.type: island.shown ? Easing.OutQuint : Easing.InCubic
        }
    }

    Item {
        id: root
        anchors.fill: parent

        HoverHandler { id: hover }

        // Le fil qui guette la souris, collé au bord droit.
        Item {
            id: hotStrip
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: island.hotT
            height: island.hotH
        }

        // La barre et un peu de marge autour : la zone qui reçoit la souris
        // une fois la barre là, pour ne pas la perdre au moindre écart.
        Item {
            id: zone
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: island.pillW + 24
            height: Math.min(parent.height, pill.height + 32)
        }

        Rectangle {
            id: pill
            x: parent.width - island.pillW + (island.pillW + 4) * (1 - island.reveal)
            anchors.verticalCenter: parent.verticalCenter
            opacity: island.reveal
            visible: island.reveal > 0
            width: island.pillW + Theme.radius
            height: column.implicitHeight + 20
            radius: Theme.radius
            color: Theme.bgDeep
            border.width: 1
            border.color: island.recording ? Qt.alpha(Theme.colorDanger, 0.45) : Theme.dividerColor
            Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            Behavior on border.color { ColorAnimation { duration: 200 } }
            clip: true

            ColumnLayout {
                id: column
                x: 0
                width: island.pillW
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                // ── La luminosité ──
                IconButton {
                    visible: !island.compact && Brightness.present
                    icon: "brightness.svg"
                    // Un clic : pleine luminosité, ou la moitié si on y est.
                    onClicked: Brightness.set(Brightness.level > 0.95 ? 0.5 : 1)
                }
                LevelSlider {
                    id: brightSlider
                    visible: !island.compact && Brightness.present
                    value: Brightness.level
                    minimum: 0.05
                    onMoved: (v) => Brightness.set(v)
                    onStepped: (dir) => Brightness.set(Brightness.level + dir * 0.05)
                }
                Percent {
                    visible: !island.compact && Brightness.present
                    text: I18n.tr("common.percent", { n: Math.round(brightSlider.shown * 100) })
                }
                Separator { visible: !island.compact && Brightness.present }

                // ── Le volume ──
                IconButton {
                    visible: !island.compact
                    icon: Audio.muted ? "volume-mute.svg" : "volume.svg"
                    alertColor: Audio.muted ? Theme.colorDanger : "transparent"
                    onClicked: Audio.toggleMute()
                }
                LevelSlider {
                    id: volSlider
                    visible: !island.compact
                    value: Audio.level
                    fill: Audio.muted ? Theme.textDim : Theme.accentColor
                    onMoved: (v) => Audio.set(v)
                    onStepped: (dir) => dir > 0 ? Audio.up() : Audio.down()
                }
                Percent {
                    visible: !island.compact
                    text: Audio.muted ? I18n.tr("volume.muted") : I18n.tr("common.percent", { n: Math.round(volSlider.shown * 100) })
                    color: Audio.muted ? Theme.textDim : Theme.textSecondary
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
            }
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    component Separator: Rectangle {
        Layout.topMargin: 2
        Layout.bottomMargin: 2
        Layout.preferredWidth: 18
        Layout.preferredHeight: 1
        Layout.alignment: Qt.AlignHCenter
        color: Qt.alpha(Theme.textPrimary, 0.12)
    }

    // Un bouton rond, sans fond au repos : le survol le révèle.
    component IconButton: Rectangle {
        id: ib
        property string icon
        // Signale un état (muet…) : teinté en permanence.
        property color alertColor: "transparent"
        readonly property bool alerted: ib.alertColor.a > 0
        signal clicked()

        Layout.alignment: Qt.AlignHCenter
        implicitWidth: 30
        implicitHeight: 30
        radius: Theme.radiusSmall
        color: ib.alerted ? Qt.alpha(ib.alertColor, 0.18)
                          : ibMa.containsMouse ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        scale: ibMa.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        NixIcon {
            anchors.centerIn: parent
            iconSize: 17
            source: "../assets/icons/" + ib.icon
            color: ib.alerted ? ib.alertColor : Theme.iconColor
            opacity: ib.alerted || ibMa.containsMouse ? 1 : 0.8
        }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ib.clicked()
        }
    }

    // Un curseur vertical et fin, qui se remplit par le bas : il suit la
    // souris pendant le glisser ; la molette règle par pas.
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

        Layout.preferredHeight: island.sliderH
        Layout.alignment: Qt.AlignHCenter
        implicitWidth: 16

        Rectangle {
            id: slTrack
            anchors.horizontalCenter: parent.horizontalCenter
            width: 4
            height: parent.height
            radius: 2
            color: Qt.alpha(Theme.textPrimary, 0.12)
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: slTrack.bottom
            width: slTrack.width
            height: Math.max(slTrack.width, slTrack.height * sl.shown)
            radius: slTrack.radius
            color: sl.fill
            Behavior on height { enabled: !sl.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            Behavior on color { ColorAnimation { duration: 180 } }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: (1 - sl.shown) * (sl.height - height)
            Behavior on y { enabled: !sl.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            width: 10
            height: 10
            radius: 5
            color: Theme.textPrimary
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
            anchors.leftMargin: -10
            anchors.rightMargin: -10
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.PointingHandCursor
            function follow(my) {
                sl.dragValue = Math.max(sl.minimum, Math.min(1, 1 - (my - 5) / Math.max(1, sl.height - 10)));
                sl.moved(sl.dragValue);
            }
            onPressed: (mouse) => follow(mouse.y)
            onPositionChanged: (mouse) => { if (pressed) follow(mouse.y); }
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
        Layout.alignment: Qt.AlignHCenter
        horizontalAlignment: Text.AlignHCenter
        font.family: island.uiFont
        font.pixelSize: 10
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
        color: Theme.textSecondary
    }

    // Un enregistrement en cours : son icône rouge qui bat, le temps
    // écoulé, et ■ pour l'arrêter.
    component RecordingTag: ColumnLayout {
        id: tag
        property string kind
        property string icon
        property var track: null

        Layout.alignment: Qt.AlignHCenter
        spacing: 4

        NixIcon {
            Layout.alignment: Qt.AlignHCenter
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
            Layout.alignment: Qt.AlignHCenter
            text: Recorder.elapsed(tag.track)
            font.family: island.uiFont
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: Theme.colorDanger
        }
        IconButton {
            icon: "stop.svg"
            onClicked: Recorder.stop(tag.kind)
        }
    }
}
