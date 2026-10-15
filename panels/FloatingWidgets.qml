pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

// Les widgets flottants (cf. services/Widgets.qml) : ce qui vivait dans les
// panneaux latéraux et les popups de la barre, en cartes qu'on place où l'on
// veut au-dessus des fenêtres. anna les ouvre (outil `widget` du pilote).
//
// Une seule surface plein écran porte toutes les cartes : les déplacer ne
// demande rien au compositeur, et le masque ne rend cliquables que les cartes
// ouvertes — le reste de l'écran laisse passer les clics vers les fenêtres.
PanelWindow { // qmllint disable uncreatable-type
    id: layer

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-widgets"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    color: "transparent"
    visible: Object.keys(Widgets.opened).length > 0 || stats.visible || music.visible
             || metronome.visible || sound.visible || camera.visible

    // La carte touchée en dernier passe devant les autres.
    property int topZ: 1
    function raise(card) {
        layer.topZ++;
        card.z = layer.topZ;
    }

    mask: Region { // qmllint disable unqualified
        Region { item: stats.open ? stats : null }
        Region { item: music.open ? music : null }
        Region { item: metronome.open ? metronome : null }
        Region { item: sound.open ? sound : null }
        Region { item: camera.open ? camera : null }
    }

    WidgetCard {
        id: stats
        name: "stats"
        areaWidth: layer.screen ? layer.screen.width : 1280
        areaHeight: layer.screen ? layer.screen.height : 720
        contentWidth: 300
        contentHeight: 540
        onRaised: layer.raise(stats)
        content: Component { HardwareStats {} }
    }

    WidgetCard {
        id: music
        name: "musique"
        areaWidth: layer.screen ? layer.screen.width : 1280
        areaHeight: layer.screen ? layer.screen.height : 720
        contentWidth: 320
        contentHeight: 520
        onRaised: layer.raise(music)
        content: Component { MusicPlayerWidget {} }
    }

    // Métronome et accordeur, comme dans l'ancien panneau « Pitch ».
    WidgetCard {
        id: metronome
        name: "metronome"
        areaWidth: layer.screen ? layer.screen.width : 1280
        areaHeight: layer.screen ? layer.screen.height : 720
        contentWidth: 300
        contentHeight: 560
        onRaised: layer.raise(metronome)
        content: Component {
            ColumnLayout {
                spacing: 8
                Metronome {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    active: true
                }
                Tuner {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 180
                    active: true
                }
            }
        }
    }

    WidgetCard {
        id: sound
        name: "son"
        areaWidth: layer.screen ? layer.screen.width : 1280
        areaHeight: layer.screen ? layer.screen.height : 720
        contentWidth: 320
        onRaised: layer.raise(sound)
        content: Component { QuickControls {} }
    }

    WidgetCard {
        id: camera
        name: "camera"
        areaWidth: layer.screen ? layer.screen.width : 1280
        areaHeight: layer.screen ? layer.screen.height : 720
        contentWidth: 300
        onRaised: layer.raise(camera)
        content: Component { GestureControls {} }
    }
}
