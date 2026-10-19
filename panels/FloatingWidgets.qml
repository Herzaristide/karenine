pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

// Les cartes flottantes (cf. services/Widgets.qml) : ce qui ne vit pas dans
// les widgets de la barre (panels/WidgetHub.qml), qu'on place où l'on veut
// au-dessus des fenêtres. Il n'en reste qu'une, le contrôle gestuel, qu'anna
// ou la FIFO (`camera`) ouvrent.
//
// Une seule surface plein écran porte les cartes : les déplacer ne demande
// rien au compositeur, et le masque ne rend cliquables que les cartes
// ouvertes — le reste de l'écran laisse passer les clics vers les fenêtres.
PanelWindow { // qmllint disable uncreatable-type
    id: layer

    // Overlay : visibles même devant une fenêtre en plein écran.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-widgets"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    color: "transparent"
    visible: camera.open || camera.visible

    mask: Region { // qmllint disable unqualified
        Region { item: camera.open ? camera : null }
    }

    WidgetCard {
        id: camera
        name: "camera"
        areaWidth: layer.screen ? layer.screen.width : 1280
        areaHeight: layer.screen ? layer.screen.height : 720
        contentWidth: 300
        content: Component { GestureControls {} }
    }
}
