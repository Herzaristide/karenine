pragma Singleton
import QtQuick

// La géométrie du tableau noir (panels/Blackboard.qml) : de quoi alléger un
// trait à main levée et savoir ce que touche le chiffon. Pur calcul, sans
// rien du système : tests/tst_chalk.qml le vérifie hors de Quickshell.
QtObject {
    id: chalk

    // Une fraction écrite court : quatre décimales suffisent à un écran 8K.
    function fraction(v) {
        return Math.round(Math.max(0, Math.min(1, v)) * 10000) / 10000;
    }

    // Ramer–Douglas–Peucker : les points d'un trait à `eps` près, en pixels.
    // Un trait à main levée en garde une poignée par courbe au lieu d'un
    // par mouvement de souris.
    function simplify(points, eps) {
        if (points.length < 3)
            return points.slice();
        var keep = new Array(points.length).fill(false);
        keep[0] = keep[points.length - 1] = true;
        var stack = [[0, points.length - 1]];
        while (stack.length > 0) {
            var span = stack.pop();
            var a = points[span[0]], b = points[span[1]];
            var far = -1, farDist = eps;
            for (var i = span[0] + 1; i < span[1]; i++) {
                var d = chalk.segmentDistance(points[i], a, b);
                if (d > farDist) {
                    far = i;
                    farDist = d;
                }
            }
            if (far >= 0) {
                keep[far] = true;
                stack.push([span[0], far], [far, span[1]]);
            }
        }
        return points.filter((p, i) => keep[i]);
    }

    // La distance d'un point au segment [a, b].
    function segmentDistance(p, a, b) {
        var dx = b[0] - a[0], dy = b[1] - a[1];
        var len2 = dx * dx + dy * dy;
        var t = len2 === 0 ? 0 : ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
        t = Math.max(0, Math.min(1, t));
        var x = a[0] + t * dx - p[0], y = a[1] + t * dy - p[1];
        return Math.sqrt(x * x + y * y);
    }

    // Les ids des traits que touche un cercle de rayon `r` (pixels) centré
    // en `p`, sur un tableau de `w`×`h`.
    function strokesNear(strokes, p, r, w, h) {
        var hit = [];
        for (var i = 0; i < strokes.length; i++) {
            var s = strokes[i];
            var pts = s.points || [];
            var reach = r + (s.width || 3) / 2;
            for (var j = 0; j < pts.length; j++) {
                var a = [pts[j][0] * w, pts[j][1] * h];
                var b = j + 1 < pts.length ? [pts[j + 1][0] * w, pts[j + 1][1] * h] : a;
                if (chalk.segmentDistance(p, a, b) <= reach) {
                    hit.push(s.id);
                    break;
                }
            }
        }
        return hit;
    }
}
