import QtQuick
import QtTest
import "pure"  // monté par tests/run.sh

// La géométrie du tableau noir (services/Chalk.qml) : ce qu'un trait garde de
// ses points, et ce que touche le chiffon.
TestCase {
    name: "Chalk"

    function test_fraction_is_short_and_inside() {
        compare(Chalk.fraction(0.123456), 0.1235);
        compare(Chalk.fraction(-0.2), 0);
        compare(Chalk.fraction(1.7), 1);
    }

    function test_segment_distance() {
        compare(Chalk.segmentDistance([5, 3], [0, 0], [10, 0]), 3);
        // Au-delà d'un bout : la distance à ce bout.
        compare(Chalk.segmentDistance([13, 4], [0, 0], [10, 0]), 5);
        // Un segment réduit à un point.
        compare(Chalk.segmentDistance([3, 4], [0, 0], [0, 0]), 5);
    }

    function test_a_straight_line_keeps_its_ends() {
        var line = [];
        for (var i = 0; i <= 50; i++)
            line.push([i * 2, i * 0.01]);
        compare(Chalk.simplify(line, 1), [[0, 0], [100, 0.5]]);
    }

    function test_a_corner_is_kept() {
        var pts = [[0, 0], [5, 0.2], [10, 0], [10, 5], [10, 10]];
        compare(Chalk.simplify(pts, 1), [[0, 0], [10, 0], [10, 10]]);
    }

    function test_short_strokes_are_left_alone() {
        compare(Chalk.simplify([[1, 1]], 1), [[1, 1]]);
        compare(Chalk.simplify([[1, 1], [2, 2]], 1), [[1, 1], [2, 2]]);
    }

    function test_the_eraser_finds_what_it_touches() {
        var strokes = [
            { id: "a", width: 4, points: [[0.1, 0.1], [0.5, 0.1]] },   // y = 10 px
            { id: "b", width: 4, points: [[0.1, 0.5], [0.5, 0.5]] },   // y = 50 px
            { id: "c", width: 4, points: [[0.9, 0.9]] }                // un point
        ];
        // Tableau de 100×100 px, chiffon de rayon 5.
        compare(Chalk.strokesNear(strokes, [30, 14], 5, 100, 100), ["a"]);
        compare(Chalk.strokesNear(strokes, [30, 30], 5, 100, 100), []);
        compare(Chalk.strokesNear(strokes, [92, 92], 5, 100, 100), ["c"]);
    }
}
