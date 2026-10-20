pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// S'enregistrer et se réécouter : la colonne de gauche du panneau Musique
// (MusicPanel), et l'état que le lecteur du milieu (TakeView) affiche. anna
// tient l'enregistrement (services/Recorder.qml, anna/src/recorder.rs) : il
// continue quand l'onglet se ferme, et s'arrête d'ici, par son raccourci ou
// par `anna record stop`. Deux sources : le micro seul, ou le micro avec ce
// que joue l'ordinateur (jouer par-dessus un morceau). Chaque prise va dans
// le dossier Musique, en FLAC ; les huit dernières se rejouent ici.
//
//   (●)(▶)(🎤)          enregistrer, jouer, la source
//   16:59        2:13   les prises, la plus récente en haut ;
//   16:40        1:05   un clic choisit celle que le lecteur montre
//   hier 21:12   3:20
//
// À l'arrêt d'un enregistrement, la nouvelle prise arrive en tête, choisie,
// prête à être écoutée. anna joue les prises (Recorder.play) ; une pause
// garde la position ici, et la lecture reprend de là. On efface une prise
// depuis les fichiers.
Item {
    id: recPanel

    implicitWidth: 150

    readonly property bool on: Recorder.audioOn
    // La source du prochain enregistrement : "mic" ou "mix".
    property string mode: "mic"

    // La prise choisie : son chemin, et ses crêtes une fois lues.
    property string selected: ""
    property var peaks: []
    readonly property var take: {
        var t = Recorder.takes;
        for (var i = 0; i < t.length; i++)
            if (t[i].path === recPanel.selected)
                return t[i];
        return null;
    }

    // La prise choisie reste choisie tant qu'elle existe ; sinon, la plus
    // récente.
    function keepSelection() {
        if (recPanel.take === null)
            recPanel.selected = Recorder.takes.length > 0 ? Recorder.takes[0].path : "";
    }
    // À l'ouverture : les prises telles que le dossier les tient (une prise
    // effacée entre-temps disparaît).
    Component.onCompleted: {
        recPanel.keepSelection();
        Recorder.refresh();
    }
    Connections {
        target: Recorder
        function onTakesChanged() { recPanel.keepSelection(); }
        // Une prise qui vient de finir : c'est elle qu'on veut entendre.
        function onLastChanged() {
            if (Recorder.last !== "")
                recPanel.selected = Recorder.last;
        }
        // La lecture s'arrête : en pause, la position reste ; à la fin de la
        // prise, elle revient au début.
        function onPlayingChanged() {
            if (Recorder.playing === null) {
                if (!recPanel.pausing)
                    recPanel.pausedAt = 0;
                recPanel.pausing = false;
            }
        }
    }

    onSelectedChanged: {
        recPanel.peaks = [];
        recPanel.pausedAt = 0;
        if (Recorder.playing)
            Recorder.pause();
        var path = recPanel.selected;
        if (path !== "")
            Recorder.peaks(path, (p) => {
                if (recPanel.selected === path)
                    recPanel.peaks = p;
            });
    }

    // ── La lecture ──
    // Ce qu'anna joue est la prise choisie.
    readonly property bool playing: Recorder.playing !== null && Recorder.playing.path === recPanel.selected
    readonly property real duration: recPanel.take ? recPanel.take.duration : 0
    // Où reprendre, en secondes, après une pause ou un clic sur l'onde.
    property real pausedAt: 0
    property bool pausing: false
    // L'heure, finement, pendant la lecture : la tête avance en douceur.
    property double nowMs: Date.now()
    Timer {
        interval: 50
        repeat: true
        running: recPanel.playing
        triggeredOnStart: true
        onTriggered: recPanel.nowMs = Date.now()
    }
    // En secondes dans la prise.
    readonly property real position: recPanel.playing
        ? Math.min(recPanel.duration, Recorder.playing.from + Math.max(0, recPanel.nowMs - Recorder.playing.since) / 1000)
        : recPanel.pausedAt
    readonly property real progress: recPanel.duration > 0 ? recPanel.position / recPanel.duration : 0

    function toggle() {
        if (recPanel.playing) {
            recPanel.pausedAt = recPanel.position;
            recPanel.pausing = true;
            Recorder.pause();
        } else if (recPanel.take) {
            // Arrivé au bout : on repart du début.
            Recorder.play(recPanel.selected, recPanel.pausedAt < recPanel.duration - 0.1 ? recPanel.pausedAt : 0);
        }
    }

    // Va à `fraction` de la prise, et joue.
    function seek(fraction) {
        if (!recPanel.take)
            return;
        recPanel.pausedAt = fraction * recPanel.duration;
        Recorder.play(recPanel.selected, recPanel.pausedAt);
    }

    // « 16:59 », « hier 21:12 », « 18/10 09:30 » : depuis `at`
    // (20261020_165927).
    function when(at) {
        var m = /^(\d{4})(\d\d)(\d\d)_(\d\d)(\d\d)/.exec(at || "");
        if (!m)
            return at || "";
        var d = new Date(+m[1], +m[2] - 1, +m[3]);
        var today = new Date();
        today.setHours(0, 0, 0, 0);
        var days = Math.round((today - d) / 86400000);
        var hm = m[4] + ":" + m[5];
        if (days === 0)
            return hm;
        if (days === 1)
            return I18n.tr("record.yesterday", { time: hm });
        return m[3] + "/" + m[2] + " " + hm;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // ── Enregistrer, jouer, la source ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            // Enregistrer, arrêter : le voyant bat pendant l'enregistrement.
            GlassButton {
                id: recBtn
                implicitWidth: 32
                implicitHeight: 32
                danger: true
                enabled: Recorder.available
                icon: Qt.resolvedUrl("../assets/icons/" + (recPanel.on ? "stop.svg" : "record.svg"))
                onClicked: recPanel.on ? Recorder.stop("audio") : Recorder.toggleAudio(recPanel.mode)
                SequentialAnimation on opacity {
                    running: recPanel.on
                    loops: Animation.Infinite
                    onStopped: recBtn.opacity = 1
                    NumberAnimation { to: 0.55; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                }
            }
            GlassButton {
                implicitWidth: 32
                implicitHeight: 32
                enabled: !recPanel.on && recPanel.take !== null && Recorder.available
                opacity: enabled ? 1 : 0.45
                accent: recPanel.playing
                icon: Qt.resolvedUrl("../assets/icons/" + (recPanel.playing ? "pause.svg" : "play.svg"))
                onClicked: recPanel.toggle()
            }

            Item { Layout.fillWidth: true }

            // La source : le micro seul, ou avec l'ordinateur (teintée).
            GlassButton {
                implicitWidth: 32
                implicitHeight: 32
                enabled: !recPanel.on
                accent: (recPanel.on && Recorder.audio ? Recorder.audio.mode : recPanel.mode) === "mix"
                icon: Qt.resolvedUrl("../assets/icons/" + (accent ? "computer.svg" : "mic.svg"))
                onClicked: recPanel.mode = recPanel.mode === "mix" ? "mic" : "mix"
            }
        }

        // ── Les prises ──
        ListView {
            id: takeList
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            enabled: !recPanel.on
            opacity: recPanel.on ? 0.45 : 1
            Behavior on opacity { NumberAnimation { duration: 180 } }
            model: Recorder.takes

            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property bool current: row.modelData.path === recPanel.selected

                width: takeList.width
                height: 26
                radius: Theme.radiusSmall
                color: row.current ? Qt.alpha(Theme.accentColor, rowMa.containsMouse ? 0.26 : 0.18)
                                   : rowMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.06) : "transparent"
                Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: recPanel.when(row.modelData.at)
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.weight: row.current ? Font.DemiBold : Font.Medium
                    font.features: { "tnum": 1 }
                    color: row.current ? Theme.textPrimary : Theme.textSecondary
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: Recorder.clock(row.modelData.duration)
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: row.current ? Theme.textPrimary : Theme.textDim
                }
                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: recPanel.selected = row.modelData.path
                }
            }

            // Aucune prise encore.
            Text {
                visible: Recorder.takes.length === 0
                width: takeList.width
                topPadding: 4
                leftPadding: 4
                text: I18n.tr("record.empty")
                wrapMode: Text.WordWrap
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textDim
            }
        }
    }
}
