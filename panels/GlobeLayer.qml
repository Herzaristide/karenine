import QtQuick
import Quickshell
import Quickshell.Wayland

// La place du géoïde : là où vont les fenêtres. Une surface sous elles
// (couche Bottom, au-dessus de la Surface), ancrée aux quatre bords mais
// sans zone exclusive à ignorer (zone 0, mode Normal) : Hyprland la range
// dans ce que laissent la barre et le panneau, comme une fenêtre, et la
// redimensionne quand le panneau s'ouvre ou se ferme. À l'intérieur, le
// même écart au bord que les fenêtres (gaps_out d'Hyprland, 18).
//
// Elle n'existe que le temps où le géoïde se voit : cachée, elle ne prend
// pas les clics du bureau.
PanelWindow { // qmllint disable uncreatable-type
    id: layer

    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "quickshell-globe"
    WlrLayershell.exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0

    anchors { // qmllint disable unqualified unresolved-type
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"
    visible: globe.shown

    Globe {
        id: globe
        anchors.fill: parent
        anchors.margins: 18
        screen: layer.screen
    }
}
