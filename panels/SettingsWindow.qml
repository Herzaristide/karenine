import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

pragma ComponentBehavior: Bound

PanelWindow { // qmllint disable uncreatable-type
    id: win

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-settings"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    color: "transparent"

    // ── Entry / exit animation state ─────────────────────────────
    property bool _shown: false

    Timer {
        id: entryTimer
        interval: 16   // one frame delay so initial frame renders before animating
        onTriggered: win._shown = true
    }

    Timer {
        id: closeTimer
        interval: 210  // matches animation duration
        onTriggered: Theme.settingsOpen = false
    }

    // Trigger entry animation whenever the surface becomes visible
    Component.onCompleted: entryTimer.start()
    onVisibleChanged: {
        if (visible) {
            win._shown = false
            entryTimer.start()
        } else {
            win._shown = false
        }
    }

    function _close() {
        win._shown = false
        closeTimer.start()
    }

    // ── Dim backdrop ──────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.6)
        opacity: win._shown ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        MouseArea {
            anchors.fill: parent
            onClicked: win._close()
        }
    }

    // ── Centered card ─────────────────────────────────────────────
    Rectangle {
        id: card
        anchors.centerIn: parent
        width:  Math.min(500, win.width  - 80)
        height: Math.min(700, win.height - 80)
        z: 1
        radius: 12
        color:  Theme.bgElevated
        border.color: Theme.accentDark
        border.width: 1
        clip: true

        scale:   win._shown ? 1.0 : 0.92
        opacity: win._shown ? 1.0 : 0.0
        Behavior on scale   { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 200 } }

        // Prevent backdrop clicks leaking through the card
        MouseArea { anchors.fill: parent }

        // ── Title bar ────────────────────────────────────────────
        Rectangle {
            id: titleBar
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 40
            color: Theme.bgDeep
            topLeftRadius:  12
            topRightRadius: 12

            RowLayout {
                anchors { fill: parent; leftMargin: 14; rightMargin: 10 }
                spacing: 8

                Text {
                    text: "⚙  PARAMÈTRES"
                    font.family:  "JetBrains Mono"
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: Theme.accentColor
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: "[×]"
                    font.family:  "JetBrains Mono"
                    font.pixelSize: 13
                    color: closeMa.containsMouse ? Theme.colorDanger : Theme.textSecondary
                    Behavior on color { ColorAnimation { duration: 100 } }

                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win._close()
                    }
                }
            }
        }

        // Divider under title bar
        Rectangle {
            anchors { top: titleBar.bottom; left: parent.left; right: parent.right }
            height: 1
            color: Theme.accentDark
        }

        // ── Settings content ──────────────────────────────────────
        Settings {
            anchors {
                top: titleBar.bottom
                topMargin: 1
                left: parent.left; right: parent.right; bottom: parent.bottom
                leftMargin: 2; rightMargin: 2; bottomMargin: 2
            }
            showInternalHeader: false
        }
    }
}
