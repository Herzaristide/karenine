import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"
import "../ai"

pragma ComponentBehavior: Bound

PanelWindow { // qmllint disable uncreatable-type
    id: panel

    property bool panelOpen: false
    property int activeWidget: 0
    property real panelWidth: 280
    readonly property real minWidth: 180
    readonly property real maxWidth: 600

    // Same layer as the LeftBar so the bar, created first, keeps the screen edge.
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-sidepanel"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors {
        top: true
        left: true
        bottom: true
    }

    implicitWidth: panelOpen ? panelWidth : 0
    Behavior on implicitWidth { enabled: false }
    exclusiveZone: implicitWidth

    color: "transparent"

    margins { // qmllint disable unqualified unresolved-type
        left: 8     // la LeftBar réserve déjà ses 44 px (exclusive zone)
        bottom: 0
    }

    // ── Panel surface ────────────────────────────────────────────
    // Deliberately lighter than the LeftBar's slab: the bar is always on
    // screen and anchors the edge, the panel only visits.
    Rectangle {
        anchors.fill: parent
        visible: panel.panelOpen
        color: Theme.bgDeep
        opacity: 0.62

        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // Only the inner edge is drawn — nothing on the bar side.
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Theme.dividerColor
        }
    }

    // ── Resize handle on right edge ──────────────────────────────
    MouseArea {
        id: resizeHandle
        width: 8
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        cursorShape: Qt.SizeHorCursor
        hoverEnabled: true
        preventStealing: true

        property real startGlobalX: 0
        property real startWidth: 0

        onPressed: (mouse) => {
            startGlobalX = mapToGlobal(mouse.x, 0).x;
            startWidth = panel.panelWidth;
        }

        onPositionChanged: (mouse) => {
            if (!pressed) return;
            const currentGlobalX = mapToGlobal(mouse.x, 0).x;
            const delta = currentGlobalX - startGlobalX;
            panel.panelWidth = Math.max(panel.minWidth,
                Math.min(panel.maxWidth, startWidth + delta));
        }

        Rectangle {
            anchors.fill: parent
            color: resizeHandle.containsMouse || resizeHandle.pressed
                   ? Theme.iconColor : "transparent"
            opacity: 0.2
        }
    }

    // ── Main content ─────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        anchors.leftMargin: 0
        anchors.rightMargin: 12
        visible: panel.panelOpen
        spacing: 0

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: panel.activeWidget

            // Les index sont figés par l'IPC (widget:N), donc les entrées
            // retirées laissent un trou plutôt que de tout décaler.
            Item {}  // index 0 : hardware déplacé dans RightPanel
            AIPanel {}
            Item {}  // index 2 : notes retirées
            ColumnLayout {          // index 3 : métronome + accordeur
                spacing: 8
                Metronome {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    active: panel.panelOpen && panel.activeWidget === 3
                }
                Tuner {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 180
                    active: panel.panelOpen && panel.activeWidget === 3
                }
            }
            MusicPlayerWidget {}
            ConsoleWidget {          // index 5
                active: panel.panelOpen && panel.activeWidget === 5
            }
        }
    }
}
