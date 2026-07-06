pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "panels"
import "services"

ShellRoot {
    id: root

    property bool panelOpen: false
    property int activeWidget: 0
    property bool rightOpen: false

    // ── IPC externe via FIFO /tmp/qs-panel.fifo ──────────────────────────
    //   echo "widget:N" > /tmp/qs-panel.fifo   → bascule le widget N
    //   echo "close"    > /tmp/qs-panel.fifo   → ferme le panel
    //   N : 0=Stats  1=IA  2=Notes  3=Pitch  4=Music
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
                    if (!isNaN(idx)) {
                        if (idx === 0) {
                            root.rightOpen = !root.rightOpen;
                        } else if (root.panelOpen && root.activeWidget === idx) {
                            root.panelOpen = false;
                        } else {
                            root.activeWidget = idx;
                            root.panelOpen = true;
                        }
                    }
                } else if (msg === "close") {
                    root.panelOpen = false;
                    root.rightOpen = false;
                }
            }
        }
        onExited: Qt.callLater(function() { ipcListener.running = true; })
    }

    property string primaryScreen: "DP-1"

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

        BottomBar {
            property var modelData
            screen: modelData
            visible: modelData && modelData.name === root.primaryScreen
            panelOpen: root.panelOpen
            activeWidget: root.activeWidget
            rightOpen: root.rightOpen
            onSelectWidget: (idx) => {
                if (idx === 0) {
                    root.rightOpen = !root.rightOpen;
                } else if (root.panelOpen && root.activeWidget === idx) {
                    root.panelOpen = false;
                } else {
                    root.activeWidget = idx;
                    root.panelOpen = true;
                }
            }
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
