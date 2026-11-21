pragma Singleton
import QtQuick
import Quickshell

// Le panneau de droite (panels/SidePanel.qml) : ouvert ou non, sur quel
// onglet, à quelle largeur. Le dernier bouton de la barre du bas le montre
// ou le cache, et anna aussi (outil MCP `widget` du pilote, cf.
// anna/src/claude/desk.rs), par la FIFO du shell :
//
//   echo "widget:stats"            > /tmp/qs-panel.fifo   → bascule
//   echo "widget:lecteur:ouvrir"   > /tmp/qs-panel.fifo
//   echo "widget:tout:fermer"      > /tmp/qs-panel.fifo
//
// Les noms sont ceux de `names`, en français comme les outils du pilote ;
// chacun mène à un onglet du panneau (`tabs`).
Singleton {
    id: widgets

    readonly property var names: ["explorer", "stats", "agenda", "lecteur", "musique", "claude", "reglages"]

    // Le nom donné par le pilote → l'onglet du panneau. Les anciens noms
    // (« son », « metronome », « telephone »…) mènent à l'onglet qui les
    // contient aujourd'hui.
    readonly property var tabs: ({
        explorer: "files", stats: "system", agenda: "agenda", lecteur: "music", musique: "music",
        claude: "claude", reglages: "settings",
        son: "settings", metronome: "music", accordeur: "music", network: "system", telephone: "system"
    })

    property bool panelOpen: false
    // Son onglet ("music", "files", "system", "agenda", "claude", et
    // "settings" que la palette de la barre ouvre) et sa largeur, qu'on
    // règle en tirant son bord gauche.
    property string panelTab: "music"
    property int panelWidth: 440

    // Le dossier ouvert dans l'explorateur, gardé d'un onglet à l'autre ;
    // vide : le dossier personnel.
    property string explorerPath: ""
    // Le second dossier, sous le premier (le mode split) ; vide : fermé.
    property string explorerSplitPath: ""
    // L'Explorer en liste (nom, taille, date) plutôt qu'en tuiles.
    property bool explorerListView: false
    // La machine choisie, la même pour tous les onglets qui en montrent une
    // (cf. MachinePicker) : null pour celle-ci, sinon un serveur du tailnet
    // ({ name, host }).
    property var machine: null
    readonly property string machineName: widgets.machine ? widgets.machine.name : ""
    // Ce que l'Explorer en a monté : null pour celle-ci, sinon le serveur
    // monté par sshfs (cf. FileExplorer.connect). Il rattrape `machine` dès
    // qu'il est affiché.
    property var explorerMachine: null
    // La hauteur que l'Explorer demande (FileExplorer.implicitHeight).
    property int explorerHeight: 356

    function isOpen(name) {
        return widgets.panelOpen && widgets.panelTab === widgets.tabs[name];
    }

    // Un onglet du panneau, ouvert sur lui.
    function show(tab) {
        widgets.panelTab = tab;
        widgets.panelOpen = true;
    }

    // action : "ouvrir", "fermer" ou "basculer" (le défaut). « tout » ne
    // sait que se fermer. Renvoie false pour un nom inconnu.
    function apply(name, action) {
        if (name === "tout") {
            if (action === "fermer" || action === "basculer" || !action)
                widgets.closeAll();
            return true;
        }
        var tab = widgets.tabs[name];
        if (!tab)
            return false;
        var on = action === "ouvrir" ? true
               : action === "fermer" ? false
               : !widgets.isOpen(name);
        if (on)
            widgets.show(tab);
        else if (widgets.panelTab === tab)
            widgets.panelOpen = false;
        return true;
    }

    function closeAll() {
        widgets.panelOpen = false;
    }
}
