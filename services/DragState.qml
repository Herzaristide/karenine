pragma Singleton
import QtQuick

// Un glisser en cours (depuis l'explorateur) sort forcément le curseur de la
// barre, ce qui la fermerait — et détruirait la tuile source au milieu du
// geste. Ce drapeau suspend la fermeture le temps du glisser.
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
