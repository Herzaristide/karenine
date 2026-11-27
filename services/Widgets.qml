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
// chacun mène à un onglet du panneau (`tabs`) ou à un volet de la barre du
// bas (`pops`, que la barre ouvre sous son bouton : `popRequested`).
Singleton {
    id: widgets

    readonly property var names: ["explorer", "stats", "agenda", "lecteur", "musique", "claude", "reglages",
        "son", "micro", "wifi", "bluetooth", "telephone", "notifications", "energie", "alimentation", "taches",
        "applications"]

    // Le nom donné par le pilote → l'onglet du panneau. Les anciens noms
    // (« metronome », « network »…) mènent à l'onglet qui les contient
    // aujourd'hui.
    readonly property var tabs: ({
        explorer: "files", stats: "system", agenda: "agenda", lecteur: "music", musique: "music",
        claude: "claude", reglages: "settings",
        metronome: "music", accordeur: "music", network: "system"
    })

    // Le nom donné par le pilote → le volet de la barre (Bar.qml `pop`).
    readonly property var pops: ({
        son: "sound", micro: "mic", wifi: "wifi", bluetooth: "bluetooth", telephone: "phone",
        notifications: "notifications", energie: "energy", alimentation: "power", taches: "tasks",
        applications: "apps"
    })
    // action : "ouvrir", "fermer" ou "basculer" ; la barre l'applique.
    signal popRequested(string pop, string action)

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
    // Le second dossier en arborescence (par défaut) plutôt qu'en liste.
    property bool explorerSplitTree: true
    // L'affichage de l'Explorer : "grid" (les tuiles, qui vont à la ligne),
    // "list" (nom, taille, date) ou "tree" (l'arborescence, comme la barre
    // latérale d'un IDE : les dossiers se déplient sur place).
    property string explorerView: "grid"
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

    // Le mode de l'onglet Agenda ("day", "three", "week", "month" ou "tasks"), gardé
    // d'une ouverture à l'autre.
    property string agendaView: "three"
    // Une tâche que l'onglet Agenda doit ouvrir dans son éditeur, venue du
    // volet des tâches de la barre : { task, tick }. CalendarWidget la prend
    // et la remet à null, à son chargement si l'onglet n'existait pas encore.
    property var agendaRequest: null

    // L'onglet Agenda, sur la liste des tâches ; sur l'une d'elles, ouverte
    // dans l'éditeur, si `task` est donnée.
    function showTasks(task) {
        widgets.agendaView = "tasks";
        widgets.agendaRequest = task ? { task: task, tick: Date.now() } : null;
        widgets.show("agenda");
    }

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
        var pop = widgets.pops[name];
        if (pop) {
            widgets.popRequested(pop, action || "basculer");
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

    // Un chemin que l'Explorer doit montrer, venu d'ailleurs (la FIFO :
    // « explorer:dossier:<chemin> » ou « explorer:fichier:<chemin> »,
    // qu'écrit karenine-open, l'application XDG des dossiers) : un dossier,
    // on y va ; un fichier, on va dans le sien et on l'y sélectionne.
    // { path, isDir, tick } ; FileExplorer la prend et la remet à null, à
    // son chargement si l'onglet n'existait pas encore. Le tick fait
    // repartir la même demande deux fois de suite.
    property var explorerRequest: null
    function explorerShow(path, isDir) {
        // Le chemin est local : l'Explorer quitte le serveur monté (la
        // machine choisie est la même pour l'onglet Système).
        if (widgets.machine !== null)
            widgets.machine = null;
        widgets.explorerRequest = { path: path, isDir: isDir, tick: Date.now() };
        widgets.show("files");
    }

    // Un disque à montrer (l'onglet Système) : sa machine ("" ici ; un
    // serveur, l'Explorer le monte) et son point de montage. Même demande
    // que explorerShow, prise par FileExplorer.openDisk.
    function explorerShowDisk(machine, host, mount) {
        widgets.explorerRequest = { disk: { machine: machine, host: host, main: mount }, tick: Date.now() };
        widgets.show("files");
    }

    // ── Le sélecteur de fichiers des applications ───────────────
    // Le portail FileChooser (xdg-desktop-portal-termfilechooser) lance
    // karenine-pick, qui écrit « explorer:choisir:<json> » sur la FIFO :
    //   { mode: "open" | "dir" | "save", multiple, path, reply }
    // `path` : le dossier de départ (open, dir) ou le fichier proposé
    // (save : son dossier, et son nom dans le champ). `reply` : une FIFO où
    // karenine-pick attend les chemins choisis, un par ligne ; rien du tout
    // vaut annulation. L'Explorer passe en mode choix tant que
    // `explorerPick` n'est pas null ; fermer le panneau, ou changer
    // d'onglet, annule.
    property var explorerPick: null
    // Le panneau était fermé quand le choix l'a ouvert : il se referme après.
    property bool pickOpenedPanel: false

    function explorerPickStart(req) {
        // `done` : une fonction du shell (ClaudeChat), au lieu d'une FIFO.
        if (!req || !(req.reply || req.done) || ["open", "dir", "save"].indexOf(req.mode) < 0)
            return;
        // Une demande encore en cours : annulée, la nouvelle passe devant.
        if (widgets.explorerPick)
            widgets.explorerPickFinish([]);
        var start = req.path || "";
        var name = "";
        if (req.mode === "save" && start !== "") {
            var slash = start.lastIndexOf("/");
            name = start.substring(slash + 1);
            start = slash > 0 ? start.substring(0, slash) : "/";
        }
        widgets.pickOpenedPanel = !widgets.panelOpen;
        widgets.explorerPick = { mode: req.mode, multiple: req.multiple === true,
                                 reply: req.reply || "", done: req.done || null, name: name };
        if (start.startsWith("/"))
            widgets.explorerShow(start, true);
        else
            widgets.show("files");
    }

    // Rend les chemins choisis (aucun : annulé) à karenine-pick.
    function explorerPickFinish(paths) {
        var pick = widgets.explorerPick;
        if (!pick)
            return;
        widgets.explorerPick = null;
        if (pick.done) {
            widgets.pickOpenedPanel = false;
            pick.done(paths);
            return;
        }
        var text = paths.filter(p => p.indexOf("\n") < 0).map(p => p + "\n").join("");
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" > \"$2\"", "--", text, pick.reply]);
        if (widgets.pickOpenedPanel)
            widgets.panelOpen = false;
        widgets.pickOpenedPanel = false;
    }

    onPanelOpenChanged: if (!widgets.panelOpen) widgets.explorerPickFinish([])
    onPanelTabChanged: if (widgets.panelTab !== "files") widgets.explorerPickFinish([])
}
