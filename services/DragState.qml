pragma Singleton
import QtQuick

// Un glisser en cours sort forcément le curseur du dock, ce qui déclencherait
// sa fermeture — et détruirait la carte source au milieu du geste. Ce drapeau
// suspend la fermeture le temps du glisser.
QtObject {
    id: root

    property bool active: false
    property string path: ""

    function begin(p) {
        root.path = p;
        root.active = true;
    }

    function end() {
        root.active = false;
        root.path = "";
    }
}
