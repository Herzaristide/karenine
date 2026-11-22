pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "../auth"
import "../services"
import "../widgets"

// Visuel du lockscreen : une seule carte au milieu de l'écran, posée sur
// l'encre dans un halo d'accent à peine visible.
//
//   ╭───────────────────────────────────────────────────────────────────╮
//   │ ❄ MACHINE · 87 %                                                  │
//   │                                                   ╭─ F ─ C ─ G ─╮ │
//   │ 14:32                              Am            Bb      ·      D │
//   │ Samedi 22 novembre                 A · C · E     Eb   A mineur  A │
//   │                                    (Dm)(G)(C)     ╰ C# ─ F# ─ B ╯ │
//   │ aristide · session verrouillée                                    │
//   │ [ ••••••••                                  → ]                   │
//   │ ───────────────────────────────────────────────────────────────── │
//   │ ▣ Titre du morceau          ━━━━━━━●──────────      ⏮  (⏯)  ⏭     │
//   │   Artiste                   1:12           3:40                   │
//   │ ───────────────────────────────────────────────────────────────── │
//   │ CPU      │ MÉMOIRE  │ GPU      │ MÉTRONOME   │ ACCORDEUR          │
//   │ 8 %      │ 27 %     │ 5 %      │ 120 bpm     │ A4  +3 ¢           │
//   │ ~~~~~    │ ~~~~~    │ ~~~~~    │ ● ○ ○ ○     │ la = 440           │
//   ╰───────────────────────────────────────────────────────────────────╯
//
// Pas de cases dans la carte : la typo, des filets, et la roue des accords
// (widgets/Harmony, celle du lecteur du shell) pour pièce maîtresse. Le pied
// tient en une ligne de relevés : la machine (LockStats), le métronome
// (services/Tempo — un clic le lance) et l'accordeur (widgets/Tuner, sans
// son visuel — un clic ouvre le micro).
//
// La moitié droite, la lecture et le pied ne sont montés que sur l'écran
// primaire, et seulement s'ils tiennent ; sinon la carte se réduit à
// l'heure et à la saisie.
//
// Purement présentation : l'authentification vit dans lock.qml, cette surface
// se contente d'émettre `submitted(password)` et d'afficher l'état que le
// parent lui repasse.
Item {
    id: surface

    // Pilotés par lock.qml
    required property string message
    required property bool messageIsError
    required property bool busy
    required property string userName

    // La carte complète : sur l'écran primaire seulement — WlSessionLock
    // instancie une surface par moniteur, et chacune ouvrirait sinon ses
    // propres abonnements au socket anna.
    required property bool showWidgets

    // Vidéo de fond (le fond d'écran de la session), vide pour un fond uni.
    property string wallpaper: ""

    signal submitted(password: string)
    // Activité après la mise en veille : lock.qml en profite pour retenter la
    // reconnaissance faciale.
    signal woke()

    // Rien ne bouge depuis un moment (hypridle éteint l'écran peu après le
    // verrouillage) : la vidéo, l'harmonie et le micro s'arrêtent. Tout
    // repart au moindre mouvement.
    property bool idle: false

    function wake(): void {
        if (surface.idle)
            surface.woke();
        surface.idle = false;
        idleTimer.restart();
    }

    Timer {
        id: idleTimer
        interval: 90 * 1000
        running: true
        onTriggered: surface.idle = true
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onPositionChanged: surface.wake()
    }

    // Vidé par lock.qml après chaque tentative.
    function clearPassword(): void {
        passwordField.clear();
    }

    function focusPassword(): void {
        passwordField.focusInput();
    }

    onMessageIsErrorChanged: {
        if (surface.messageIsError)
            passwordField.shake();
    }

    // ── Mise en page ──────────────────────────────────────────────────────
    readonly property int pad: 32
    readonly property int margin: 40
    readonly property int fullW: 920
    readonly property bool full: surface.showWidgets
        && surface.width >= surface.fullW + 2 * surface.margin
        && surface.height >= 660

    // ── Ce qui joue ───────────────────────────────────────────────────────
    // Même choix que le lecteur du shell : le premier en lecture, sinon le
    // premier venu.
    readonly property var player: {
        const list = Mpris.players ? Mpris.players.values : [];
        if (!list || list.length === 0)
            return null;
        for (let i = 0; i < list.length; ++i) {
            if (list[i].playbackState === MprisPlaybackState.Playing)
                return list[i];
        }
        return list[0];
    }
    readonly property bool hasPlayer: surface.player !== null && surface.player !== undefined
    readonly property bool playing: surface.hasPlayer && surface.player.playbackState === MprisPlaybackState.Playing

    // MPRIS ne pousse pas la position : on la redemande chaque seconde.
    Timer {
        interval: 1000
        repeat: true
        running: surface.full && surface.playing && !surface.idle
        onTriggered: surface.player.positionChanged()
    }

    function fmtTime(s: real): string {
        if (!(s > 0))
            return "0:00";
        const m = Math.floor(s / 60);
        const r = Math.floor(s % 60);
        return m + ":" + (r < 10 ? "0" : "") + r;
    }

    // ── Les sources du pied ───────────────────────────────────────────────
    LockStats {
        id: stats
        active: surface.full && !surface.idle
    }

    // L'accordeur sans son visuel : seul son moteur sert (le socket d'anna,
    // la note et l'écart). Le micro ne s'ouvre que sur un clic, et se ferme
    // avec la mise en veille de l'écran.
    property bool listening: false
    onIdleChanged: if (surface.idle) surface.listening = false

    Tuner {
        id: tuner
        visible: false
        active: surface.full && surface.listening && !surface.idle
    }

    // Tempo ouvre sa session audio d'avance quand on peut le lancer.
    Binding {
        target: Tempo
        property: "shown"
        value: true
        when: surface.full
    }

    // Nom de la machine pour l'en-tête.
    FileView {
        id: hostFile
        path: "/etc/hostname"
        printErrors: false
    }
    readonly property string hostName: hostFile.loaded ? hostFile.text().trim() : ""

    // ── Le fond ───────────────────────────────────────────────────────────
    AuthBackdrop {
        anchors.fill: parent
        videoSource: surface.wallpaper
        playing: !surface.idle
    }

    // Un halo d'accent sous la carte, comme une lampe posée sur la table.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeWidth: -1
            startX: 0
            startY: 0
            fillGradient: RadialGradient {
                centerX: surface.width / 2
                centerY: surface.height / 2
                centerRadius: Math.max(card.width, card.height) * 0.8
                focalX: surface.width / 2
                focalY: surface.height / 2
                // Faible et court : au-delà, l'écran 8 bits dessine des
                // anneaux au lieu d'un fondu.
                GradientStop { position: 0.0; color: Qt.alpha(Theme.accentColor, 0.055) }
                GradientStop { position: 0.6; color: Qt.alpha(Theme.accentColor, 0.02) }
                GradientStop { position: 1.0; color: "transparent" }
            }
            PathLine { x: surface.width; y: 0 }
            PathLine { x: surface.width; y: surface.height }
            PathLine { x: 0; y: surface.height }
            PathLine { x: 0; y: 0 }
        }
    }

    // ── La carte ──────────────────────────────────────────────────────────
    Rectangle {
        id: card

        anchors.centerIn: parent
        width: surface.full ? surface.fullW : Math.min(440, surface.width - 2 * surface.margin)
        height: content.implicitHeight + 2 * surface.pad
        radius: 28
        color: Theme.bgElevated
        border.width: 1
        border.color: Qt.alpha(Theme.textPrimary, 0.06)

        // Entrée : fondu + légère montée.
        opacity: 0
        transform: Translate { id: rise; y: 22 }
        Component.onCompleted: entrance.start()

        ParallelAnimation {
            id: entrance
            NumberAnimation { target: card; property: "opacity"; to: 1; duration: 360; easing.type: Easing.OutCubic }
            NumberAnimation { target: rise; property: "y"; to: 0; duration: 520; easing.type: Easing.OutQuint }
        }

        ColumnLayout {
            id: content

            anchors.fill: parent
            anchors.margins: surface.pad
            spacing: 0

            // ── Le haut : l'heure et la saisie, l'harmonie à droite ───────
            RowLayout {
                Layout.fillWidth: true
                spacing: 44

                ColumnLayout {
                    Layout.fillWidth: !surface.full
                    Layout.preferredWidth: surface.full ? 360 : -1
                    Layout.alignment: Qt.AlignTop
                    spacing: 0

                    // Machine et batterie.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 7

                        NixIcon {
                            source: "../assets/nixos.svg"
                            iconSize: 12
                            color: Theme.accentColor
                        }

                        Caps {
                            text: surface.hostName
                        }

                        Caps {
                            visible: Battery.present
                            text: "·  " + Battery.percent + " %"
                            color: Battery.percent <= 15 && Battery.status !== "Charging" ? Theme.colorDanger : Theme.textDim
                        }

                        NixIcon {
                            visible: Battery.present && Battery.status === "Charging"
                            source: "../assets/icons/bolt.svg"
                            iconSize: 10
                            color: Theme.textDim
                        }

                        Item { Layout.fillWidth: true }
                    }

                    // L'heure, les deux points à l'accent.
                    Row {
                        id: clockRow

                        Layout.topMargin: 14
                        Layout.leftMargin: -6

                        readonly property date now: clock.date

                        SystemClock {
                            id: clock
                            precision: SystemClock.Minutes
                        }

                        Digits { text: Qt.formatDateTime(clockRow.now, "HH") }
                        Digits {
                            text: ":"
                            color: Theme.accentColor
                            leftPadding: 2
                            rightPadding: 6
                        }
                        Digits { text: Qt.formatDateTime(clockRow.now, "mm") }
                    }

                    Text {
                        Layout.topMargin: -4
                        text: {
                            const d = I18n.locale.toString(clockRow.now, I18n.tr("date.long"));
                            return d.charAt(0).toUpperCase() + d.slice(1);
                        }
                        color: Theme.textSecondary
                        font.family: "Inter"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                    }

                    // Qui, et la saisie.
                    Text {
                        Layout.topMargin: 34
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        textFormat: Text.StyledText
                        text: "<b>" + surface.userName + "</b>"
                              + "<font color=\"" + Theme.textDim + "\">  ·  " + I18n.tr("lock.subtitle") + "</font>"
                        color: Theme.textPrimary
                        font.family: "Inter"
                        font.pixelSize: 13
                    }

                    PasswordField {
                        id: passwordField

                        Layout.topMargin: 10
                        Layout.fillWidth: true
                        busy: surface.busy
                        error: surface.messageIsError

                        onTextChanged: surface.wake()
                        onSubmitted: (secret) => surface.submitted(secret)
                    }

                    Text {
                        Layout.topMargin: 8
                        Layout.fillWidth: true
                        Layout.preferredHeight: 14
                        text: surface.message
                        elide: Text.ElideRight
                        color: surface.messageIsError ? Theme.colorDanger : Theme.textDim
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: surface.messageIsError ? Font.Medium : Font.Normal
                    }
                }

                // La roue des accords de ce qui joue, en grand.
                Harmony {
                    visible: surface.full
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: implicitHeight
                    maxWheel: 236
                    active: surface.full && surface.playing && !surface.idle
                }
            }

            // ── En lecture ────────────────────────────────────────────────
            Rule { visible: surface.full }

            RowLayout {
                visible: surface.full
                Layout.fillWidth: true
                spacing: 16

                // La pochette.
                Rectangle {
                    Layout.preferredWidth: 46
                    Layout.preferredHeight: 46
                    radius: 10
                    color: Theme.bgDeep
                    clip: true

                    NixIcon {
                        anchors.centerIn: parent
                        visible: art.status !== Image.Ready
                        iconSize: 18
                        source: "../assets/icons/music-note.svg"
                        color: Theme.textDim
                    }

                    Image {
                        id: art
                        anchors.fill: parent
                        source: surface.hasPlayer ? (surface.player.trackArtUrl || "") : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                    }
                }

                ColumnLayout {
                    Layout.preferredWidth: 220
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        Layout.fillWidth: true
                        text: surface.hasPlayer ? (surface.player.trackTitle || "—") : I18n.tr("player.nothingPlaying")
                        color: surface.hasPlayer ? Theme.textPrimary : Theme.textDim
                        font.family: "Inter"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: surface.hasPlayer ? (surface.player.trackArtist || "") : ""
                        color: Theme.textSecondary
                        font.family: "Inter"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                }

                // La progression : un filet, rempli à l'accent.
                ColumnLayout {
                    Layout.preferredWidth: 280
                    Layout.fillWidth: true
                    spacing: 6
                    opacity: surface.hasPlayer ? 1 : 0.35

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 3
                        radius: 1.5
                        color: Qt.alpha(Theme.textPrimary, 0.1)

                        Rectangle {
                            readonly property real ratio: surface.hasPlayer && surface.player.length > 0
                                ? Math.max(0, Math.min(1, surface.player.position / surface.player.length)) : 0
                            width: parent.width * ratio
                            height: parent.height
                            radius: parent.radius
                            color: Theme.accentColor
                            Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        Small { text: surface.hasPlayer ? surface.fmtTime(surface.player.position) : "0:00" }
                        Item { Layout.fillWidth: true }
                        Small { text: surface.hasPlayer ? surface.fmtTime(surface.player.length) : "0:00" }
                    }
                }

                Row {
                    spacing: 4
                    Layout.leftMargin: 8

                    Transport {
                        icon: "prev"
                        enabled: surface.hasPlayer && surface.player.canGoPrevious
                        onActivated: surface.player.previous()
                    }
                    Transport {
                        icon: surface.playing ? "pause" : "play"
                        main: true
                        enabled: surface.hasPlayer
                        onActivated: surface.player.togglePlaying()
                    }
                    Transport {
                        icon: "next"
                        enabled: surface.hasPlayer && surface.player.canGoNext
                        onActivated: surface.player.next()
                    }
                }
            }

            // ── Le pied : une ligne de relevés ────────────────────────────
            Rule { visible: surface.full }

            RowLayout {
                visible: surface.full
                Layout.fillWidth: true
                spacing: 0

                Readout {
                    label: I18n.tr("stats.cpu")
                    value: stats.cpu >= 0 ? String(stats.cpu) : "—"
                    unit: stats.cpu >= 0 ? "%" : ""
                    note: stats.cpuTemp
                    history: stats.cpuHistory
                    tone: Theme.accentColor
                }
                Divider {}
                Readout {
                    label: I18n.tr("stats.memory")
                    value: stats.ram >= 0 ? String(stats.ram) : "—"
                    unit: stats.ram >= 0 ? "%" : ""
                    note: stats.ramTotal > 0 ? stats.formatGiB(stats.ramUsed) + " / " + stats.formatGiB(stats.ramTotal) : ""
                    history: stats.ramHistory
                    tone: Theme.colorRam
                }
                Divider { visible: stats.gpuPresent }
                Readout {
                    visible: stats.gpuPresent
                    label: I18n.tr("stats.gpu")
                    value: stats.gpu >= 0 ? String(stats.gpu) : "—"
                    unit: stats.gpu >= 0 ? "%" : ""
                    note: stats.gpuTemp
                    history: stats.gpuHistory
                    tone: Theme.colorGpu
                }
                Divider {}

                // Le métronome : le tempo, les temps de la mesure ; un clic
                // le lance ou l'arrête.
                Readout {
                    label: I18n.tr("metronome.title")
                    value: String(Tempo.bpm)
                    unit: "bpm"
                    tone: Tempo.running ? Theme.accentColor : Theme.textDim
                    lit: Tempo.running
                    clickable: true
                    onActivated: Tempo.toggle()

                    Row {
                        spacing: 5
                        Layout.topMargin: 6
                        Layout.preferredHeight: 14

                        Repeater {
                            model: Math.min(8, Tempo.beatsPerBar)

                            Rectangle {
                                id: beat
                                required property int index
                                readonly property bool on: Tempo.running && Tempo.beatIndex === beat.index
                                y: 4
                                width: 6
                                height: 6
                                radius: 3
                                color: beat.on ? (beat.index === 0 ? Theme.colorSuccess : Theme.accentColor) : Qt.alpha(Theme.textPrimary, 0.14)
                                scale: beat.on ? 1.35 : 1
                                Behavior on scale { NumberAnimation { duration: 90 } }
                            }
                        }
                    }
                }
                Divider {}

                // L'accordeur : la note entendue et l'écart ; un clic ouvre
                // ou ferme le micro.
                Readout {
                    label: I18n.tr("tuner.title")
                    value: surface.listening && tuner.freq > 0 ? tuner.noteName + tuner.octave : "—"
                    unit: surface.listening && tuner.freq > 0 ? (tuner.cents > 0 ? "+" : "") + tuner.cents + " ¢" : ""
                    tone: tuner.inTune ? Theme.colorSuccess : Theme.colorWarning
                    lit: surface.listening
                    clickable: true
                    onActivated: surface.listening = !surface.listening

                    RowLayout {
                        Layout.topMargin: 6
                        Layout.preferredHeight: 14
                        spacing: 6

                        NixIcon {
                            iconSize: 11
                            source: "../assets/icons/mic.svg"
                            color: surface.listening ? Theme.accentColor : Theme.textDim
                        }
                        Small {
                            text: "A4 " + Math.round(Tuning.refFreq) + " Hz"
                        }
                    }
                }
            }
        }
    }

    // ── Les pièces ────────────────────────────────────────────────────────

    // Les chiffres de l'heure.
    component Digits: Text {
        color: Theme.textPrimary
        font.family: "Inter Display"
        font.pixelSize: 112
        font.weight: Font.Light
        font.letterSpacing: -4
        font.features: { "tnum": 1 }
    }

    // Petites capitales espacées, comme les titres de section du shell
    // (widgets/SectionTitle).
    component Caps: Text {
        font.family: "Inter"
        font.pixelSize: 10
        font.weight: Font.DemiBold
        font.letterSpacing: 1.3
        font.capitalization: Font.AllUppercase
        font.features: { "tnum": 1 }
        color: Theme.textDim
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    component Small: Text {
        font.family: "Inter"
        font.pixelSize: 11
        font.features: { "tnum": 1 }
        color: Theme.textDim
    }

    // Un filet sur toute la largeur, qui sépare les étages de la carte.
    component Rule: Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        Layout.topMargin: 24
        Layout.bottomMargin: 20
        color: Theme.dividerColor
    }

    // Un filet vertical entre deux relevés.
    component Divider: Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        Layout.topMargin: 4
        Layout.bottomMargin: 4
        Layout.leftMargin: 18
        Layout.rightMargin: 18
        color: Theme.dividerColor
    }

    // Un relevé : l'intitulé, la valeur en grand et son unité à la couleur
    // de la série, puis une courbe ou ce qu'on y met.
    component Readout: ColumnLayout {
        id: readout

        property string label
        property string value
        property string unit
        property string note
        property var history: []
        property color tone: Theme.accentColor
        // Allumé (le métronome bat, le micro écoute) : l'intitulé à l'accent.
        property bool lit: false
        property bool clickable: false
        signal activated()

        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignTop
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Caps {
                Layout.fillWidth: true
                text: readout.label
                color: readout.lit ? Theme.accentColor : (hover.hovered && readout.clickable ? Theme.textSecondary : Theme.textDim)
                Behavior on color { ColorAnimation { duration: 140 } }
            }
            Small {
                visible: text.length > 0
                text: readout.note
                font.pixelSize: 10
            }
        }

        Row {
            Text {
                id: big
                text: readout.value
                color: Theme.textPrimary
                font.family: "Inter Display"
                font.pixelSize: 30
                font.weight: Font.Light
                font.letterSpacing: -1
                font.features: { "tnum": 1 }
            }
            Text {
                anchors.baseline: big.baseline
                leftPadding: 4
                text: readout.unit
                color: readout.tone
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                font.features: { "tnum": 1 }
            }
        }

        MiniGraph {
            visible: readout.history.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: 18
            Layout.topMargin: 2
            values: readout.history
            lineColor: readout.tone
            fillOpacity: 0.08
        }

        HoverHandler {
            id: hover
            enabled: readout.clickable
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            enabled: readout.clickable
            onTapped: readout.activated()
        }
    }

    // Un bouton de transport ; `main` pour lecture/pause, en pastille.
    component Transport: Rectangle {
        id: button

        required property string icon
        property bool main: false
        signal activated()

        y: (40 - button.height) / 2
        width: button.main ? 40 : 32
        height: width
        radius: width / 2
        color: button.main
            ? Qt.alpha(Theme.accentColor, mouse.containsMouse && button.enabled ? 0.28 : 0.16)
            : (mouse.containsMouse && button.enabled ? Theme.hoverOverlay : "transparent")
        opacity: button.enabled ? 1 : 0.35
        Behavior on color { ColorAnimation { duration: 120 } }

        NixIcon {
            anchors.centerIn: parent
            iconSize: button.main ? 16 : 14
            source: "../assets/icons/" + button.icon + ".svg"
            color: button.main ? Theme.accentColor : Theme.textSecondary
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (button.enabled) button.activated()
        }
    }
}
