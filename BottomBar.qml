import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.SystemTray

PanelWindow {
    id: window

    property bool panelOpen: false
    property int activeWidget: 0
    property bool rightOpen: false
    signal selectWidget(int index)

    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "quickshell-leftbar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        bottom: true
        left: true
        right: true
    }

    implicitHeight: 44
    color: "transparent"

    // ── Design tokens (shared by every pill so all containers match) ──
    readonly property int  pillH:   32          // uniform height of ALL pills
    readonly property int  pad:     4           // inner horizontal padding
    readonly property int  cell:    32          // one segment / hit-target
    readonly property int  capPadV: 4           // capsule vertical inset
    readonly property int  capPadH: 3           // capsule horizontal inset

    // Apple-ish spring for anything that slides between positions —
    // a tiny overshoot reads as "settling", not bouncy.
    readonly property int  slideDuration: 360

    // Subtle translucent surface shared by every pill container.
    readonly property color pillSurface: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.05)
                                                         : Qt.rgba(0, 0, 0, 0.05)

    function toRoman(num) {
        const romanNumerals = ["I", "II", "III", "IV", "V"];
        return romanNumerals[num - 1] || "";
    }

    // Left group — one connected control. Monochrome glyphs that exist in
    // JetBrains Mono itself (no emoji fallback → crisp, single weight).
    readonly property var appButtons: [
        { glyph: "◈", widget: 1, size: 15 },   // IA
        { glyph: "≡", widget: 2, size: 16 },   // Notes
        { glyph: "▲", widget: 3, size: 13 },   // Métronome
        { glyph: "▶", widget: 4, size: 13 }    // Musique
    ]

    // ── Workspace selector — segmented pill, centered ─────────────
    Rectangle {
        id: wsPill
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        z: 1

        height: window.pillH
        width:  5 * window.cell + window.pad * 2
        radius: height / 2
        color: window.pillSurface
        border.width: 1
        border.color: Theme.dividerColor

        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }

        readonly property int focusedId: {
            const id = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1;
            return Math.min(5, Math.max(1, id));
        }

        // Sliding accent capsule that follows the focused workspace.
        Rectangle {
            width: window.cell - window.capPadH * 2
            height: parent.height - window.capPadV * 2
            radius: height / 2
            color: Theme.accentColor
            y: window.capPadV
            x: window.pad + window.capPadH + (wsPill.focusedId - 1) * window.cell

            Behavior on x {
                NumberAnimation {
                    duration: window.slideDuration
                    easing.type: Easing.OutBack
                    easing.overshoot: 1.05
                }
            }
            Behavior on color { ColorAnimation { duration: 220 } }
        }

        Row {
            x: window.pad
            height: parent.height
            spacing: 0

            Repeater {
                model: 5

                Item {
                    required property int index
                    width: window.cell
                    height: window.pillH

                    readonly property int workspaceId: index + 1
                    readonly property bool isActive: wsPill.focusedId === workspaceId

                    Text {
                        anchors.centerIn: parent
                        text: window.toRoman(parent.workspaceId)
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        font.weight: parent.isActive ? Font.DemiBold : Font.Normal
                        color: Theme.iconColor

                        opacity: {
                            if (parent.isActive) return 1.0;
                            if (Hyprland.workspaces && Hyprland.workspaces.values) {
                                const ws = Hyprland.workspaces.values.find(w => w.id === parent.workspaceId);
                                const hasWindows = ws && ws.windows && ws.windows.values && ws.windows.values.length > 0;
                                return hasWindows ? 0.6 : 0.28;
                            }
                            return 0.28;
                        }

                        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + parent.workspaceId + " })")
                    }
                }
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 0

        // ── Left connected app group ──────────────────────────────
        Rectangle {
            id: appPill
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredHeight: window.pillH
            Layout.preferredWidth:  window.appButtons.length * window.cell + window.pad * 2
            radius: height / 2
            color: window.pillSurface
            border.width: 1
            border.color: Theme.dividerColor

            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }

            readonly property bool hasActive: window.panelOpen
                                              && window.activeWidget >= 1
                                              && window.activeWidget <= window.appButtons.length

            // Sliding accent capsule behind the active app.
            Rectangle {
                width: window.cell - window.capPadH * 2
                height: parent.height - window.capPadV * 2
                radius: height / 2
                color: Theme.accentColor
                y: window.capPadV
                x: window.pad + window.capPadH + Math.max(0, window.activeWidget - 1) * window.cell
                opacity: appPill.hasActive ? 1.0 : 0.0
                scale: appPill.hasActive ? 1.0 : 0.6

                Behavior on x {
                    NumberAnimation {
                        duration: window.slideDuration
                        easing.type: Easing.OutBack
                        easing.overshoot: 1.05
                    }
                }
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on scale {
                    NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                }
                Behavior on color { ColorAnimation { duration: 220 } }
            }

            Row {
                x: window.pad
                height: parent.height
                spacing: 0

                Repeater {
                    model: window.appButtons

                    Item {
                        required property int index
                        required property var modelData
                        width: window.cell
                        height: window.pillH

                        readonly property bool isActive: window.panelOpen
                                                         && window.activeWidget === modelData.widget

                        // Hover halo (hidden while active — the capsule owns it).
                        Rectangle {
                            width: window.cell - window.capPadH * 2
                            height: parent.height - window.capPadV * 2
                            radius: height / 2
                            anchors.centerIn: parent
                            color: Theme.iconColor
                            opacity: (appMa.containsMouse && !parent.isActive) ? 0.08 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.glyph
                            font.family: "JetBrains Mono"
                            font.pixelSize: modelData.size
                            color: Theme.iconColor
                            opacity: parent.isActive ? 1.0 : (appMa.containsMouse ? 0.9 : 0.5)
                            scale: appMa.pressed ? 0.82 : 1.0

                            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                            Behavior on scale {
                                NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                            }
                        }

                        MouseArea {
                            id: appMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: window.selectWidget(modelData.widget)
                        }
                    }
                }
            }
        }

        // ── Spacer ─────────────────────────────────────────────────
        Item { Layout.fillWidth: true }

        // ── System tray (StatusNotifierItem) ───────────────────────
        Rectangle {
            id: trayPill
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredHeight: window.pillH
            Layout.preferredWidth:  SystemTray.items.values.length * window.cell + window.pad * 2
            visible: SystemTray.items.values.length > 0
            radius: height / 2
            color: window.pillSurface
            border.width: 1
            border.color: Theme.dividerColor

            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on Layout.preferredWidth {
                NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
            }

            Row {
                x: window.pad
                height: parent.height
                spacing: 0

                Repeater {
                    model: SystemTray.items

                    Item {
                        id: trayItem
                        required property var modelData
                        width: window.cell
                        height: window.pillH

                        // Hover halo, matching the app group.
                        Rectangle {
                            width: window.cell - window.capPadH * 2
                            height: parent.height - window.capPadV * 2
                            radius: height / 2
                            anchors.centerIn: parent
                            color: Theme.iconColor
                            opacity: trayMa.containsMouse ? 0.08 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }

                        Image {
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            source: trayItem.modelData.icon
                            sourceSize.width: 40
                            sourceSize.height: 40
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            opacity: trayMa.containsMouse ? 1.0 : 0.85
                            scale: trayMa.pressed ? 0.82 : 1.0

                            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                            Behavior on scale {
                                NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                            }
                        }

                        MouseArea {
                            id: trayMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            onClicked: (mouse) => {
                                const item = trayItem.modelData;
                                if (mouse.button === Qt.MiddleButton) {
                                    item.secondaryActivate();
                                    return;
                                }
                                // Right click, or left click on a menu-only item → open menu.
                                if (mouse.button === Qt.RightButton || item.onlyMenu) {
                                    const p = trayItem.mapToItem(null, trayItem.width / 2, 0);
                                    item.display(window, p.x, p.y);
                                } else {
                                    item.activate();
                                }
                            }
                            onWheel: (wheel) => {
                                trayItem.modelData.scroll(wheel.angleDelta.y, false);
                            }
                        }
                    }
                }
            }
        }

        // Gap between tray and the NixOS button (only when tray is visible).
        Item {
            Layout.preferredWidth: trayPill.visible ? 8 : 0
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 200 } }
        }

        // ── NixOS button (HardwareStats) ───────────────────────────
        Rectangle {
            id: nixPill
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth:  window.cell + window.pad * 2
            Layout.preferredHeight: window.pillH
            radius: height / 2
            color: window.pillSurface
            border.width: 1
            border.color: Theme.dividerColor

            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Rectangle {
                width: window.cell - window.capPadH * 2
                height: parent.height - window.capPadV * 2
                radius: height / 2
                anchors.centerIn: parent
                color: Theme.accentColor
                opacity: window.rightOpen ? 1.0 : (nixMa.containsMouse ? 0.10 : 0.0)
                scale: window.rightOpen ? 1.0 : 0.6

                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on scale {
                    NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                }
            }

            Image {
                anchors.centerIn: parent
                width: 18
                height: 18
                source: "nixos.svg"
                sourceSize.width: 64
                sourceSize.height: 64
                fillMode: Image.PreserveAspectFit
                smooth: true
                opacity: window.rightOpen ? 1.0 : 0.7
                scale: nixMa.pressed ? 0.82 : 1.0

                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on scale {
                    NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                }
            }

            MouseArea {
                id: nixMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: window.selectWidget(0)
            }
        }
    }
}
