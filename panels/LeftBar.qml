pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import "../services"
import "../widgets"

PanelWindow { // qmllint disable uncreatable-type
    id: window

    property bool panelOpen: false
    property int activeWidget: 0
    property bool rightOpen: false
    property bool controlsOpen: false
    signal selectWidget(int index)
    signal toggleControls()

    // Top, not Bottom: on Bottom the bar is painted under the windows and
    // disappears behind them while Hyprland animates a workspace switch.
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-leftbar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        top: true
        left: true
        bottom: true
    }

    // The surface is wider than the bar itself so the background can bulge out
    // around the flake; only `barWidth` is reserved from the workspace, and the
    // input mask keeps the overhang click-through.
    readonly property int barWidth: 44
    implicitWidth: 56
    exclusiveZone: barWidth
    color: "transparent"

    mask: Region { // qmllint disable unqualified
        x: 0
        y: 0
        width: window.barWidth
        height: window.height
    }

    // ── Design tokens ────────────────────────────────────────────
    readonly property int  pillW:   32          // uniform width of every group
    readonly property int  pad:     4           // inner padding along the bar axis
    readonly property int  cell:    32          // one segment / hit-target
    readonly property int  capInset: 4          // capsule inset across the bar
    readonly property int  capGap:   3          // capsule inset along the bar

    readonly property int  wsCount: 5

    // Battery tint, matching the thresholds QuickControls already uses.
    readonly property color batteryColor: {
        if (!Battery.present) return Theme.textInactive;
        if (Battery.status === "Charging" || Battery.status === "Full")
            return Theme.colorSuccess;
        if (Battery.percent <= 15) return Theme.colorDanger;
        if (Battery.percent <= 30) return Theme.textDim;
        return Theme.iconColor;
    }

    // ── Flake geometry ───────────────────────────────────────────
    // The flake sits left of the bar's centre so it bleeds off the screen
    // edge; the background bulge is a slightly larger hexagon sharing that
    // centre, so its two visible edges run parallel to the flake's own arms.
    readonly property int  logoSize:   56
    readonly property real logoOffset: -8
    readonly property real hexCx: barWidth / 2 + logoOffset
    readonly property real hexCy: height / 2
    readonly property real hexR:  38

    // Upper-right vertex of that hexagon, and where the edge running from it
    // down to the right-hand tip crosses the bar's own edge.
    readonly property real hexVertexX: hexCx + hexR / 2
    readonly property real hexVertexY: hexCy - hexR * 0.8660254
    readonly property real hexTipX:    hexCx + hexR
    readonly property real hexEdgeY: hexVertexY
        + (hexCy - hexVertexY) * ((barWidth - hexVertexX) / (hexTipX - hexVertexX))

    // Apple-ish spring for anything that slides between positions —
    // a tiny overshoot reads as "settling", not bouncy.
    readonly property int  slideDuration: 360

    function toRoman(num) {
        const romanNumerals = ["I", "II", "III", "IV", "V"];
        return romanNumerals[num - 1] || "";
    }

    // Top group — one connected control. Icons drawn on the flake's own grid:
    // 60° angles, constant stroke, bevelled ends (see assets/icons).
    readonly property var appButtons: [
        { icon: Qt.resolvedUrl("../assets/icons/ai.svg"),        widget: 1 },
        { icon: Qt.resolvedUrl("../assets/icons/metronome.svg"), widget: 3 },
        { icon: Qt.resolvedUrl("../assets/icons/music.svg"),     widget: 4 },
        { icon: Qt.resolvedUrl("../assets/icons/terminal.svg"),  widget: 5 }
    ]

    // ── Bar surface ───────────────────────────────────────────────
    // One slab behind the whole bar — the groups themselves are bare, only
    // the accent capsules and hover halos sit on top of it. Its right edge
    // steps out into a point around the flake, along the hexagon's edges.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        opacity: 0.88

        ShapePath {
            fillColor: Theme.bgDeep
            strokeColor: Theme.dividerColor
            strokeWidth: 1

            startX: 0
            startY: 0
            PathLine { x: window.barWidth; y: 0 }
            PathLine { x: window.barWidth; y: window.hexEdgeY }
            PathLine { x: window.hexTipX;  y: window.hexCy }
            PathLine { x: window.barWidth; y: 2 * window.hexCy - window.hexEdgeY }
            PathLine { x: window.barWidth; y: window.height }
            PathLine { x: 0;               y: window.height }
        }
    }

    // ── NixOS snowflake — workspace indicator, centered ───────────
    // Deliberately wider than the bar and pushed left so it bleeds off the
    // screen edge. It turns once per workspace step while the numeral at its
    // hub tracks the current workspace.
    Item {
        id: nixLogo
        x: window.hexCx - width / 2
        y: window.hexCy - height / 2
        width: window.logoSize
        height: window.logoSize
        z: 1

        readonly property int focusedId: {
            const id = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1;
            return Math.min(window.wsCount, Math.max(1, id));
        }

        property int  previousId: 1
        property real spin: 0

        Component.onCompleted: previousId = focusedId

        // One full turn per change, in the direction of travel: any other
        // angle relies on the flake being perfectly symmetric, which it is
        // not, and leaves it resting slightly askew.
        onFocusedIdChanged: {
            spin += focusedId > previousId ? 360 : -360;
            previousId = focusedId;
            numeralPop.restart();
        }

        Behavior on spin {
            NumberAnimation {
                duration: 700
                easing.type: Easing.OutBack
                easing.overshoot: 1.02
            }
        }

        // Spinning flake. The SVG artwork is pure white, so it is recolored
        // to the theme icon color instead of being drawn as-is.
        Item {
            anchors.fill: parent
            transformOrigin: Item.Center
            rotation: nixLogo.spin
            scale: nixMa.pressed ? 0.9 : 1.0

            Behavior on scale {
                NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
            }

            Image {
                id: flakeSource
                anchors.fill: parent
                source: "../assets/nixos.svg"
                sourceSize.width: 128
                sourceSize.height: 128
                fillMode: Image.PreserveAspectFit
                smooth: true
                visible: false
            }

            MultiEffect {
                anchors.fill: flakeSource
                source: flakeSource
                colorization: 1.0
                colorizationColor: window.rightOpen ? Theme.accentColor : Theme.iconColor
                opacity: window.rightOpen ? 1.0 : (nixMa.containsMouse ? 0.95 : 0.72)

                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }
        }

        // Workspace numeral at the hub — never rotates. It sits on the white
        // arms of the flake, so a soft dark shadow is what keeps it readable.
        Item {
            id: numeralHub
            anchors.centerIn: parent
            width: 34
            height: 18

            SequentialAnimation {
                id: numeralPop
                NumberAnimation {
                    target: numeralHub; property: "scale"
                    to: 0.72; duration: 120; easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: numeralHub; property: "scale"
                    to: 1.0; duration: 320; easing.type: Easing.OutBack; easing.overshoot: 2.2
                }
            }

            Text {
                id: wsNumeral
                anchors.centerIn: parent
                text: window.toRoman(nixLogo.focusedId)
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                color: "#FFFFFF"
                visible: false
            }

            MultiEffect {
                anchors.fill: wsNumeral
                source: wsNumeral
                shadowEnabled: true
                shadowColor: "#000000"
                shadowBlur: 1.0
                shadowOpacity: 0.9
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }
        }

        MouseArea {
            id: nixMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: window.selectWidget(0)
            // Scrolling over the flake walks through the workspaces — the
            // segmented selector is gone, this replaces its click targets.
            onWheel: (wheel) => {
                const step = wheel.angleDelta.y > 0 ? -1 : 1;
                const target = Math.min(window.wsCount,
                                        Math.max(1, nixLogo.focusedId + step));
                if (target !== nixLogo.focusedId)
                    Hyprland.dispatch("hl.dsp.focus({ workspace = " + target + " })");
            }
        }
    }

    ColumnLayout {
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.topMargin: 12
        anchors.bottomMargin: 12
        width: window.barWidth   // stay inside the bar, not the overhang
        spacing: 0

        // ── Top connected app group ───────────────────────────────
        Item {
            id: appGroup
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth:  window.pillW
            Layout.preferredHeight: window.appButtons.length * window.cell + window.pad * 2

            // Row of the active widget. Looked up rather than derived from the
            // widget id: the ids are fixed by the IPC protocol and no longer
            // match the row order now that Notes is gone.
            readonly property int activeRow: {
                for (let i = 0; i < window.appButtons.length; i++)
                    if (window.appButtons[i].widget === window.activeWidget)
                        return i;
                return -1;
            }

            readonly property bool hasActive: window.panelOpen && activeRow >= 0

            // Sliding accent capsule behind the active app.
            Rectangle {
                width: parent.width - window.capInset * 2
                height: window.cell - window.capGap * 2
                radius: width / 2
                color: Theme.accentColor
                x: window.capInset
                y: window.pad + window.capGap + Math.max(0, appGroup.activeRow) * window.cell
                opacity: appGroup.hasActive ? 1.0 : 0.0
                scale: appGroup.hasActive ? 1.0 : 0.6

                Behavior on y {
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

            Column {
                y: window.pad
                width: parent.width
                spacing: 0

                Repeater {
                    model: window.appButtons

                    Item {
                        id: appBtn
                        required property int index
                        required property var modelData
                        width: window.pillW
                        height: window.cell

                        readonly property bool isActive: window.panelOpen
                                                         && window.activeWidget === modelData.widget

                        // Hover halo (hidden while active — the capsule owns it).
                        Rectangle {
                            width: parent.width - window.capInset * 2
                            height: window.cell - window.capGap * 2
                            radius: width / 2
                            anchors.centerIn: parent
                            color: Theme.iconColor
                            opacity: (appMa.containsMouse && !appBtn.isActive) ? 0.08 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }

                        NixIcon {
                            anchors.centerIn: parent
                            source: appBtn.modelData.icon
                            iconSize: 17
                            color: Theme.iconColor
                            opacity: appBtn.isActive ? 1.0 : (appMa.containsMouse ? 0.95 : 0.72)
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
                            onClicked: window.selectWidget(appBtn.modelData.widget)
                        }
                    }
                }
            }
        }

        // ── Spacer ─────────────────────────────────────────────────
        Item { Layout.fillHeight: true }

        // ── System tray (StatusNotifierItem) ───────────────────────
        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth:  window.pillW
            Layout.preferredHeight: SystemTray.items.values.length * window.cell + window.pad * 2
            visible: SystemTray.items.values.length > 0

            Behavior on Layout.preferredHeight {
                NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
            }

            Column {
                y: window.pad
                width: parent.width
                spacing: 0

                Repeater {
                    model: SystemTray.items

                    Item {
                        id: trayItem
                        required property var modelData
                        width: window.pillW
                        height: window.cell

                        // Hover halo, matching the app group.
                        Rectangle {
                            width: parent.width - window.capInset * 2
                            height: window.cell - window.capGap * 2
                            radius: width / 2
                            anchors.centerIn: parent
                            color: Theme.iconColor
                            opacity: trayMa.containsMouse ? 0.08 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }

                        // Bluetooth gets the house icon — the theme's own is a
                        // full-colour badge that sits badly next to the rest.
                        readonly property bool isBluetooth: {
                            const m = trayItem.modelData;
                            const name = ((m.id || "") + " " + (m.title || "")).toLowerCase();
                            return name.indexOf("blue") >= 0;
                        }

                        NixIcon {
                            anchors.centerIn: parent
                            visible: trayItem.isBluetooth
                            source: Qt.resolvedUrl("../assets/icons/bluetooth.svg")
                            iconSize: 17
                            color: Theme.iconColor
                            opacity: trayMa.containsMouse ? 0.95 : 0.72
                            scale: trayMa.pressed ? 0.82 : 1.0

                            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                            Behavior on scale {
                                NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                            }
                        }

                        Image {
                            anchors.centerIn: parent
                            visible: !trayItem.isBluetooth
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
                                    // Menus open off the bar's right edge now.
                                    const p = trayItem.mapToItem(null, trayItem.width, trayItem.height / 2);
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

        // ── Volume button — opens the controls popup ───────────────
        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth:  window.pillW
            Layout.preferredHeight: window.cell
            Layout.topMargin: 4

            Rectangle {
                width: parent.width - window.capInset * 2
                height: window.cell - window.capGap * 2
                radius: width / 2
                anchors.centerIn: parent
                color: window.controlsOpen ? Theme.accentColor : Theme.iconColor
                opacity: window.controlsOpen ? 1.0 : (volMa.containsMouse ? 0.08 : 0.0)
                scale: window.controlsOpen ? 1.0 : 0.6

                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on scale {
                    NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                }
                Behavior on color { ColorAnimation { duration: 220 } }
            }

            NixIcon {
                anchors.centerIn: parent
                source: Qt.resolvedUrl("../assets/icons/volume.svg")
                iconSize: 17
                color: Theme.iconColor
                opacity: window.controlsOpen ? 1.0 : (volMa.containsMouse ? 0.95 : 0.72)
                scale: volMa.pressed ? 0.82 : 1.0

                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on scale {
                    NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                }
            }

            MouseArea {
                id: volMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: window.toggleControls()
            }
        }

        // ── Battery ────────────────────────────────────────────────
        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth:  window.pillW
            Layout.preferredHeight: batteryCol.implicitHeight + 6
            visible: Battery.present

            Column {
                id: batteryCol
                anchors.centerIn: parent
                spacing: 0

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Battery.symbol
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    color: window.batteryColor
                    Behavior on color { ColorAnimation { duration: 220 } }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Battery.percent
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: window.batteryColor
                    Behavior on color { ColorAnimation { duration: 220 } }
                }
            }
        }
    }
}
