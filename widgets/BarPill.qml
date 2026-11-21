import QtQuick
import "../services"

// Le socle de chaque bouton de la barre du bas (BarButton, la batterie,
// l'heure, le téléphone, les workspaces) : un même mouvement partout.
//
//  - le survol fait éclore un aplat discret, du centre vers les bords ;
//  - `on` (son volet ouvert, le workspace courant) y pose le fond d'accent,
//    qui s'ouvre avec un léger rebond ;
//  - l'appui tasse le contenu, le lâcher le relâche sur un ressort ;
//  - le clic laisse un éclat bref, qui s'élargit et s'efface.
//
// `rest` garde l'aplat de survol au repos (un workspace occupé). Le contenu
// se met dedans, centré par qui le pose.
Item {
    id: pill

    property bool on: false
    property bool rest: false
    property real radius: Theme.radiusSmall
    property int acceptedButtons: Qt.LeftButton
    property bool interactive: true
    readonly property bool hovered: ma.containsMouse
    readonly property bool pressed: ma.pressed
    default property alias content: holder.data
    signal clicked(int button)

    // ── L'aplat de survol ──
    Rectangle {
        anchors.fill: parent
        radius: pill.radius
        color: Theme.hoverOverlay
        readonly property bool lit: (pill.hovered || pill.rest) && !pill.on
        opacity: lit ? 1 : 0
        scale: lit ? 1 : 0.82
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    }

    // ── Le fond d'accent ──
    Rectangle {
        anchors.fill: parent
        radius: pill.radius
        color: Theme.selectedFill
        opacity: pill.on ? 1 : 0
        scale: pill.on ? 1 : 0.7
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on scale {
            NumberAnimation { duration: 380; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
        }
        Behavior on color { ColorAnimation { duration: 240 } }
    }

    // ── L'onde du clic : l'aplat s'éclaire et s'élargit, puis s'efface ──
    Rectangle {
        id: ripple
        anchors.fill: parent
        radius: pill.radius
        color: Theme.textPrimary
        opacity: 0
        ParallelAnimation {
            id: rippleAnim
            NumberAnimation { target: ripple; property: "scale"; from: 0.6; to: 1; duration: 380; easing.type: Easing.OutCubic }
            NumberAnimation { target: ripple; property: "opacity"; from: 0.12; to: 0; duration: 480; easing.type: Easing.OutQuad }
        }
    }

    // ── Le contenu, tassé à l'appui ──
    Item {
        id: holder
        anchors.fill: parent
        scale: pill.pressed ? 0.9 : 1
        Behavior on scale { SpringAnimation { spring: 5; damping: 0.32; epsilon: 0.002 } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        enabled: pill.interactive
        hoverEnabled: true
        acceptedButtons: pill.acceptedButtons
        cursorShape: Qt.PointingHandCursor
        onPressed: rippleAnim.restart()
        onClicked: (mouse) => pill.clicked(mouse.button)
    }
}
