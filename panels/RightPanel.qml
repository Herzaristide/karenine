import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

pragma ComponentBehavior: Bound

PanelWindow {
    id: panel

    property bool panelOpen: false
    property real panelWidth: 280
    readonly property real minWidth: 180
    readonly property real maxWidth: 600

    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "quickshell-rightpanel"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors {
        top: true
        right: true
        bottom: true
    }

    implicitWidth: panelOpen ? panelWidth : 0
    Behavior on implicitWidth { enabled: false }
    exclusiveZone: implicitWidth

    color: "transparent"

    margins {
        right: 8
        bottom: 52  // laisse la place à la BottomBar horizontale
    }

    // ── Resize handle on left edge ───────────────────────────────
    MouseArea {
        id: resizeHandle
        width: 8
        anchors.left: parent.left
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
            const delta = startGlobalX - currentGlobalX;
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
        anchors.leftMargin: 12
        anchors.rightMargin: 0
        visible: panel.panelOpen
        spacing: 0

        // Always-visible controls: volume + screenshot
        QuickControls {
            Layout.fillWidth: true
        }

        HardwareStats {
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }
}
