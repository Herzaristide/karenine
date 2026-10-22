pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Une forme d'onde en barres fines, symétriques autour du milieu : celle
// d'une prise (anna en donne les crêtes, Recorder.peaks), ou celle d'un
// enregistrement qui se fait (Recorder.live).
//
//   une prise :  ▂▅▇█▇▅▃▂▁▂▃▆█▇▆|▅▃▂▁▁▂▄▆▇▆▄▃▂   la part lue teintée ; un clic
//                                ↑ la tête de lecture    ou un glisser y va
//   en direct :           ▁▂▅▇█▇▅▃▂▁▂▃▆█▇▆▅   les dernières secondes, qui
//                                          ↑  arrivent par la droite
//
// La hauteur suit la racine carrée de la crête, plus proche de ce que
// l'oreille entend ; une prise est ramenée à sa crête la plus haute, pour
// qu'une prise douce se lise aussi bien qu'une forte.
Item {
    id: wave

    // Crêtes 0–1, la plus ancienne d'abord.
    property var peaks: []
    // En direct : les crêtes arrivent par la droite, sans mise à l'échelle.
    property bool live: false
    // 0–1, la part déjà lue ; la tête de lecture se montre au-delà de 0.
    property real progress: 0
    property color playedColor: Theme.accentColor
    property color restColor: Qt.alpha(Theme.textPrimary, 0.26)
    signal seek(real fraction)

    readonly property int barW: 2
    readonly property int step: 4
    readonly property int count: Math.max(0, Math.floor((wave.width + wave.step - wave.barW) / wave.step))

    // La hauteur de chaque barre, 0–1.
    readonly property var bars: {
        var n = wave.count, p = wave.peaks || [], out = [];
        if (n === 0)
            return out;
        if (wave.live) {
            for (var i = 0; i < n; i++) {
                var j = p.length - n + i;
                out.push(j >= 0 ? Math.sqrt(p[j]) : 0);
            }
            return out;
        }
        if (p.length === 0)
            return out;
        var top = 0.02;
        for (var k = 0; k < p.length; k++)
            top = Math.max(top, p[k]);
        for (var b = 0; b < n; b++) {
            // La crête la plus haute de la part de cette barre.
            var from = Math.floor(b * p.length / n);
            var to = Math.max(from + 1, Math.floor((b + 1) * p.length / n));
            var v = 0;
            for (var m = from; m < to && m < p.length; m++)
                v = Math.max(v, p[m]);
            out.push(Math.sqrt(v / top));
        }
        return out;
    }

    Repeater {
        model: wave.bars.length

        Rectangle {
            required property int index
            readonly property real level: wave.bars[index] || 0

            x: index * wave.step
            width: wave.barW
            height: Math.max(2, wave.height * level)
            y: (wave.height - height) / 2
            radius: 1
            color: !wave.live && (index + 0.5) / wave.bars.length <= wave.progress
                   ? wave.playedColor : wave.restColor
        }
    }

    // La tête de lecture.
    Rectangle {
        visible: !wave.live && wave.bars.length > 0 && wave.progress > 0
        x: Math.round(wave.progress * (wave.bars.length * wave.step - wave.step + wave.barW)) - 1
        width: 2
        height: wave.height
        radius: 1
        color: Theme.textPrimary
        opacity: 0.85
    }

    MouseArea {
        anchors.fill: parent
        enabled: !wave.live && wave.bars.length > 0
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        preventStealing: true
        function at(x) {
            wave.seek(Math.max(0, Math.min(1, x / Math.max(1, wave.bars.length * wave.step))));
        }
        onPressed: (mouse) => at(mouse.x)
        onPositionChanged: (mouse) => { if (pressed) at(mouse.x); }
    }
}
