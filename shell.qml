pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import "panels"
import "services"

ShellRoot {
    id: root

    // Super montre ou renvoie la barre de conversation ; c'est elle qui sait
    // si elle est là (cf. ConversationBar.toggle).
    signal barToggled()
    signal barClosed()

    // Les anciens numéros de widget (widget:N) des raccourcis existants.
    readonly property var legacyWidgets: ({ 0: "stats", 1: "sessions", 3: "metronome", 4: "musique" })

    // ── IPC externe via FIFO /tmp/qs-panel.fifo ──────────────────────────
    //   echo "widget:NOM[:ACTION]" > /tmp/qs-panel.fifo → ouvre / ferme / bascule
    //        un widget flottant (cf. services/Widgets.qml ; c'est ce qu'écrit anna)
    //   echo "dock"     > /tmp/qs-panel.fifo   → fait monter (ou renvoie) la barre de conversation
    //   echo "savoir"   > /tmp/qs-panel.fifo   → ouvre le dock IA sur le savoir
    //   echo "voix"     > /tmp/qs-panel.fifo   → parle au pilote (comme `anna voice`)
    //   echo "controls" > /tmp/qs-panel.fifo   → bascule le widget du son
    //   echo "camera"   > /tmp/qs-panel.fifo   → bascule le widget caméra/gestes
    //   echo "close"    > /tmp/qs-panel.fifo   → ferme tout
    //   NOM : stats, musique, metronome, son, camera, reglages, sessions, tout
    //   ACTION : ouvrir, fermer, basculer (le défaut)
    //   « widget:N » reste compris : 0=stats 1=sessions 3=metronome 4=musique
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
                    var parts = msg.substring(7).split(":");
                    var name = parts[0];
                    if (/^[0-9]+$/.test(name))
                        name = root.legacyWidgets[parseInt(name)] || "";
                    Widgets.apply(name, parts[1] || "basculer");
                } else if (msg === "dock") {
                    root.barToggled();
                } else if (msg === "voix") {
                    ClaudeLive.voiceToggle();
                } else if (msg === "savoir") {
                    Widgets.apply("sessions", "ouvrir");
                    aiDock.openKnowledge();
                } else if (msg === "controls") {
                    Widgets.apply("son", "basculer");
                } else if (msg === "camera") {
                    Widgets.apply("camera", "basculer");
                } else if (msg === "close") {
                    Widgets.closeAll();
                    root.barClosed();
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

    // La barre de conversation, en bas au centre : le flocon (la voix) et le
    // champ qui parle au pilote, sa réponse au-dessus.
    Variants {
        model: root.primaryScreens

        ConversationBar {
            id: conversationBar
            property var modelData
            screen: modelData

            Connections {
                target: root
                function onBarToggled() { conversationBar.toggle(); }
                function onBarClosed() { conversationBar.dismiss(); }
            }
        }
    }

    // Les widgets flottants (système, musique, métronome, son, gestes),
    // qu'anna ouvre à la demande.
    Variants {
        model: root.primaryScreens

        FloatingWidgets {
            property var modelData
            screen: modelData
        }
    }

    // Alertes des sessions Claude Code (attente, long tour terminé), dans le
    // coin haut droit de l'écran de l'interface.
    Variants {
        model: root.primaryScreens

        SessionToast {
            property var modelData
            screen: modelData
        }
    }

    // La barre des sessions, bande noire contre le bord gauche, toujours là : la liste des
    // sessions Claude et leurs permissions à valider. Une ligne affiche le texte de sa
    // session (le dock IA), ✦ bascule le dock.
    Variants {
        model: root.primaryScreens

        SessionBar {
            property var modelData
            screen: modelData
            openId: aiDock.open && !aiDock.overlay ? aiDock.selectedId : ""
            onPicked: (id) => aiDock.openOn(id)
            onToggled: Widgets.apply("sessions", "basculer")
        }
    }

    // Le panneau des sessions, qui sort de leur barre : lancer, suivre et
    // reprendre les sessions Claude, revoir leur travail, le savoir. C'est le
    // widget « sessions » : un point de la barre, Super+P
    // (widget:sessions:basculer sur la FIFO) ou anna l'ouvrent.
    AiDock {
        id: aiDock
        screen: Display.primary
        open: Widgets.opened.sessions === true
        onCloseRequested: Widgets.apply("sessions", "fermer")
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
