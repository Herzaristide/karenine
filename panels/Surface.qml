import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"

// La surface : l'encre du thème sous toutes les fenêtres (la couche
// Background du layer-shell), unie, sans image. La barre du bas et le
// panneau de droite sont de la même encre : entre les fenêtres, autour
// d'elles, sous la barre, c'est une seule matière, et les fenêtres
// arrondies y sont posées.
PanelWindow { // qmllint disable uncreatable-type
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "quickshell-surface"
    WlrLayershell.exclusionMode: ExclusionMode.Ignore

    anchors { // qmllint disable unqualified unresolved-type
        top: true
        bottom: true
        left: true
        right: true
    }
    color: Theme.bgDeep
}
