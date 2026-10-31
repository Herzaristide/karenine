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

    // Les singletons ne naissent qu'au premier usage. Ceux-ci doivent tourner
    // dès le démarrage, même sans rien d'ouvert : le serveur de notifications
    // (sinon personne ne tient org.freedesktop.Notifications) et la batterie,
    // qui prévient quand elle faiblit.
    readonly property var resident: [Notifications, Battery]

    // Les anciens numéros de widget (widget:N) des raccourcis existants.
    readonly property var legacyWidgets: ({ 0: "stats", 3: "musique", 4: "lecteur" })

    // ── IPC externe via FIFO /tmp/qs-panel.fifo ──────────────────────────
    //   echo "widget:NOM[:ACTION]" > /tmp/qs-panel.fifo → ouvre / ferme / bascule
    //        un widget flottant (cf. services/Widgets.qml ; c'est ce qu'écrit anna)
    //   echo "dock"     > /tmp/qs-panel.fifo   → fait monter (ou renvoie) la barre de conversation
    //   echo "voix"     > /tmp/qs-panel.fifo   → parle au pilote (comme `anna voice`)
    //   echo "controls" > /tmp/qs-panel.fifo   → bascule les réglages (sortie, entrée, webcam)
    //   echo "camera"   > /tmp/qs-panel.fifo   → bascule le widget caméra/gestes
    //   echo "close"    > /tmp/qs-panel.fifo   → ferme tout
    //   NOM : explorer, stats, notifications, notes, lecteur, musique, son, camera,
    //         reglages, tout
    //   ACTION : ouvrir, fermer, basculer (le défaut)
    //   « widget:N » reste compris : 0=stats 3=musique 4=lecteur
    //   echo "metronome:ACTION[:BPM[:TEMPS]]" > /tmp/qs-panel.fifo → lance, arrête ou
    //        bascule le métronome (services/Tempo.qml), onglet ouvert ou non
    //        ACTION : lancer, arreter, basculer ; BPM 20–300 ; TEMPS par mesure
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
                } else if (msg.startsWith("metronome")) {
                    var m = msg.split(":");
                    Tempo.apply(m[1] || "basculer", m[2], m[3]);
                } else if (msg === "dock") {
                    root.barToggled();
                } else if (msg === "voix") {
                    Pilot.voiceToggle();
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
    // Le fond d'écran : un tableau noir par écran, chacun avec ses notes et
    // ses traits (panels/Blackboard.qml).
    Variants {
        model: Quickshell.screens

        Blackboard {
            required property var modelData
            screen: modelData
        }
    }

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

    // La barre tactile, à gauche (en bas en portrait) : la batterie, le
    // flocon qui fait monter la barre de conversation comme Super, et les
    // workspaces.
    Variants {
        model: root.primaryScreens

        TabletBar {
            property var modelData
            screen: modelData
            onAskRequested: root.barToggled()
        }
    }

    // La petite barre du haut : la luminosité et le volume quand ils
    // changent ou que la souris approche, l'enregistrement en cours.
    Variants {
        model: root.primaryScreens

        LevelsIsland {
            property var modelData
            screen: modelData
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

    // L'agent polkit : les demandes de mot de passe des actions système,
    // sur l'écran de l'interface.
    PolkitPrompt {
        screen: Display.primary
    }
}
