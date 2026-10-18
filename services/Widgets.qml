pragma Singleton
import QtQuick
import Quickshell

// Les widgets : lesquels sont ouverts, et où. Le flocon de la barre de
// conversation les ouvre, et anna aussi (outil MCP `widget` du pilote, cf.
// anna/src/claude/desk.rs), par la FIFO du shell :
//
//   echo "widget:stats"            > /tmp/qs-panel.fifo   → bascule
//   echo "widget:lecteur:ouvrir"   > /tmp/qs-panel.fifo
//   echo "widget:tout:fermer"      > /tmp/qs-panel.fifo
//
// Les noms sont ceux de `names`, en français comme les outils du pilote.
// Ceux de `hubTabs` vivent dans la capsule de la barre de conversation, que
// le flocon agrandit vers le haut (panels/WidgetHub.qml) : un onglet chacun,
// un seul affiché à la fois. « explorer » parcourt les dossiers du PC
// (widgets/FileExplorer.qml). « camera » reste une carte flottante
// (FloatingWidgets), « sessions » le dock IA.
Singleton {
    id: widgets

    readonly property var names: ["explorer", "stats", "notifications", "notes", "lecteur", "musique", "son", "camera", "reglages", "sessions"]

    // Les onglets des widgets, dans l'ordre de la barre d'onglets.
    readonly property var hubTabs: ["explorer", "stats", "notifications", "notes", "lecteur", "musique", "reglages"]
    readonly property var hubLabels: ({
        explorer: I18n.tr("widget.explorer"),
        stats: I18n.tr("widget.stats"),
        notifications: I18n.tr("widget.notifications"),
        notes: I18n.tr("widget.notes"),
        lecteur: I18n.tr("widget.player"),
        musique: I18n.tr("widget.music"),
        reglages: I18n.tr("widget.settings")
    })
    readonly property var hubIcons: ({
        explorer: "folder.svg",
        stats: "stats.svg",
        notifications: "bell.svg",
        notes: "notes.svg",
        lecteur: "play.svg",
        musique: "music.svg",
        reglages: "settings.svg"
    })

    // Les widgets affichés dans la capsule, et l'onglet (gardé quand on les ferme).
    property bool hubOpen: false
    property string hubTab: "stats"
    // Le dossier ouvert dans l'explorateur, gardé d'un onglet à l'autre ;
    // vide : le dossier personnel.
    property string explorerPath: ""
    // La machine choisie, la même pour tous les onglets qui en montrent une
    // (Explorer, Système ; cf. MachinePicker) : null pour celle-ci, sinon un
    // serveur du tailnet ({ name, host }).
    property var machine: null
    readonly property string machineName: widgets.machine ? widgets.machine.name : ""
    // Ce que l'Explorer en a monté : null pour celle-ci, sinon le serveur
    // monté par sshfs (cf. FileExplorer.connect). Il rattrape `machine` dès
    // qu'il est affiché.
    property var explorerMachine: null

    // Le titre de chaque carte flottante.
    readonly property var titles: ({
        camera: I18n.tr("widget.camera")
    })

    // { nom: true } pour chaque carte flottante ou le dock ouvert. Réaffecté
    // en entier à chaque changement pour que les liaisons suivent.
    property var opened: ({})
    // { nom: { x, y } } : la dernière place de chaque carte, gardée tant que
    // le shell tourne.
    property var positions: ({})

    function isHubTab(name) {
        return widgets.hubTabs.indexOf(name) >= 0;
    }

    // Les anciens noms d'onglets, devenus une partie d'un autre : « son »
    // (sortie, entrée) vit dans les réglages, le métronome et l'accordeur
    // dans « musique », les serveurs du tailnet (« network ») et le téléphone
    // (« telephone ») dans « stats ».
    readonly property var aliases: ({ son: "reglages", metronome: "musique", accordeur: "musique", network: "stats", telephone: "stats" })

    function isOpen(name) {
        name = widgets.aliases[name] || name;
        if (widgets.isHubTab(name))
            return widgets.hubOpen && widgets.hubTab === name;
        return !!widgets.opened[name];
    }

    // Les widgets d'un coup : rouverts sur le dernier onglet.
    function toggleHub() {
        widgets.hubOpen = !widgets.hubOpen;
    }

    function _set(name, on) {
        name = widgets.aliases[name] || name;
        if (widgets.isHubTab(name)) {
            if (on) {
                widgets.hubTab = name;
                widgets.hubOpen = true;
            } else if (widgets.hubTab === name) {
                widgets.hubOpen = false;
            }
            return;
        }
        var o = Object.assign({}, widgets.opened);
        if (on)
            o[name] = true;
        else
            delete o[name];
        widgets.opened = o;
    }

    // action : "ouvrir", "fermer" ou "basculer" (le défaut). « tout » ne
    // sait que se fermer. Renvoie false pour un nom inconnu.
    function apply(name, action) {
        if (name === "tout") {
            if (action === "fermer" || action === "basculer" || !action)
                widgets.closeAll();
            return true;
        }
        if (widgets.names.indexOf(name) < 0 && !widgets.aliases[name])
            return false;
        var on = action === "ouvrir" ? true
               : action === "fermer" ? false
               : !widgets.isOpen(name);
        widgets._set(name, on);
        return true;
    }

    function closeAll() {
        widgets.opened = ({});
        widgets.hubOpen = false;
    }

    // Où poser une carte de cette taille sur un écran de cette taille : là où
    // on l'a laissée, sinon à sa place par défaut (les gestes dans le coin
    // droit). Toujours
    // ramenée dans l'écran (il a pu changer depuis).
    readonly property var defaults: ({
        camera: { x: -24, y: 260 }
    })

    function position(name, w, h, screenW, screenH) {
        var p = widgets.positions[name] || widgets.defaults[name] || { x: 24, y: 24 };
        // Un x négatif se compte depuis le bord droit.
        var x = p.x < 0 ? screenW - w + p.x : p.x;
        return {
            x: Math.max(0, Math.min(x, screenW - w)),
            y: Math.max(0, Math.min(p.y, screenH - h))
        };
    }

    function move(name, x, y) {
        var p = Object.assign({}, widgets.positions);
        p[name] = { x: Math.round(x), y: Math.round(y) };
        widgets.positions = p;
    }
}
