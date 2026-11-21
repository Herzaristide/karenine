pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import "../services"

// L'harmonie de ce qui joue — une vidéo, un morceau — pour improviser
// dessus sans jouer faux. Au cœur du lecteur (MusicPlayerWidget), sous le
// disque et le morceau :
//
//                                   ╭─ F ─ C ─ G ─╮
//   A m                           Bb       ·       D      le cycle des
//   A · C · E                    Eb    A          A      quintes : la gamme
//                                 Ab   mineur    E       forme un arc, en
//   ( Dm ) ( G ) ( C )             ╰ C# ─ F# ─ B ╯       haut ; l'accord s'y
//                                                         allume
//
// À gauche l'accord en grand (l'accord à jouer), ses notes, ceux d'avant ;
// à droite la roue, qui pivote vers la tonalité quand elle change, avec
// l'énergie de chaque note en couronne intérieure.
//
// anna écoute la sortie du PC (pas le micro), et seulement tant que la
// connexion est ouverte : `active` suit la lecture.
Item {
    id: root

    property bool active: false

    // ── L'état, tel qu'anna l'envoie (une ligne toutes les ~46 ms) ──────
    // 12 énergies Do..Si, la plus forte à 1.
    property var chroma: [0,0,0,0,0,0,0,0,0,0,0,0]
    // La tonalité : {tonic, minor, flats, scale, confidence}, ou null.
    property var key: null
    // L'écart de l'enregistrement au la 440, en cents.
    property int tuning: 0

    // L'accord affiché : le dernier tenu au moins `hold` ms ({name, root,
    // tones}), gardé quand le son devient flou — `chordLive` dit alors
    // qu'il n'est plus entendu, et il s'estompe au lieu de clignoter.
    property var chord: null
    property bool chordLive: false
    // Les accords d'avant, le plus récent d'abord.
    property var history: []
    readonly property int hold: 120
    readonly property int historyMax: 4

    property var _pending: null

    readonly property bool listening: chromaSock.connected

    readonly property var sharpNames: ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    readonly property var flatNames:  ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    // Écrites comme la tonalité les écrit (B♭ en fa majeur, pas A#).
    readonly property var noteNames: key && key.flats ? flatNames : sharpNames

    function inChord(pc) { return !!chord && chord.tones.indexOf(pc) >= 0; }
    function inScale(pc) { return !!key && key.scale.indexOf(pc) >= 0; }
    // La place d'une note sur le cycle des quintes (Do en 0, Sol en 1…) ;
    // 7 × 7 = 49 ≡ 1 (mod 12) : la même formule va dans les deux sens.
    function fifths(pc) { return (pc * 7) % 12; }

    function clear() {
        root.chroma = [0,0,0,0,0,0,0,0,0,0,0,0];
        root.key = null;
        root.tuning = 0;
        root.chord = null;
        root.chordLive = false;
        root.history = [];
        root._pending = null;
        holdTimer.stop();
    }

    function receive(c) {
        if (!c) {
            root._pending = null;
            holdTimer.stop();
            root.chordLive = false;
            return;
        }
        if (root.chord && c.name === root.chord.name) {
            root._pending = null;
            holdTimer.stop();
            root.chordLive = true;
            return;
        }
        if (!root._pending || root._pending.name !== c.name) {
            root._pending = c;
            holdTimer.restart();
        }
    }

    function commit(c) {
        var prev = root.chord ? root.chord.name : "";
        if (prev && prev !== c.name && root.history[0] !== prev)
            root.history = [prev].concat(root.history).slice(0, root.historyMax);
        root.chord = c;
        root.chordLive = true;
        chordPop.restart();
    }

    Timer {
        id: holdTimer
        interval: root.hold
        onTriggered: if (root._pending) {
            root.commit(root._pending);
            root._pending = null;
        }
    }

    // ── Backend ──────────────────────────────────────────────────────────
    Socket {
        id: chromaSock
        path: Anna.socketPath

        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (Array.isArray(msg.chroma) && msg.chroma.length === 12)
                        root.chroma = msg.chroma.map(function (v) { return typeof v === "number" ? v : 0; });
                    root.key = msg.key || null;
                    root.tuning = msg.tuning || 0;
                    root.receive(msg.chord || null);
                } catch (e) { /* ignore malformed / partial line */ }
            }
        }

        onConnectedChanged: {
            if (connected)
                write('{"cmd":"chroma_watch"}\n');
            else
                root.clear();
        }
    }

    // Connect while active; retry every 2 s if the daemon isn't up yet.
    Timer {
        interval: 2000
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!chromaSock.connected) chromaSock.connected = true
    }

    onActiveChanged: if (!active) chromaSock.connected = false

    // ── La carte ─────────────────────────────────────────────────────────
    // La roue au plus (le lecteur l'agrandit quand la place le permet) ;
    // la hauteur suit la roue, au moins celle qu'il faut à l'accord.
    property real maxWheel: 136
    readonly property real baseHeight: Math.max(120, Math.min(136, width * 0.48))
    implicitHeight: Math.max(120, wheel.size)

    RowLayout {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 14

        // ── L'accord, en grand ───────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: 0
            spacing: 2

            Item { Layout.fillHeight: true }

            Item {
                id: chordBox
                visible: !!root.chord
                Layout.fillWidth: true
                implicitHeight: chordRow.implicitHeight

                readonly property string rootName: root.chord ? root.noteNames[root.chord.root] : ""
                readonly property var rest: root.chord ? root.chord.name.slice(rootName.length).split("/") : ["", ""]

                Row {
                    id: chordRow
                    spacing: 1
                    transformOrigin: Item.Left
                    opacity: !root.chord ? 1 : root.chordLive ? 1 : 0.4
                    Behavior on opacity { NumberAnimation { duration: 260 } }

                    Text {
                        id: rootText
                        text: chordBox.rootName
                        font.family: "Inter"
                        font.pixelSize: 38
                        font.weight: root.chord ? Font.DemiBold : Font.Light
                        font.letterSpacing: -0.5
                        color: root.chord ? Theme.textPrimary : Theme.textDim
                    }
                    // La qualité, à l'accent : m, 7, maj7…
                    Text {
                        visible: !!root.chord && text.length > 0
                        anchors.baseline: rootText.baseline
                        text: chordBox.rest[0] || ""
                        font.family: "Inter"
                        font.pixelSize: 20
                        font.weight: Font.Medium
                        color: Theme.accentColor
                    }
                    // Un renversement : la basse.
                    Text {
                        visible: !!root.chord && chordBox.rest.length > 1
                        anchors.baseline: rootText.baseline
                        leftPadding: 2
                        text: "/" + (chordBox.rest[1] || "")
                        font.family: "Inter"
                        font.pixelSize: 18
                        color: Theme.textSecondary
                    }

                    ParallelAnimation {
                        id: chordPop
                        NumberAnimation { target: chordRow; property: "scale"; from: 0.92; to: 1; duration: 220; easing.type: Easing.OutBack }
                        NumberAnimation { target: rootText; property: "opacity"; from: 0.3; to: 1; duration: 180; easing.type: Easing.OutCubic }
                    }
                }
            }

            // Ses notes ; à défaut, ce que fait la carte.
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: root.chord
                      ? root.chord.tones.map(function (pc) { return root.noteNames[pc]; }).join("  ·  ")
                      : root.listening ? I18n.tr("harmony.listening") : I18n.tr("harmony.idle")
                font.family: "Inter"
                font.pixelSize: root.chord ? 11 : 13
                font.weight: Font.Medium
                font.letterSpacing: root.chord ? 0.4 : 0
                lineHeight: 1.15
                color: root.chord ? Theme.textSecondary : Theme.textDim
            }

            Item { Layout.fillHeight: true }

            // Ceux d'avant : la grille se lit d'un coup d'œil.
            Row {
                Layout.fillWidth: true
                Layout.preferredHeight: 22
                spacing: 6
                clip: true

                Repeater {
                    model: root.history

                    Rectangle {
                        id: pill
                        required property string modelData
                        required property int index
                        width: pillText.implicitWidth + 16
                        height: 22
                        radius: Theme.radiusSmall
                        color: Qt.alpha(Theme.textPrimary, 0.06)
                        opacity: [0.9, 0.65, 0.45, 0.3][pill.index] || 0.3

                        Text {
                            id: pillText
                            anchors.centerIn: parent
                            text: pill.modelData
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            color: Theme.textSecondary
                        }
                    }
                }
            }
        }

        // ── La roue des quintes ──────────────────────────────────────
        Item {
            id: wheel
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            Layout.preferredWidth: size
            Layout.preferredHeight: size

            readonly property real size: Math.min(root.maxWheel, root.width * 0.48)
            readonly property real c: size / 2
            readonly property real ringW: 18
            readonly property real rOut: c - 7
            readonly property real rMid: rOut - ringW / 2
            readonly property real rIn: rOut - ringW
            readonly property real reach: 8   // l'énergie, vers le centre
            readonly property real span: 30
            readonly property real gap: 3.5

            opacity: root.listening ? 1 : 0.45
            Behavior on opacity { NumberAnimation { duration: 320 } }

            // La tonalité en haut : la gamme est un arc de 7 cases sur le
            // cycle, centré sur la 2e de sa majeure (ré pour do majeur et
            // la mineur) — l'arc tombe d'aplomb. La roue tourne au plus court.
            property real turn: 0
            readonly property int center: {
                if (!root.key)
                    return 0;
                var major = root.key.minor ? (root.key.tonic + 3) % 12 : root.key.tonic;
                return (root.fifths(major) + 2) % 12;
            }
            onCenterChanged: {
                var target = -wheel.center * wheel.span;
                var delta = (((target - wheel.turn) % 360) + 540) % 360 - 180;
                wheel.turn += delta;
            }
            Behavior on turn { NumberAnimation { duration: 700; easing.type: Easing.InOutCubic } }

            Repeater {
                model: 12

                Item {
                    id: seg
                    required property int index
                    anchors.fill: parent

                    readonly property int pc: (seg.index * 7) % 12
                    readonly property real angle: wheel.turn + seg.index * wheel.span
                    readonly property real rad: seg.angle * Math.PI / 180
                    readonly property real level: Math.max(0, Math.min(1, root.chroma[seg.pc] || 0))
                    readonly property bool chordTone: root.inChord(seg.pc)
                    readonly property bool scaleTone: root.inScale(seg.pc)
                    readonly property bool tonic: !!root.key && root.key.tonic === seg.pc

                    property color fill: seg.chordTone
                        ? (root.chordLive ? Theme.accentColor : Qt.alpha(Theme.accentColor, 0.5))
                        : seg.scaleTone ? Qt.alpha(Theme.accentColor, 0.2)
                        : Qt.alpha(Theme.textPrimary, 0.06)
                    Behavior on fill { ColorAnimation { duration: 220 } }

                    property color energy: seg.chordTone
                        ? Qt.alpha(Theme.accentColor, 0.5 + seg.level * 0.5)
                        : Qt.alpha(Theme.textPrimary, 0.12 + seg.level * 0.4)
                    Behavior on energy { ColorAnimation { duration: 220 } }

                    // Au plus d'une image d'anna (~46 ms) : glisse entre deux.
                    property real thick: 1.5 + seg.level * wheel.reach
                    Behavior on thick { NumberAnimation { duration: 46 } }

                    Shape {
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer

                        // La case.
                        ShapePath {
                            strokeColor: seg.fill
                            strokeWidth: wheel.ringW
                            fillColor: "transparent"
                            capStyle: ShapePath.FlatCap
                            PathAngleArc {
                                centerX: wheel.c
                                centerY: wheel.c
                                radiusX: wheel.rMid
                                radiusY: wheel.rMid
                                startAngle: seg.angle - 90 - (wheel.span - wheel.gap) / 2
                                sweepAngle: wheel.span - wheel.gap
                            }
                        }
                        // Son énergie, en couronne intérieure : comme le
                        // spectre autour du disque, mais vers le dedans.
                        ShapePath {
                            strokeColor: seg.energy
                            strokeWidth: seg.thick
                            fillColor: "transparent"
                            capStyle: ShapePath.FlatCap
                            PathAngleArc {
                                centerX: wheel.c
                                centerY: wheel.c
                                radiusX: wheel.rIn - 3 - seg.thick / 2
                                radiusY: wheel.rIn - 3 - seg.thick / 2
                                startAngle: seg.angle - 90 - (wheel.span - wheel.gap * 2) / 2
                                sweepAngle: wheel.span - wheel.gap * 2
                            }
                        }
                    }

                    // Le nom, sur sa case, toujours droit.
                    Text {
                        x: wheel.c + wheel.rMid * Math.sin(seg.rad) - width / 2
                        y: wheel.c - wheel.rMid * Math.cos(seg.rad) - height / 2
                        text: root.noteNames[seg.pc]
                        font.family: "Inter"
                        font.pixelSize: 9
                        font.weight: seg.chordTone || seg.tonic ? Font.Bold : Font.Medium
                        color: seg.chordTone ? Theme.selectedTextColor
                             : seg.scaleTone ? Theme.textPrimary
                             : Theme.textDim
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }

                    // La tonique : un point, au bord.
                    Rectangle {
                        width: 4
                        height: 4
                        radius: 2
                        x: wheel.c + (wheel.rOut + 4) * Math.sin(seg.rad) - 2
                        y: wheel.c - (wheel.rOut + 4) * Math.cos(seg.rad) - 2
                        color: Theme.accentColor
                        opacity: seg.tonic ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 220 } }
                    }
                }
            }

            // Au centre, la tonalité.
            Column {
                anchors.centerIn: parent
                spacing: 0

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.key ? root.noteNames[root.key.tonic] : "—"
                    font.family: "Inter"
                    font.pixelSize: 20
                    font.weight: root.key ? Font.DemiBold : Font.Light
                    color: root.key ? Theme.textPrimary : Theme.textDim
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !!root.key
                    text: root.key ? I18n.tr(root.key.minor ? "harmony.minor" : "harmony.major") : ""
                    font.family: "Inter"
                    font.pixelSize: 8
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.0
                    font.capitalization: Font.AllUppercase
                    color: Theme.textDim
                }
            }
        }
    }
}
