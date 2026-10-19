import QtQuick
import QtTest
import "pure"  // monté par tests/run.sh

// Le drapeau qui suspend la fermeture du dock pendant un glisser
// (services/DragState.qml).
TestCase {
    name: "DragState"

    function test_begin_then_end() {
        verify(!DragState.active);
        DragState.begin("/home/u/photo.png");
        verify(DragState.active);
        compare(DragState.path, "/home/u/photo.png");
        DragState.end();
        verify(!DragState.active);
        compare(DragState.path, "");
    }
}
