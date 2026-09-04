pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

// The QuickControls block — volume, audio devices, screenshot, battery and the
// accent picker — as a popup hung off the LeftBar's bottom buttons, instead of
// riding along at the top of every side panel.
PanelWindow { // qmllint disable uncreatable-type
    id: popup

    property bool popupOpen: false
    signal dismissed()

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-controls"
    WlrLayershell.keyboardFocus: popupOpen ? WlrKeyboardFocus.OnDemand
                                           : WlrKeyboardFocus.None

    // Full-screen but click-through-transparent: that is what lets a click
    // anywhere outside the card dismiss it.
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    color: "transparent"
    visible: popupOpen

    MouseArea {
        anchors.fill: parent
        onClicked: popup.dismissed()
    }

    Rectangle {
        id: card
        // The bar's exclusive zone already shifts this surface clear of it,
        // so this is just the gutter — same 8 px the side panels use.
        x: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        width: 320
        height: Math.min(controls.implicitHeight, popup.height - 16)

        color: Theme.bgDeep
        opacity: 1.0
        radius: 12
        border.width: 1
        border.color: Theme.dividerColor

        // Swallow clicks on the card itself so they don't dismiss it.
        MouseArea { anchors.fill: parent }

        QuickControls {
            id: controls
            anchors.fill: parent
        }

        // Rises from the bar as it opens.
        transform: Translate { y: popup.popupOpen ? 0 : 12 }
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
}
