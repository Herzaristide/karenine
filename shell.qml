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
    // Popup caméra / gestes (bouton caméra de la barre).
    property bool cameraOpen: false
    // Dock du bas maintenu ouvert au clavier (cf. commande IPC "dock").
    property bool dockPinned: false

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
    //   echo "dock"     > /tmp/qs-panel.fifo   → bascule le dock du bas
    //   echo "controls" > /tmp/qs-panel.fifo   → bascule le popup de contrôles
    //   echo "camera"   > /tmp/qs-panel.fifo   → bascule le popup caméra/gestes
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
                } else if (msg === "dock") {
                    root.dockPinned = !root.dockPinned;
                } else if (msg === "controls") {
                    root.controlsOpen = !root.controlsOpen;
                } else if (msg === "camera") {
                    root.cameraOpen = !root.cameraOpen;
                    if (root.cameraOpen)
                        root.controlsOpen = false;
                } else if (msg === "close") {
                    root.panelOpen = false;
                    root.rightOpen = false;
                    root.controlsOpen = false;
                    root.cameraOpen = false;
                    root.dockPinned = false;
                }
            }
        }
        onExited: Qt.callLater(function() { ipcListener.running = true; }) // qmllint disable signal-handler-parameters
    }

    // Écran par défaut de l'interface. La config Nix substitue cette ligne
    // (« DP-1 » est la valeur standalone, comme dans lock.qml) : le réglage
    // « Écran » de la fenêtre de paramètres passe devant, et à défaut des deux
    // Display retombe sur le premier écran branché (cf. services/Display.qml).
    property string primaryScreen: "DP-1"

    Binding {
        target: Display
        property: "defaultName"
        value: root.primaryScreen
    }

    // Only the interface screen. Feeding this (instead of Quickshell.screens)
    // to the Variants below means the panels are instantiated ONCE, not once
    // per monitor — otherwise the hidden per-screen variants still run their
    // backends (metronome player, hardware polling…) for nothing. Changing the
    // screen swaps the model, so the panels are rebuilt on the new one.
    readonly property var primaryScreens: Display.primary ? [Display.primary] : []

    Variants {
        model: root.primaryScreens

        TopBar {
            property var modelData
            screen: modelData
            panelOpen: root.panelOpen
            activeWidget: root.activeWidget
            rightOpen: root.rightOpen
            controlsOpen: root.controlsOpen
            cameraOpen: root.cameraOpen
            onSelectWidget: (idx) => root.activateWidget(idx)
            // Les deux popups de la barre s'excluent : ils tombent au même endroit.
            onToggleControls: {
                root.controlsOpen = !root.controlsOpen;
                if (root.controlsOpen)
                    root.cameraOpen = false;
            }
            onToggleCamera: {
                root.cameraOpen = !root.cameraOpen;
                if (root.cameraOpen)
                    root.controlsOpen = false;
            }
        }
    }

    Variants {
        model: root.primaryScreens

        ControlsPopup {
            property var modelData
            screen: modelData
            popupOpen: root.controlsOpen
            onDismissed: root.controlsOpen = false
        }
    }

    Variants {
        model: root.primaryScreens

        CameraPopup {
            property var modelData
            screen: modelData
            popupOpen: root.cameraOpen
            onDismissed: root.cameraOpen = false
        }
    }

    Variants {
        model: root.primaryScreens

        SidePanel {
            property var modelData
            screen: modelData
            panelOpen: root.panelOpen
            activeWidget: root.activeWidget
        }
    }

    Variants {
        model: root.primaryScreens

        RightPanel {
            property var modelData
            screen: modelData
            panelOpen: root.rightOpen
        }
    }

    // Le dock n'est pas lié à l'écran de l'interface : une seule instance, qui
    // suit l'écran ayant le focus (cf. BottomDock, qui ne change d'écran que
    // refermé).
    BottomDock {
        screen: Display.focused
        pinned: root.dockPinned
        onCloseRequested: root.dockPinned = false
    }

    Variants {
        model: root.primaryScreens

        SettingsWindow {
            property var modelData
            screen: modelData
            visible: Theme.settingsOpen
        }
    }
}
