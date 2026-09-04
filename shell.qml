pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import "panels"
import "services"

ShellRoot {
    id: root

    property bool panelOpen: false
    property int activeWidget: 0
    property bool rightOpen: false
    property bool controlsOpen: false

    // Toggle a widget. Only one panel is ever open: opening either side
    // closes the other. Shared by the FIFO listener and the bar's buttons.
    function activateWidget(idx) {
        if (idx === 0) {
            rightOpen = !rightOpen;
            if (rightOpen)
                panelOpen = false;
        } else if (panelOpen && activeWidget === idx) {
            panelOpen = false;
        } else {
            activeWidget = idx;
            panelOpen = true;
            rightOpen = false;
        }
    }

    // ── IPC externe via FIFO /tmp/qs-panel.fifo ──────────────────────────
    //   echo "widget:N" > /tmp/qs-panel.fifo   → bascule le widget N
    //   echo "controls" > /tmp/qs-panel.fifo   → bascule le popup de contrôles
    //   echo "close"    > /tmp/qs-panel.fifo   → ferme le panel
    //   N : 0=Stats  1=IA  2=Notes  3=Pitch  4=Music  5=Console
    Process {
        id: ipcListener
        command: [
            "bash", "-c",
            "rm -f /tmp/qs-panel.fifo; mkfifo /tmp/qs-panel.fifo; " +
            "exec 3<>/tmp/qs-panel.fifo; " +
            "while IFS= read -r line <&3; do echo \"$line\"; done"
        ]
        running: true
        stdout: SplitParser {
            onRead: (data) => {
                var msg = data.trim();
                if (msg.startsWith("widget:")) {
                    var idx = parseInt(msg.substring(7));
                    if (!isNaN(idx))
                        root.activateWidget(idx);
                } else if (msg === "controls") {
                    root.controlsOpen = !root.controlsOpen;
                } else if (msg === "close") {
                    root.panelOpen = false;
                    root.rightOpen = false;
                    root.controlsOpen = false;
                }
            }
        }
        onExited: Qt.callLater(function() { ipcListener.running = true; }) // qmllint disable signal-handler-parameters
    }

    property string primaryScreen: "eDP-1"

    // Only the primary screen. Feeding this (instead of Quickshell.screens) to
    // the Variants below means the panels are instantiated ONCE, not once per
    // monitor — otherwise the hidden per-screen variants still run their
    // backends (metronome player, hardware polling…) for nothing.
    readonly property var primaryScreens: {
        var out = [];
        var ss = Quickshell.screens;
        for (var i = 0; i < ss.length; i++)
            if (ss[i] && ss[i].name === primaryScreen)
                out.push(ss[i]);
        return out;
    }

    Variants {
        model: root.primaryScreens

        LeftBar {
            property var modelData
            screen: modelData
            visible: modelData && modelData.name === root.primaryScreen
            panelOpen: root.panelOpen
            activeWidget: root.activeWidget
            rightOpen: root.rightOpen
            controlsOpen: root.controlsOpen
            onSelectWidget: (idx) => root.activateWidget(idx)
            onToggleControls: root.controlsOpen = !root.controlsOpen
        }
    }

    Variants {
        model: root.primaryScreens

        ControlsPopup {
            property var modelData
            screen: modelData
            popupOpen: root.controlsOpen && modelData && modelData.name === root.primaryScreen
            onDismissed: root.controlsOpen = false
        }
    }

    Variants {
        model: root.primaryScreens

        SidePanel {
            property var modelData
            screen: modelData
            visible: modelData && modelData.name === root.primaryScreen
            panelOpen: root.panelOpen
            activeWidget: root.activeWidget
        }
    }

    Variants {
        model: root.primaryScreens

        RightPanel {
            property var modelData
            screen: modelData
            visible: modelData && modelData.name === root.primaryScreen
            panelOpen: root.rightOpen
        }
    }

    Variants {
        model: root.primaryScreens

        SettingsWindow {
            property var modelData
            screen: modelData
            visible: modelData && modelData.name === root.primaryScreen && Theme.settingsOpen
        }
    }
}
