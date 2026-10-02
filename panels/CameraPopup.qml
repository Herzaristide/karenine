pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"

// Webcam gesture control, hung off the TopBar's camera button: an on/off
// switch, the engine's state, and the capture device to use.
PanelWindow { // qmllint disable uncreatable-type
    id: popup

    property bool popupOpen: false
    signal dismissed()

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-camera"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Full-screen but click-through-transparent: a click anywhere outside the
    // card dismisses it (same arrangement as ControlsPopup).
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    color: "transparent"
    visible: popupOpen

    // The device list may have changed (webcam plugged in) since last time.
    onPopupOpenChanged: if (popupOpen) Gesture.refreshCameras()

    MouseArea {
        anchors.fill: parent
        onClicked: popup.dismissed()
    }

    readonly property string stateText: {
        if (!Gesture.available) return "anna sans module gestuel";
        if (Gesture.error !== "") return Gesture.error;
        if (!Gesture.enabled) return "désactivé";
        if (!Gesture.active) return "démarrage…";
        switch (Gesture.mode) {
        case "pointer": return "curseur";
        case "palm":    return "main ouverte";
        case "hand":    return "main détectée";
        default:        return "en attente d'une main";
        }
    }

    Rectangle {
        id: card
        // Under the camera button, just left of the volume one.
        anchors.right: parent.right
        anchors.rightMargin: 48
        anchors.top: parent.top
        anchors.topMargin: 8
        width: 300
        height: content.implicitHeight + 28

        color: Theme.bgDeep
        radius: 12
        border.width: 1
        border.color: Theme.dividerColor

        // Swallow clicks on the card itself so they don't dismiss it.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: content
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 8

            // ── On/off ───────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: "GESTES"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    font.letterSpacing: 1.5
                    color: Theme.accentMuted
                    Layout.fillWidth: true
                }

                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 22
                    radius: 11
                    opacity: Gesture.available ? 1.0 : 0.4
                    color: Gesture.enabled ? Theme.accentColor : Theme.bgElevated
                    border.width: 1
                    border.color: Gesture.enabled ? Theme.accentColor : Theme.dividerColor
                    Behavior on color { ColorAnimation { duration: 200 } }

                    Rectangle {
                        width: 16; height: 16; radius: 8
                        anchors.verticalCenter: parent.verticalCenter
                        x: Gesture.enabled ? 24 : 4
                        color: Theme.iconColor
                        Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: Gesture.available
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Gesture.setEnabled(!Gesture.enabled)
                    }
                }
            }

            Text {
                text: popup.stateText
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Gesture.error !== "" ? Theme.colorDanger : Theme.textDim
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                Layout.topMargin: 4
                Layout.bottomMargin: 4
                color: Theme.dividerColor
            }

            // ── Device ───────────────────────────────────────────
            Text {
                text: "CAMÉRA"
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 1.5
                color: Theme.accentMuted
            }

            Text {
                visible: Gesture.cameras.length === 0
                text: "aucune caméra détectée"
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Theme.textDim
            }

            Repeater {
                model: Gesture.cameras

                delegate: Rectangle {
                    id: camRow

                    required property var modelData
                    readonly property bool selected: Gesture.camera === modelData.path

                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: 8
                    color: selected ? Qt.rgba(Theme.accentColor.r, Theme.accentColor.g, Theme.accentColor.b, 0.14)
                                    : (camMa.containsMouse ? Theme.hoverOverlay : "transparent")
                    border.width: 1
                    border.color: selected ? Theme.accentColor : Theme.dividerColor
                    Behavior on color { ColorAnimation { duration: 120 } }

                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        spacing: 8

                        Text {
                            // "HD Webcam: HD Webcam" → "HD Webcam"
                            text: {
                                var n = camRow.modelData.name || "";
                                var parts = n.split(": ");
                                return parts.length === 2 && parts[0] === parts[1] ? parts[0] : n;
                            }
                            font.family: "JetBrains Mono"
                            font.pixelSize: 11
                            font.weight: camRow.selected ? Font.Bold : Font.Normal
                            color: camRow.selected ? Theme.accentColor : Theme.textPrimary
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Text {
                            text: camRow.modelData.path.replace("/dev/", "")
                            font.family: "JetBrains Mono"
                            font.pixelSize: 10
                            color: Theme.textDim
                        }
                    }

                    MouseArea {
                        id: camMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Gesture.setCamera(camRow.modelData.path)
                    }
                }
            }
        }

        transform: Translate { y: popup.popupOpen ? 0 : -12 }
    }
}
