pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import "panels"
import "services"

ShellRoot {
    id: root

    // Super donne le clavier au champ de la barre du bas, ou le lui reprend
    // (cf. Bar.toggle).
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
    //        un onglet du panneau de droite (cf. services/Widgets.qml ; c'est ce qu'écrit anna)
    //   echo "dock"     > /tmp/qs-panel.fifo   → donne (ou reprend) le clavier au champ de la barre
    //   echo "voix"     > /tmp/qs-panel.fifo   → parle au pilote (comme `anna voice`)
    //   echo "controls" > /tmp/qs-panel.fifo   → bascule les réglages
    //   echo "close"    > /tmp/qs-panel.fifo   → ferme tout
    //   NOM : explorer, stats, agenda, lecteur, musique, claude, reglages (onglets),
    //         son, micro, wifi, bluetooth, telephone, notifications, energie,
    //         alimentation, taches (volets de la barre), tout
    //   echo "reglage:langue:fr" > /tmp/qs-panel.fifo → la langue de l'interface
    //   echo "reglage:langue_voix:auto" > /tmp/qs-panel.fifo → celle de la voix ("" : l'interface)
    //   ACTION : ouvrir, fermer, basculer (le défaut)
    //   « widget:N » reste compris : 0=stats 3=musique 4=lecteur
    //   echo "metronome:ACTION[:BPM[:TEMPS]]" > /tmp/qs-panel.fifo → lance, arrête ou
    //        bascule le métronome (services/Tempo.qml), onglet ouvert ou non
    //        ACTION : lancer, arreter, basculer ; BPM 20–300 ; TEMPS par mesure
    //   echo "explorer:dossier:/chemin" > /tmp/qs-panel.fifo → ouvre l'Explorer sur ce dossier
    //   echo "explorer:fichier:/chemin" > /tmp/qs-panel.fifo → … dans son dossier, lui sélectionné
    //        (c'est ce qu'écrit karenine-open, l'application XDG de inode/directory)
    //   echo 'explorer:choisir:{"mode":"open","multiple":false,"path":"/…","reply":"/…"}' > /tmp/qs-panel.fifo
    //        → l'Explorer en sélecteur de fichiers (karenine-pick, cf. Widgets.explorerPickStart)
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
                } else if (msg.startsWith("explorer:")) {
                    // explorer:dossier:<chemin> ou explorer:fichier:<chemin> ;
                    // le chemin, absolu, peut lui-même contenir des « : ».
                    var rest = msg.substring(9);
                    var sep = rest.indexOf(":");
                    var kind = sep > 0 ? rest.substring(0, sep) : "";
                    var target = rest.substring(sep + 1);
                    if ((kind === "dossier" || kind === "fichier") && target.startsWith("/")) {
                        Widgets.explorerShow(target, kind === "dossier");
                    } else if (kind === "choisir") {
                        try {
                            Widgets.explorerPickStart(JSON.parse(target));
                        } catch (e) {
                            console.warn("explorer:choisir : JSON illisible", e);
                        }
                    }
                } else if (msg.startsWith("metronome")) {
                    var m = msg.split(":");
                    Tempo.apply(m[1] || "basculer", m[2], m[3]);
                } else if (msg === "dock") {
                    root.barToggled();
                } else if (msg === "voix") {
                    Pilot.voiceToggle();
                } else if (msg.startsWith("reglage:")) {
                    // reglage:langue:<code> ou reglage:langue_voix:<code|auto|>
                    // (anna/src/claude/reglages.rs) : ce que le shell garde.
                    var r = msg.split(":");
                    if (r[1] === "langue")
                        I18n.setLang(r[2] || "");
                    else if (r[1] === "langue_voix")
                        I18n.setVoice(r[2] || "");
                } else if (msg === "controls") {
                    Widgets.apply("reglages", "basculer");
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

    // La surface : l'encre unie sous toutes les fenêtres.
    Variants {
        model: root.primaryScreens

        Surface {
            property var modelData
            screen: modelData
        }
    }

    // Le géoïde des bureaux vides, à la place des fenêtres : il suit la
    // barre et le panneau comme elles (sa zone, 0, n'en réserve aucune).
    Variants {
        model: root.primaryScreens

        GlobeLayer {
            property var modelData
            screen: modelData
        }
    }

    // La barre du bas et le panneau de droite, ensemble : Hyprland range les
    // zones exclusives dans l'ordre de création des surfaces, et la barre ne
    // garde toute la largeur que si elle est créée avant le panneau. Deux
    // Variants séparés se reconstruisent dans un ordre quelconque quand
    // l'écran change (débranché, rebranché, capot fermé) : le panneau
    // ouvert pouvait passer devant et rétrécir la barre. Ici le panneau
    // attend que la fenêtre de la barre soit là (barReady), et se recrée
    // après elle si elle est recréée.
    Variants {
        model: root.primaryScreens

        Scope {
            id: edges
            property var modelData

            // La barre du bas, toujours là : les workspaces, le flocon et le
            // champ qui parle au pilote, puis les groupes et leurs volets.
            Bar {
                id: bottomBar
                screen: edges.modelData

                Connections {
                    target: root
                    function onBarToggled() { bottomBar.toggle(); }
                    function onBarClosed() { bottomBar.dismiss(); }
                }
            }

            // Le panneau de droite, que le dernier bouton de la barre montre
            // ou cache : la musique, les fichiers, la flotte, l'agenda, Claude.
            SidePanel {
                screen: edges.modelData
                barReady: bottomBar.backingWindowVisible
                buttonInset: bottomBar.panelButtonInset
                buttonWidth: bottomBar.panelButtonWidth
            }
        }
    }

    // L'agent polkit : les demandes de mot de passe des actions système,
    // sur l'écran de l'interface.
    PolkitPrompt {
        screen: Display.primary
    }

    // Les autres demandes, relayées par anna : ssh, git, sudo… (Prompts).
    PromptHost {
        screen: Display.primary
    }
}
