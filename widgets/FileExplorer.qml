pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "../services"

// L'onglet « Explorer » : les dossiers du PC, sans quitter la barre. À
// gauche, les favoris (le dossier personnel, ses dossiers, et /etc/nixos) ; à
// droite, la navigation (précédent, suivant, parent), le chemin, et le
// contenu du dossier, les dossiers d'abord : en tuiles, ou en liste avec la
// taille et la date, au choix. En bas, combien
// d'éléments, la sélection, et l'affichage.
//
//   (▣ zola  ▾)  (←)(→)(↑) ( ▭ ~ › ciph3r › karenine       ✎ ) (⌕)
//   ╭──────────╮ ╭─────────────────────────────────────────────╮
//   │ ▭ ciph3r │ │  ▭      ▭      ▭      ≡      ▣             │
//   │ ▭ Docum… │ │  ai     anna   docs   flake  logo          │
//   │ …        │ ╰─────────────────────────────────────────────╯
//   │ ❄ nixos  │  12 éléments                 (◉) (▦) (▭) (>_)
//   ╰──────────╯
//
// Le chemin s'édite : un clic dessus (à côté des segments), Ctrl+L, ou
// « / » et « ~ » tapés dans la liste. On y tape un chemin absolu, relatif,
// avec ~ ou .. ; les entrées du dossier tapé sont proposées dessous, Tab
// complète (le préfixe commun, puis chaque proposition), ↑ ↓ choisissent,
// Entrée y va (un fichier : son dossier, lui sélectionné), Échap annule.
// La loupe (Ctrl+F) change la barre en filtre du dossier. Alt+← → ↑ et
// les boutons latéraux de la souris parcourent l'historique.
//
// Comme dans un gestionnaire de fichiers : un clic sélectionne, Ctrl+clic
// ajoute ou retire, Maj+clic prend une plage, un clic dans le vide
// désélectionne ; un double clic entre dans le dossier, ou ouvre le
// fichier (xdg-open) et renvoie la barre. Glisser une tuile vers une autre
// application (text/uri-list) emporte toute la sélection si elle en fait
// partie ; la barre s'efface une fois déposé. Au clavier, une fois la
// grille atteinte (Tab) : les flèches promènent le curseur (Maj : étendent
// la sélection), Espace ajoute ou retire, Ctrl+A prend tout, Entrée ouvre,
// Échap désélectionne, Retour arrière remonte, et taper les premières
// lettres d'un nom y saute. Le bouton « précédent » de la souris remonte
// aussi. Le dossier est gardé d'un onglet à l'autre (Widgets.explorerPath).
//
// Au-dessus des favoris, la machine parcourue : celle-ci, ou un serveur du
// tailnet (la liste d'anna), la même que dans l'onglet Système. Un serveur se monte
// par sshfs et l'Explorer y montre ses dossiers comme les locaux ; ses
// favoris sont ceux de son dossier personnel et sa config NixOS.
// En bas, sur toute la largeur, les disques de la machine montrée et leur
// remplissage.
Item {
    id: root

    // Un fichier, ou un dossier dans le gestionnaire de fichiers, vient
    // d'être ouvert : la barre peut partir.
    signal opened()

    // La machine montrée : null pour celle-ci, sinon un serveur monté par
    // sshfs ({ name, host, mount, home, nixos }, cf. connect). Tout le reste
    // ne voit que des chemins locaux, sous le point de montage : naviguer,
    // ouvrir, glisser vers une application marchent pareil à distance.
    readonly property var machine: Widgets.explorerMachine
    // Dans onMachineChanged, `remote` n'est pas encore recalculé : ce qui y
    // touche à la machine teste `machine` lui-même.
    readonly property bool remote: root.machine !== null
    // Le haut de l'arborescence (on ne remonte pas au-dessus) et le dossier
    // personnel, sur la machine montrée.
    readonly property string rootDir: root.machine ? root.machine.mount : "/"
    readonly property string home: root.machine ? root.machine.mount + root.machine.home
                                               : root.localHome
    readonly property string localHome: Quickshell.env("HOME") || "/"
    readonly property string path: Widgets.explorerPath || root.home
    property bool showHidden: false
    // Le tri : 0 le nom, 1 la taille, 2 la date ; et dans quel sens.
    property int sortKey: 0
    property bool sortReversed: false
    // La liste plutôt que les tuiles (qui vont à la ligne), au choix, même
    // étroit : le bouton du pied passe de l'une à l'autre.
    readonly property bool listView: Widgets.explorerListView
    // La taille et la date, en liste, quand il y a la place.
    readonly property bool details: root.listView && content.width >= 340
    readonly property int sizeW: 58
    readonly property int dateW: 78

    readonly property int placesW: 150
    // Étroit (le panneau de droite) : les favoris passent en rangée de
    // pastilles au-dessus, les disques
    // s'empilent. Large (le hub), tout reste côte à côte.
    readonly property bool compact: root.width < 600
    readonly property int sideW: root.compact ? 0 : root.placesW + 12
    readonly property int headerH: 34
    readonly property int footerH: 30
    readonly property int switchH: 34
    // La bande des disques, en bas sur toute la largeur (rien sans disque).
    readonly property int diskH: 46
    readonly property int diskSpace: root.disks.length === 0 ? 0
                                   : root.compact ? root.disks.length * (root.diskH + 8) + 2
                                   : root.diskH + 10

    // Un chemin en URL « file:// », chaque segment encodé.
    function urlOf(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/");
    }
    function pathOf(u) {
        var s = u.toString();
        return decodeURIComponent(s.indexOf("file://") === 0 ? s.substring(7) : s);
    }
    function parentOf(p) {
        var slash = p.lastIndexOf("/");
        return slash > 0 ? p.substring(0, slash) : "/";
    }

    // 1536 → « 1,5 Ko » ; une décimale sous 10.
    function humanSize(bytes) {
        var units = [n => I18n.tr("unit.bytes", { n: n }), n => I18n.tr("unit.kb", { n: n }),
                     n => I18n.tr("unit.mb", { n: n }), n => I18n.tr("unit.gb", { n: n }),
                     n => I18n.tr("unit.tb", { n: n })];
        var v = Number(bytes);
        var i = 0;
        while (v >= 1024 && i < units.length - 1) {
            v /= 1024;
            i++;
        }
        var n = i === 0 ? String(Math.round(v)) : v.toLocaleString(I18n.locale, "f", v < 10 ? 1 : 0);
        return units[i](n);
    }

    // Aujourd'hui : l'heure ; cette année : le jour et le mois ; avant :
    // l'année aussi.
    function shortDate(d) {
        // Le store Nix date tout de 1970 : rien à en dire.
        if (!d || isNaN(d.getTime()) || d.getTime() < 86400000)
            return "—";
        var now = new Date();
        if (d.toDateString() === now.toDateString())
            return Qt.formatTime(d, "HH:mm");
        return d.toLocaleDateString(I18n.locale, d.getFullYear() === now.getFullYear() ? "d MMM" : "d MMM yyyy");
    }

    // Aller au dossier `p`, en le notant dans l'historique (sauf depuis
    // l'historique lui-même : `fromHistory`).
    function go(p, fromHistory) {
        if (p === root.path)
            return;
        if (!fromHistory) {
            root.backStack = root.backStack.concat([root.path]).slice(-64);
            root.forwardStack = [];
        }
        Widgets.explorerPath = p;
        root.clearSelection();
        root.filter = "";
        root.filterOpen = false;
        filterInput.text = "";
        grid.currentIndex = -1;
        grid.positionViewAtBeginning();
    }

    // ── L'historique ─────────────────────────────────────────────
    // Les dossiers d'avant et ceux quittés en revenant ; vidés en changeant
    // de machine (leurs chemins n'y voudraient plus rien dire).
    property var backStack: []
    property var forwardStack: []

    function back() {
        if (root.backStack.length === 0)
            return;
        var p = root.backStack[root.backStack.length - 1];
        root.backStack = root.backStack.slice(0, -1);
        root.forwardStack = root.forwardStack.concat([root.path]);
        root.go(p, true);
    }
    function forward() {
        if (root.forwardStack.length === 0)
            return;
        var p = root.forwardStack[root.forwardStack.length - 1];
        root.forwardStack = root.forwardStack.slice(0, -1);
        root.backStack = root.backStack.concat([root.path]);
        root.go(p, true);
    }

    // ── Le contenu, filtré ───────────────────────────────────────
    // Ce que montre la liste : le dossier lu par FolderListModel, réduit aux
    // noms qui contiennent le filtre (ses nameFilters laisseraient passer
    // les dossiers). Relu à chaque changement du dossier, groupé par
    // Qt.callLater ; le défilement et le curseur restent si c'est le même
    // dossier qui a bougé sur le disque.
    property var entries: []
    property string filter: ""
    // La loupe ouverte, même vide.
    property bool filterOpen: false
    readonly property bool filtering: root.filterOpen || root.filter !== ""
    property string entriesPath: ""
    // Un fichier à sélectionner dès qu'il apparaîtra (cf. reveal).
    property string pendingReveal: ""

    onFilterChanged: Qt.callLater(root.rebuildEntries)
    onShowHiddenChanged: Qt.callLater(root.rebuildEntries)

    function rebuildEntries() {
        var f = root.filter.toLowerCase();
        var out = [];
        for (var i = 0; i < folder.count; i++) {
            var name = String(folder.get(i, "fileName"));
            if (f !== "" && name.toLowerCase().indexOf(f) < 0)
                continue;
            out.push({
                name: name,
                path: folder.get(i, "filePath"),
                isDir: folder.get(i, "fileIsDir"),
                suffix: folder.get(i, "fileSuffix"),
                size: folder.get(i, "fileSize"),
                modified: folder.get(i, "fileModified")
            });
        }
        var same = root.entriesPath === root.path;
        var y = grid.contentY;
        var cur = grid.currentIndex;
        root.entries = out;
        root.entriesPath = root.path;
        if (same) {
            grid.contentY = Math.min(y, Math.max(0, grid.contentHeight - grid.height));
            grid.currentIndex = Math.min(cur, out.length - 1);
        } else {
            grid.currentIndex = -1;
        }
        if (root.pendingReveal !== "")
            root.applyReveal();
    }

    // Montrer le fichier `p` : aller dans son dossier, l'y sélectionner.
    function reveal(p) {
        root.pendingReveal = p;
        if (root.parentOf(p) === root.path)
            root.applyReveal();
        else
            root.go(root.parentOf(p));
    }
    function applyReveal() {
        for (var i = 0; i < root.entries.length; i++) {
            if (root.entries[i].path === root.pendingReveal) {
                root.pendingReveal = "";
                root.selectOnly(i);
                grid.currentIndex = i;
                return;
            }
        }
    }

    function sortBy(key) {
        if (root.sortKey === key)
            root.sortReversed = !root.sortReversed;
        else {
            root.sortKey = key;
            root.sortReversed = false;
        }
    }

    function focusGrid() {
        grid.forceActiveFocus();
        if (grid.currentIndex < 0 && grid.count > 0)
            grid.currentIndex = 0;
    }

    function openFilter() {
        root.filterOpen = true;
        filterInput.forceActiveFocus();
        filterInput.selectAll();
    }
    function closeFilter() {
        root.filter = "";
        filterInput.text = "";
        root.filterOpen = false;
        root.focusGrid();
    }

    // ── Le chemin, tapé ──────────────────────────────────────────
    // Ce qu'on tape se lit comme dans un shell, sur la machine montrée :
    // « ~ » son dossier personnel, « / » sa racine, le reste relatif au
    // dossier ouvert ; « . » et « .. » se résolvent sans sortir de la
    // racine (à distance, du point de montage).
    property bool editing: false
    property bool addressError: false
    // Les propositions : les entrées du dossier tapé dont le nom commence
    // par ce qui suit le dernier « / » (puis celles qui le contiennent).
    property var suggestions: []   // [{ name, path, isDir, suffix, at }]
    property int suggestIndex: -1
    // Le texte jusqu'au dernier « / » compris, et ce qui le suit.
    property string suggestDirText: ""
    property string suggestBase: ""
    // Le dossier lu pour les propositions ("" : aucune).
    property string suggestDir: ""
    readonly property int suggestMax: 8

    // Un chemin local en ce qu'on taperait : ~ pour le dossier personnel,
    // sans le point de montage à distance.
    function displayPath(p) {
        if (p === root.home)
            return "~";
        if (p.indexOf(root.home + "/") === 0)
            return "~" + p.substring(root.home.length);
        return root.remote ? root.remotePath(p) : p;
    }

    // Ce qu'on a tapé, en chemin local (sous le point de montage à distance).
    function resolve(t) {
        t = t.trim();
        var home = root.remote ? root.machine.home : root.localHome;
        var cur = root.remote ? root.remotePath(root.path) : root.path;
        var v;
        if (t === "")
            v = cur;
        else if (t === "~" || t.indexOf("~/") === 0)
            v = home + t.substring(1);
        else if (t.charAt(0) === "/")
            v = t;
        else
            v = cur + "/" + t;
        var parts = [];
        v.split("/").forEach(s => {
            if (s === "" || s === ".")
                return;
            if (s === "..")
                parts.pop();
            else
                parts.push(s);
        });
        var abs = "/" + parts.join("/");
        return root.remote ? (abs === "/" ? root.rootDir : root.rootDir + abs) : abs;
    }

    // Ouvre la barre à l'édition : sur le chemin courant tout sélectionné
    // (taper le remplace), ou sur `text` (« / » ou « ~ » tapés dans la liste).
    function startEditing(text) {
        root.editing = true;
        root.addressError = false;
        pathInput.forceActiveFocus();
        if (text) {
            pathInput.text = text;
            pathInput.cursorPosition = text.length;
            root.pathEdited(text);
        } else {
            var shown = root.displayPath(root.path);
            pathInput.text = shown + (shown.charAt(shown.length - 1) === "/" ? "" : "/");
            pathInput.selectAll();
            root.suggestDir = "";
            root.suggestions = [];
            root.suggestIndex = -1;
        }
    }
    // `back` : rendre le clavier à la liste (Échap).
    function finishEditing(back) {
        root.editing = false;
        root.addressError = false;
        root.suggestions = [];
        root.suggestIndex = -1;
        root.suggestDir = "";
        if (back)
            root.focusGrid();
    }

    function pathEdited(t) {
        var slash = t.lastIndexOf("/");
        root.suggestDirText = slash >= 0 ? t.substring(0, slash + 1) : "";
        root.suggestBase = t.substring(slash + 1);
        // « ~ » ou « ~nom » : pas encore un dossier à lire.
        root.suggestDir = t.charAt(0) === "~" && slash < 0 ? "" : root.resolve(root.suggestDirText);
        root.addressError = false;
        root.suggestIndex = -1;
        Qt.callLater(root.rebuildSuggestions);
    }

    function rebuildSuggestions() {
        if (!root.editing || root.suggestDir === ""
                || root.pathOf(suggestModel.folder) !== root.suggestDir) {
            root.suggestions = [];
            return;
        }
        var b = root.suggestBase.toLowerCase();
        var hidden = root.showHidden || b.charAt(0) === ".";
        var starts = [];
        var inside = [];
        for (var i = 0; i < suggestModel.count && starts.length < root.suggestMax; i++) {
            var name = String(suggestModel.get(i, "fileName"));
            if (!hidden && name.charAt(0) === ".")
                continue;
            var at = name.toLowerCase().indexOf(b);
            if (at < 0 || (at > 0 && b === ""))
                continue;
            var e = { name: name, path: suggestModel.get(i, "filePath"),
                      isDir: suggestModel.get(i, "fileIsDir"), suffix: suggestModel.get(i, "fileSuffix"), at: at };
            if (at === 0)
                starts.push(e);
            else if (inside.length < root.suggestMax)
                inside.push(e);
        }
        root.suggestions = starts.concat(inside).slice(0, root.suggestMax);
        if (root.suggestIndex >= root.suggestions.length)
            root.suggestIndex = -1;
    }

    // Le nom d'une proposition, la partie tapée en gras (StyledText).
    function highlight(name, at, len) {
        var esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        if (len === 0)
            return esc(name);
        return esc(name.substring(0, at)) + "<b>" + esc(name.substring(at, at + len)) + "</b>"
             + esc(name.substring(at + len));
    }

    function takeSuggestion(i) {
        var s = root.suggestions[i];
        if (!s)
            return;
        var t = root.suggestDirText + s.name + (s.isDir ? "/" : "");
        pathInput.text = t;
        pathInput.cursorPosition = t.length;
        // Un fichier : le texte est complet, plus rien à proposer.
        if (s.isDir)
            root.pathEdited(t);
        else
            root.suggestions = [];
    }

    // Tab : la proposition choisie ; sinon le préfixe commun des noms qui
    // commencent par ce qu'on a tapé ; s'il n'ajoute rien, on parcourt les
    // propositions (Maj+Tab à rebours).
    function complete(backwards) {
        var n = root.suggestions.length;
        if (n === 0)
            return;
        if (n === 1) {
            root.takeSuggestion(0);
            return;
        }
        if (root.suggestIndex < 0) {
            var pre = root.suggestions.filter(s => s.at === 0).map(s => s.name);
            if (pre.length > 0) {
                var common = pre[0];
                pre.forEach(name => {
                    var k = 0;
                    while (k < common.length && k < name.length
                           && common.charAt(k).toLowerCase() === name.charAt(k).toLowerCase())
                        k++;
                    common = common.substring(0, k);
                });
                if (common.length > root.suggestBase.length) {
                    var t = root.suggestDirText + common;
                    pathInput.text = t;
                    pathInput.cursorPosition = t.length;
                    root.pathEdited(t);
                    return;
                }
            }
        }
        root.suggestIndex = backwards ? (root.suggestIndex <= 0 ? n - 1 : root.suggestIndex - 1)
                                      : (root.suggestIndex + 1) % n;
    }

    // Entrée : la proposition choisie, ou le chemin tapé, s'il existe.
    function acceptPath() {
        if (root.suggestIndex >= 0) {
            var s = root.suggestions[root.suggestIndex];
            root.finishEditing(true);
            if (s.isDir)
                root.go(s.path);
            else
                root.reveal(s.path);
            return;
        }
        checkProc.target = root.resolve(pathInput.text);
        checkProc.typed = pathInput.text;
        checkProc.running = true;
    }

    // Ce qu'est le chemin tapé : un dossier (d), autre chose (f), ou rien.
    Process {
        id: checkProc
        property string target: ""
        property string typed: ""
        command: ["sh", "-c", "if [ -d \"$1\" ]; then echo d; elif [ -e \"$1\" ]; then echo f; fi",
                  "--", checkProc.target]
        stdout: StdioCollector {
            id: checkOut
            onStreamFinished: {
                if (!root.editing)
                    return;
                var kind = checkOut.text.trim();
                if (kind === "d" || kind === "f") {
                    root.finishEditing(true);
                    if (kind === "d")
                        root.go(checkProc.target);
                    else
                        root.reveal(checkProc.target);
                } else {
                    root.addressError = true;
                    shake.restart();
                    root.say(I18n.tr("explorer.notFound", { path: checkProc.typed.trim() }));
                }
            }
        }
    }

    FolderListModel {
        id: suggestModel
        folder: root.suggestDir !== "" ? root.urlOf(root.suggestDir) : ""
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: true
        sortField: FolderListModel.Name
        sortCaseSensitive: false
        onCountChanged: Qt.callLater(root.rebuildSuggestions)
        onStatusChanged: Qt.callLater(root.rebuildSuggestions)
    }

    // ── La sélection ─────────────────────────────────────────────
    // Par chemin plutôt que par index : l'ordre du modèle bouge (fichiers
    // cachés montrés, dossier qui change sur le disque). Réaffectée en
    // entier à chaque changement pour que les liaisons suivent.
    property var selection: ({})
    readonly property var selectedPaths: Object.keys(root.selection)
    readonly property int selectedCount: root.selectedPaths.length
    // Ce que pèsent les fichiers sélectionnés (les dossiers ne comptent pas).
    readonly property real selectedSize: {
        var total = 0;
        root.entries.forEach(e => {
            if (!e.isDir && root.selection[e.path] === true)
                total += e.size;
        });
        return total;
    }
    // Le point de départ d'une plage (Maj+clic, Maj+flèches).
    property int anchorIndex: -1

    function isSelected(p) {
        return root.selection[p] === true;
    }
    function clearSelection() {
        root.selection = ({});
        root.anchorIndex = -1;
    }
    function toggle(index) {
        var p = root.entries[index].path;
        var s = Object.assign({}, root.selection);
        if (s[p])
            delete s[p];
        else
            s[p] = true;
        root.selection = s;
        root.anchorIndex = index;
    }
    function selectOnly(index) {
        var s = {};
        s[root.entries[index].path] = true;
        root.selection = s;
        root.anchorIndex = index;
    }
    // De l'ancre à `index`, à la place de la sélection en cours.
    function selectRange(index) {
        var from = root.anchorIndex < 0 ? index : root.anchorIndex;
        var s = {};
        for (var i = Math.min(from, index); i <= Math.max(from, index) && i < root.entries.length; i++)
            s[root.entries[i].path] = true;
        root.selection = s;
        root.anchorIndex = from;
    }
    function selectAll() {
        var s = {};
        for (var i = 0; i < root.entries.length; i++)
            s[root.entries[i].path] = true;
        root.selection = s;
    }

    // Ce que porte un glisser parti de ce chemin : toute la sélection s'il
    // en fait partie, lui seul sinon.
    function dragPaths(p) {
        return root.isSelected(p) ? root.selectedPaths : [p];
    }

    // Entrée sur plusieurs éléments : chacun dans son application.
    function openSelection() {
        for (var i = 0; i < root.selectedPaths.length; i++)
            Quickshell.execDetached(["xdg-open", root.selectedPaths[i]]);
        root.clearSelection();
        root.opened();
    }

    // ── L'envoi au téléphone ─────────────────────────────────────
    // Les fichiers sélectionnés partent vers le téléphone appairé avec KDE
    // Connect (anna phone share, un à la fois), comme un dépôt sur la carte
    // de l'onglet Téléphone. Les dossiers restent : KDE Connect n'envoie que
    // des fichiers. Le téléphone n'est suivi (phone_watch) que tant qu'il y a
    // une sélection à lui envoyer : le premier appairé et à portée.
    property var phone: null
    // Le retour du dernier envoi, dans la pastille du bas, effacé seul.
    property string notice: ""

    Socket {
        id: phoneSock
        path: Anna.socketPath
        connected: root.visible && root.selectedCount > 0
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg.phone === undefined)
                        return;
                    var found = null;
                    (msg.phone.phones || []).forEach(p => {
                        if (!found && p.paired && p.reachable)
                            found = p;
                    });
                    root.phone = found;
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"phone_watch"}\n');
            else
                root.phone = null;
        }
    }

    function sendToPhone() {
        // Un envoi en cours : il finit d'abord.
        if (shareProc.running || shareProc.pending.length > 0)
            return;
        if (!root.phone) {
            root.say(I18n.tr("explorer.noPhone"));
            return;
        }
        var files = [];
        root.entries.forEach(e => {
            if (root.isSelected(e.path) && !e.isDir)
                files.push(e.path);
        });
        if (files.length === 0) {
            root.say(I18n.tr("explorer.onlyFiles"));
            return;
        }
        shareProc.device = root.phone.id;
        shareProc.name = root.phone.name;
        shareProc.pending = files;
        shareProc.sent = 0;
        shareProc.failure = "";
        root.say(I18n.trn("explorer.sending", files.length, { name: root.phone.name }));
        shareProc.next();
    }

    Process {
        id: shareProc
        property string device: ""
        property string name: ""
        property var pending: []
        property int sent: 0
        property string failure: ""
        stdout: StdioCollector { id: shareOut }

        function next() {
            if (shareProc.pending.length === 0) {
                root.say(shareProc.failure !== ""
                         ? shareProc.failure
                         : I18n.trn("explorer.phoneSent", shareProc.sent, { name: shareProc.name }));
                return;
            }
            shareProc.command = ["anna", "phone", "share", shareProc.device, shareProc.pending[0]];
            shareProc.pending = shareProc.pending.slice(1);
            shareProc.running = true;
        }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(shareOut.text);
                if (r.ok)
                    shareProc.sent++;
                else
                    shareProc.failure = r.error || I18n.tr("common.failedSentence");
            } catch (e) {
                shareProc.failure = I18n.tr("anna.noAnswer");
            }
            Qt.callLater(shareProc.next);
        }
    }

    function say(text) {
        root.notice = text;
        noticeTimer.restart();
    }
    Timer {
        id: noticeTimer
        interval: 3500
        onTriggered: root.notice = ""
    }

    function up() {
        if (root.path !== root.rootDir)
            root.go(root.parentOf(root.path));
    }

    function activate(index) {
        if (index < 0 || index >= root.entries.length)
            return;
        var p = root.entries[index].path;
        if (root.entries[index].isDir) {
            root.go(p);
            // Au clavier, la sélection reprend en haut du nouveau dossier.
            if (grid.activeFocus)
                grid.currentIndex = 0;
            return;
        }
        Quickshell.execDetached(["xdg-open", p]);
        root.opened();
    }

    // ── Les icônes ───────────────────────────────────────────────
    // Celles du thème d'icônes installé (Reversal-Accent, cf. Theme.icon) :
    // dossiers et lieux recolorés à l'accent par anna, types de fichiers
    // tels que le thème les dessine. Chaque type donne ses noms du plus
    // précis au plus générique ; si le thème n'en a aucun (pas d'anna, pas
    // de thème), l'icône de assets/icons (Phosphor) du même type, teinte.
    readonly property var imageSuffixes: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
    readonly property var suffixIcons: ({
        pdf: [["application-pdf"], "file-pdf"],
        mp3: [["audio-mpeg", "audio-x-mpeg", "audio-x-generic"], "file-audio"],
        flac: [["audio-flac", "audio-x-flac", "audio-x-generic"], "file-audio"],
        wav: [["audio-x-wav", "audio-x-generic"], "file-audio"],
        ogg: [["audio-x-vorbis+ogg", "audio-x-generic"], "file-audio"],
        opus: [["audio-x-generic"], "file-audio"],
        m4a: [["audio-x-m4a", "audio-x-generic"], "file-audio"],
        mp4: [["video-mp4", "video-x-generic"], "file-video"],
        mkv: [["video-x-matroska", "video-x-generic"], "file-video"],
        webm: [["video-webm", "video-x-generic"], "file-video"],
        mov: [["video-quicktime", "video-x-generic"], "file-video"],
        avi: [["video-x-msvideo", "video-x-generic"], "file-video"],
        zip: [["application-zip", "package-x-generic"], "file-archive"],
        tar: [["application-x-tar", "package-x-generic"], "file-archive"],
        gz: [["application-gzip", "package-x-generic"], "file-archive"],
        xz: [["application-x-xz", "package-x-generic"], "file-archive"],
        zst: [["application-x-zstd-compressed-tar", "package-x-generic"], "file-archive"],
        "7z": [["application-x-7z-compressed", "package-x-generic"], "file-archive"],
        rar: [["application-x-rar", "package-x-generic"], "file-archive"],
        png: [["image-png", "image-x-generic"], "file-image"],
        jpg: [["image-jpeg", "image-x-generic"], "file-image"],
        jpeg: [["image-jpeg", "image-x-generic"], "file-image"],
        gif: [["image-gif", "image-x-generic"], "file-image"],
        webp: [["image-webp", "image-x-generic"], "file-image"],
        bmp: [["image-bmp", "image-x-generic"], "file-image"],
        svg: [["image-svg+xml", "image-x-generic"], "file-image"],
        qml: [["text-x-qml", "text-x-script"], "file-code"],
        js: [["application-javascript", "text-x-javascript", "text-x-script"], "file-code"],
        ts: [["text-x-typescript", "text-x-script"], "file-code"],
        rs: [["text-x-rust", "text-x-script"], "file-code"],
        py: [["text-x-python", "text-x-script"], "file-code"],
        sh: [["application-x-shellscript", "text-x-script"], "file-code"],
        nix: [["text-x-nix", "text-x-script"], "file-code"],
        c: [["text-x-csrc", "text-x-script"], "file-code"],
        cpp: [["text-x-c++src", "text-x-script"], "file-code"],
        h: [["text-x-chdr", "text-x-script"], "file-code"],
        go: [["text-x-go", "text-x-script"], "file-code"],
        json: [["application-json", "text-x-script"], "file-code"],
        toml: [["application-toml", "text-x-script"], "file-code"],
        yaml: [["application-x-yaml", "text-x-script"], "file-code"],
        yml: [["application-x-yaml", "text-x-script"], "file-code"],
        css: [["text-css", "text-x-script"], "file-code"],
        html: [["text-html"], "file-html"],
        md: [["text-markdown", "text-x-markdown", "text-x-generic"], "file-text"],
        txt: [["text-plain", "text-x-generic"], "file-text"]
    })

    function glyph(name) {
        return "../assets/icons/" + name + ".svg";
    }
    // La première des icônes `names` que le thème connaît, sinon le glyphe
    // `fallback`.
    function themed(names, fallback) {
        for (var i = 0; i < names.length; i++) {
            var src = Theme.icon(names[i], true);
            if (src !== "")
                return src;
        }
        return root.glyph(fallback);
    }

    // Une image se montre elle-même (une URL file://) ; le reste prend
    // l'icône de son type dans le thème. Les dossiers XDG (Documents,
    // Musique…) gardent celle de leur favori, où qu'ils soient.
    function iconFor(p, isDir, suffix, name) {
        if (isDir) {
            var xdg = root.xdgByPath[p];
            return xdg ? root.xdgIcon(xdg) : root.themed(["folder"], "folder");
        }
        var s = (suffix || "").toLowerCase();
        // À distance, pas de miniature : chaque image traverserait le réseau.
        if (!root.remote && root.imageSuffixes.indexOf(s) !== -1)
            return root.urlOf(p);
        var known = root.suffixIcons[s];
        return known ? root.themed(known[0].concat(["text-x-generic", "unknown"]), known[1])
                     : root.themed(["text-x-generic", "unknown"], "file");
    }

    // ── Les favoris ──────────────────────────────────────────────
    // Le dossier personnel, les dossiers XDG de la machine montrée (ceux de
    // ~/.config/user-dirs.dirs, cf. xdg-user-dirs), puis la configuration
    // NixOS. Le dossier personnel ne s'allume que chez lui (`exact`) : il
    // engloberait les autres favoris.
    // Sur un serveur, sa configuration NixOS s'il en a une. Pas de favori
    // pour la racine : il engloberait tout le reste, donc resterait allumé ;
    // le disque « / » de la bande du bas, le chemin et ↑ y mènent.
    readonly property var extraPlaces: !root.remote
        ? [{ label: "nixos", icon: "../assets/nixos.svg", path: "/etc/nixos" }]
        : (root.machine.nixos ? [{ label: "nixos", icon: "../assets/nixos.svg", path: root.rootDir + "/etc/nixos" }] : [])

    // Les dossiers XDG, dans l'ordre des favoris : leur clé dans
    // user-dirs.dirs, les icônes du thème, le glyphe à défaut, et le nom
    // par défaut (anglais puis français) quand le fichier manque.
    readonly property var xdgKinds: [
        { key: "DOCUMENTS", icons: ["folder-documents"], glyph: "documents", names: ["Documents"] },
        { key: "DOWNLOAD", icons: ["folder-download", "folder-downloads"], glyph: "downloads",
          names: ["Downloads", "Téléchargements"] },
        { key: "PROJECTS", icons: ["folder-projects", "folder-development", "folder-code"], glyph: "projects",
          names: ["Projects", "Projets"] },
        { key: "PICTURES", icons: ["folder-pictures"], glyph: "pictures", names: ["Pictures", "Images"] },
        { key: "VIDEOS", icons: ["folder-videos"], glyph: "videos", names: ["Videos", "Vidéos"] },
        { key: "MUSIC", icons: ["folder-music"], glyph: "music", names: ["Music", "Musique"] },
        { key: "DESKTOP", icons: ["user-desktop", "folder-desktop"], glyph: "place-desktop",
          names: ["Desktop", "Bureau"] },
        { key: "PUBLICSHARE", icons: ["folder-publicshare"], glyph: "public", names: ["Public"] },
        { key: "TEMPLATES", icons: ["folder-templates"], glyph: "templates", names: ["Templates", "Modèles"] }
    ]
    function xdgIcon(kind) {
        return root.themed(kind.icons.concat(["folder"]), kind.glyph);
    }

    // user-dirs.dirs lu : clé → chemin local (sous le point de montage à
    // distance). null : pas de fichier, les noms par défaut servent.
    property var xdgDirs: null
    // Chemin → sa sorte XDG, pour les icônes de la liste aussi.
    property var xdgByPath: ({})
    property var places: root.extraPlaces

    FileView {
        id: userDirs
        path: root.home + "/.config/user-dirs.dirs"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parseUserDirs(userDirs.text())
        onLoadFailed: {
            root.xdgDirs = null;
            root.rebuildPlaces();
        }
    }
    // Une autre machine : son fichier à elle (le dossier personnel change).
    onHomeChanged: {
        root.xdgDirs = null;
        root.rebuildPlaces();
    }

    // Des lignes XDG_DOCUMENTS_DIR="$HOME/Documents" ; un dossier réglé sur
    // le dossier personnel lui-même est désactivé.
    function parseUserDirs(text) {
        var dirs = {};
        var homeVirt = root.remote ? root.machine.home : root.localHome;
        text.split("\n").forEach(line => {
            var m = line.match(/^\s*XDG_([A-Z]+)_DIR\s*=\s*"(.*)"\s*$/);
            if (!m)
                return;
            var v = m[2].replace(/^\$HOME/, homeVirt).replace(/\/+$/, "");
            if (v === "" || v === homeVirt || v.charAt(0) !== "/")
                return;
            dirs[m[1]] = root.remote ? root.rootDir + v : v;
        });
        root.xdgDirs = dirs;
        root.rebuildPlaces();
    }

    function rebuildPlaces() {
        // Les dossiers présents du dossier personnel (pour les noms par
        // défaut, et pour écarter un dossier XDG qui n'existe pas).
        var present = {};
        for (var i = 0; i < homeDirs.count; i++)
            present[homeDirs.get(i, "filePath")] = true;

        var out = [{ label: I18n.tr("explorer.home"), icon: root.themed(["user-home", "folder-home", "folder"], "folder"),
                     glyph: root.glyph("home"), path: root.home, exact: true }];
        var byPath = {};
        root.xdgKinds.forEach(kind => {
            var p = "";
            if (root.xdgDirs) {
                p = root.xdgDirs[kind.key] || "";
                // Sous le dossier personnel, il doit exister ; ailleurs, on
                // lui fait confiance.
                if (p !== "" && root.parentOf(p) === root.home && !present[p])
                    p = "";
            } else {
                for (var k = 0; k < kind.names.length && p === ""; k++)
                    if (present[root.home + "/" + kind.names[k]])
                        p = root.home + "/" + kind.names[k];
            }
            // Deux sortes sur un même dossier (Images et Vidéos) : un favori.
            if (p === "" || byPath[p])
                return;
            byPath[p] = kind;
            out.push({ label: p.substring(p.lastIndexOf("/") + 1), icon: root.xdgIcon(kind),
                       glyph: root.glyph(kind.glyph), path: p });
        });
        // Les autres clés du fichier (XDG_<NOM>_DIR ajoutés à la main ou par
        // home-manager, xdg.userDirs.extraConfig) : à la suite, en dossier.
        if (root.xdgDirs) {
            var knownKeys = root.xdgKinds.map(kind => kind.key);
            Object.keys(root.xdgDirs).sort().forEach(key => {
                var p = root.xdgDirs[key];
                if (knownKeys.indexOf(key) >= 0 || byPath[p]
                        || (root.parentOf(p) === root.home && !present[p]))
                    return;
                var kind = { key: key, icons: [], glyph: "folder" };
                byPath[p] = kind;
                out.push({ label: p.substring(p.lastIndexOf("/") + 1), icon: root.xdgIcon(kind),
                           glyph: root.glyph(kind.glyph), path: p });
            });
        }
        root.xdgByPath = byPath;
        root.places = out.concat(root.extraPlaces);
    }
    // Le thème recoloré (nouvel accent) : les URL des icônes changent.
    Connections {
        target: Theme
        function on_IconsChanged() { root.rebuildPlaces(); }
    }
    // La langue chargée (ou changée) : le libellé du dossier personnel suit.
    Connections {
        target: I18n
        function onDictsChanged() { root.rebuildPlaces(); }
        function onLangChanged() { root.rebuildPlaces(); }
    }

    FolderListModel {
        id: homeDirs
        folder: root.urlOf(root.home)
        showFiles: false
        showHidden: false
        showDotAndDotDot: false
        sortField: FolderListModel.Name
        sortCaseSensitive: false
        onCountChanged: root.rebuildPlaces()
        onStatusChanged: root.rebuildPlaces()
    }

    // ── Les machines ─────────────────────────────────────────────
    // Celle-ci, et les serveurs du tailnet qu'on atteint par ssh (la liste
    // d'anna). Un serveur se monte en entier
    // (sshfs, `host:/`) sous $XDG_RUNTIME_DIR/karenine-sshfs/<nom>, et y reste
    // tant qu'on ne passe pas à une autre machine : revenir sur l'onglet ne
    // coûte pas une nouvelle connexion. La liste des machines est celle du
    // sélecteur (MachinePicker).
    // Le serveur en cours de montage (son nom), ou "".
    property string connecting: ""
    property string error: ""

    readonly property string mountBase: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/karenine-sshfs"

    // Le chemin sur le serveur d'un chemin sous le point de montage.
    function remotePath(p) {
        return p.substring(root.rootDir.length) || "/";
    }
    function shellQuote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'";
    }

    function unmount(m) {
        if (m)
            Quickshell.execDetached(["fusermount3", "-uz", m.mount]);
    }

    function useLocal() {
        root.error = "";
        if (!root.remote)
            return;
        root.unmount(root.machine);
        root.clearSelection();
        Widgets.explorerMachine = null;
        Widgets.explorerPath = "";
    }

    // Rattrape la machine choisie (Widgets.machine), où qu'elle l'ait été :
    // ici, ou dans l'onglet Système pendant que l'Explorer était caché.
    function follow() {
        var m = Widgets.machine;
        if (!m)
            root.useLocal();
        else if (!(root.remote && root.machine.name === m.name) && root.connecting !== m.name)
            root.connect(m);
    }
    Connections {
        target: Widgets
        function onMachineChanged() { root.follow(); }
    }
    Component.onCompleted: root.follow()

    function connect(srv) {
        root.error = "";
        if (root.remote && root.machine.name === srv.name)
            return;
        root.connecting = srv.name;
        mountProc.server = srv;
        mountProc.mount = root.mountBase + "/" + srv.name;
        mountProc.command = ["sh", "-c", root.mountScript, "--", srv.host, mountProc.mount];
        mountProc.running = true;
        mountGuard.restart();
    }

    // Monte `host:/` s'il ne l'est pas déjà, puis dit le dossier personnel
    // du serveur et s'il a une configuration NixOS. BatchMode : un serveur
    // qui demanderait un mot de passe échoue au lieu d'attendre.
    readonly property string mountScript:
        "host=\"$1\"; mp=\"$2\"; mkdir -p \"$mp\" || exit 1; " +
        "if ! mountpoint -q \"$mp\"; then " +
        "  err=$(sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3," +
        "BatchMode=yes,ConnectTimeout=6,idmap=user \"$host:/\" \"$mp\" 2>&1) " +
        "  || { printf '%s\\n' \"$err\" | tail -n 1 >&2; exit 1; }; " +
        "fi; " +
        "ssh -o BatchMode=yes -o ConnectTimeout=6 \"$host\" " +
        "'printf \"%s\\n\" \"$HOME\"; test -d /etc/nixos && echo nixos'"

    Process {
        id: mountProc
        property var server: null
        property string mount: ""
        stdout: StdioCollector { id: mountOut }
        stderr: StdioCollector { id: mountErr }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            mountGuard.stop();
            var srv = mountProc.server;
            root.connecting = "";
            var lines = mountOut.text.trim().split("\n");
            if (code !== 0 || lines[0].length === 0) {
                // Le choix revient à la machine encore montrée, pour tous les
                // onglets : le sélecteur ne dit pas une machine qu'on ne voit pas.
                Widgets.machine = root.remote ? { name: root.machine.name, host: root.machine.host } : null;
                root.error = srv.name + " : " + (mountErr.text.trim().split("\n").pop()
                                                 || I18n.tr("explorer.cannotConnect"));
                return;
            }
            // Le serveur d'avant n'a plus de raison de rester monté.
            if (root.remote && root.machine.mount !== mountProc.mount)
                root.unmount(root.machine);
            root.clearSelection();
            Widgets.explorerMachine = {
                name: srv.name, host: srv.host, mount: mountProc.mount,
                home: lines[0], nixos: lines.indexOf("nixos") > 0
            };
            Widgets.explorerPath = mountProc.mount + lines[0];
            // Une autre machine choisie pendant le montage.
            root.follow();
        }
    }
    // Un serveur qui ne répond plus : on abandonne plutôt que d'attendre.
    Timer {
        id: mountGuard
        interval: 20000
        onTriggered: if (mountProc.running) mountProc.running = false
    }

    // ── Les disques ──────────────────────────────────────────────
    // Sous les favoris, les disques physiques de la machine montrée, avec
    // leur remplissage ; un clic va à leur point de montage principal. df
    // liste les systèmes de fichiers (sur btrfs, chaque sous-volume revient
    // avec la taille du volume entier), lsblk relie chacun à son disque :
    // chaque système de fichiers compte une fois, puis on additionne par
    // disque. Sur un serveur, ses disques viennent de son node_exporter, par
    // anna (servers_watch : `drives`, un relevé puis on raccroche) : pas de
    // ssh pour lire. Relu à l'affichage, au changement de machine et chaque
    // minute.
    property var disks: []   // [{ label, used, size, path }], en Go

    // -l : sans les systèmes de fichiers réseau, dont nos montages sshfs (un
    // serveur qui ne répond plus figerait df).
    readonly property string diskScript: "df -P -B1 -l; echo @@; lsblk -J -o NAME,PATH,TYPE,MODEL"

    function refreshDisks() {
        if (root.machine) {
            serverDisks.ask(root.machine.name, root.machine.mount);
            return;
        }
        // Un relevé en cours : celui-ci est refait juste après (sinon un
        // changement de machine pendant un relevé n'aurait plus de disques).
        if (diskProc.running) {
            diskProc.again = true;
            return;
        }
        diskProc.again = false;
        diskProc.mount = "";
        diskProc.command = ["sh", "-c", root.diskScript];
        diskProc.running = true;
    }

    // Les disques physiques d'un serveur, tels qu'anna les tient de son
    // node_exporter : un par disque, avec ce que ses systèmes de fichiers
    // occupent et leurs points de montage (le principal d'abord). Comme ici,
    // sans ceux qui ne portent que /boot ou /efi.
    function applyServerDisks(drives, mount) {
        var gib = 1024 * 1024 * 1024;
        var shown = m => m.indexOf("/boot") !== 0 && m.indexOf("/efi") !== 0 && m.indexOf("/nix/store") !== 0;
        root.disks = drives.filter(d => d.fs_size > 0 && (d.mounts || []).some(shown))
            .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
            .map(d => {
                var main = d.mounts.find(shown);
                // « Micron 3400 MTFDKBA1T0TFH » → « Micron 3400 ».
                var model = (d.model || "").trim().split(/\s+/).slice(0, 2).join(" ");
                return { label: model || d.name, used: Math.round(d.fs_used / gib),
                         size: Math.round(d.fs_size / gib), path: mount + (main === "/" ? "" : main) };
            });
    }

    // Un relevé d'anna pour le serveur montré : le premier message qui le
    // contient suffit, puis on raccroche (anna n'interroge que celui-ci).
    Socket {
        id: serverDisks
        property string name: ""
        property string mount: ""
        function ask(name, mount) {
            serverDisks.name = name;
            serverDisks.mount = mount;
            serverDisks.connected = false;
            serverDisks.connected = true;
        }
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    const s = (JSON.parse(line).servers || []).find(x => x.name === serverDisks.name);
                    if (!s)
                        return;
                    serverDisks.connected = false;
                    // La machine a changé entre-temps : son relevé suit.
                    if (serverDisks.mount !== (root.machine ? root.machine.mount : ""))
                        return;
                    // node_exporter n'a pas répondu : on garde ce qu'on
                    // montrait et on réessaie bientôt.
                    if (!s.online || !s.measured || s.error) {
                        diskRetry.restart();
                        return;
                    }
                    root.applyServerDisks(s.drives || [], serverDisks.mount);
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write(JSON.stringify({ cmd: "servers_watch", name: serverDisks.name }) + "\n");
        }
    }

    function applyDisks(text, mount) {
        var parts = text.split("@@");
        // lsblk : chemin de chaque source (partition, volume chiffré) → son disque.
        var devices = {};
        try {
            (JSON.parse(parts[1] || "{}").blockdevices || []).forEach(d => {
                if (d.type !== "disk" || d.name.indexOf("zram") === 0)
                    return;
                // « Micron_3400_MTFDKBA1T0TFH » → « Micron 3400 ».
                var info = { disk: d.name, model: (d.model || "").trim().replace(/_/g, " ")
                                                     .split(/\s+/).slice(0, 2).join(" ") };
                var walk = n => { devices[n.path] = info; (n.children || []).forEach(walk); };
                walk(d);
            });
        } catch (e) { /* lsblk absent : les sources seules */ }

        // df : un système de fichiers par source, au point de montage le plus
        // court ; seulement les vrais périphériques, sans /boot.
        var bySource = {};
        parts[0].split("\n").slice(1).forEach(line => {
            var f = line.trim().split(/\s+/);
            if (f.length < 6 || f[0].indexOf("/dev/") !== 0 || f[0].indexOf("/dev/loop") === 0)
                return;
            var mnt = f.slice(5).join(" ");
            if (mnt.indexOf("/boot") === 0 || mnt.indexOf("/efi") === 0 || mnt.indexOf("/nix/store") === 0)
                return;
            var prev = bySource[f[0]];
            if (!prev || mnt.length < prev.mount.length)
                bySource[f[0]] = { size: Number(f[1]), used: Number(f[2]), mount: mnt };
        });

        var byDisk = {};
        Object.keys(bySource).forEach(src => {
            var fs = bySource[src];
            var dev = devices[src];
            var key = dev ? dev.disk : src;
            var g = byDisk[key] || (byDisk[key] = {
                label: dev && dev.model ? dev.model : key.replace(/^\/dev\//, ""),
                used: 0, size: 0, mount: fs.mount
            });
            g.used += fs.used;
            g.size += fs.size;
            if (fs.mount.length < g.mount.length)
                g.mount = fs.mount;
        });
        var gib = 1024 * 1024 * 1024;
        root.disks = Object.keys(byDisk).sort().map(k => {
            var g = byDisk[k];
            return { label: g.label, used: Math.round(g.used / gib), size: Math.round(g.size / gib),
                     path: mount + (g.mount === "/" && mount !== "" ? "" : g.mount) };
        });
    }

    Process {
        id: diskProc
        // Le point de montage du serveur relevé ("" ici), pour ses chemins.
        property string mount: ""
        // Redemandé pendant qu'il tournait.
        property bool again: false
        stdout: StdioCollector {
            id: diskOut
            onStreamFinished: {
                // Un serveur choisi entre-temps : ses disques viennent d'anna.
                if (root.machine)
                    return;
                // Rien n'est revenu : on garde ce qu'on montrait et on
                // réessaie bientôt, plutôt que de vider la bande.
                if (diskOut.text.indexOf("@@") < 0) {
                    diskRetry.restart();
                    return;
                }
                root.applyDisks(diskOut.text, diskProc.mount);
            }
        }
        // Une fois le processus vraiment arrêté (dans `exited`, il compte
        // encore comme lancé et refreshDisks n'aurait rien fait).
        onRunningChanged: {
            if (!running && diskProc.again && !root.machine)
                Qt.callLater(root.refreshDisks);
        }
    }
    Timer {
        id: diskRetry
        interval: 5000
        onTriggered: if (root.visible) root.refreshDisks()
    }
    Timer {
        interval: 60000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshDisks()
    }
    onMachineChanged: {
        root.backStack = [];
        root.forwardStack = [];
        root.disks = [];
        root.refreshDisks();
    }

    // Le chemin, en segments cliquables : « ~ » pour le dossier personnel,
    // « / » pour la racine (celle du serveur, à distance : le point de
    // montage n'apparaît pas).
    readonly property var crumbs: {
        var p = root.path;
        var out = [];
        var base = root.rootDir === "/" ? "" : root.rootDir;
        if (p === root.home || p.indexOf(root.home + "/") === 0) {
            out.push({ label: "~", path: root.home });
            base = root.home;
        } else {
            out.push({ label: "/", path: root.rootDir });
        }
        var rest = p.substring(base.length).split("/").filter(s => s.length > 0);
        var acc = base;
        for (var i = 0; i < rest.length; i++) {
            acc += "/" + rest[i];
            out.push({ label: rest[i], path: acc });
        }
        return out;
    }

    FolderListModel {
        id: folder
        folder: root.urlOf(root.path)
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: root.showHidden
        sortField: root.sortKey === 1 ? FolderListModel.Size
                 : root.sortKey === 2 ? FolderListModel.Time : FolderListModel.Name
        sortReversed: root.sortReversed
        sortCaseSensitive: false
        onCountChanged: Qt.callLater(root.rebuildEntries)
        onStatusChanged: Qt.callLater(root.rebuildEntries)
    }
    // Un fichier renommé ou retouché sur le disque (le nombre ne bouge pas),
    // un autre tri : la liste se relit aussi.
    Connections {
        target: folder
        function onDataChanged() { Qt.callLater(root.rebuildEntries); }
        function onModelReset() { Qt.callLater(root.rebuildEntries); }
        function onRowsMoved() { Qt.callLater(root.rebuildEntries); }
    }

    // Les boutons « précédent » et « suivant » de la souris parcourent
    // l'historique.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.BackButton | Qt.ForwardButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.BackButton)
                root.back();
            else
                root.forward();
        }
    }

    // Les raccourcis de tout l'onglet : ce que la grille, le champ ou un
    // bouton n'a pas pris remonte jusqu'ici.
    Keys.onPressed: (event) => {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        var alt = (event.modifiers & Qt.AltModifier) !== 0;
        if ((ctrl && event.key === Qt.Key_L) || event.key === Qt.Key_F6)
            root.startEditing("");
        else if (ctrl && event.key === Qt.Key_F)
            root.openFilter();
        else if (ctrl && event.key === Qt.Key_H)
            root.showHidden = !root.showHidden;
        else if (alt && event.key === Qt.Key_Left)
            root.back();
        else if (alt && event.key === Qt.Key_Right)
            root.forward();
        else if (alt && event.key === Qt.Key_Up)
            root.up();
        else
            return;
        event.accepted = true;
    }

    // ── La machine, au-dessus des favoris ────────────────────────
    MachinePicker {
        width: root.compact ? root.width : root.placesW
        height: root.switchH
        busy: root.connecting
    }

    // Une icône du thème, en couleurs ; un glyphe de assets/icons, teint.
    component FileIcon: Item {
        id: fileIcon
        property string source
        property color tint: Theme.accentColor
        property real iconSize: 18
        // Un glyphe de assets/icons (cf. root.glyph), monochrome.
        readonly property bool glyph: fileIcon.source.indexOf("../assets/") === 0
        implicitWidth: fileIcon.iconSize
        implicitHeight: fileIcon.iconSize

        Image {
            anchors.fill: parent
            visible: !fileIcon.glyph
            source: fileIcon.glyph ? "" : fileIcon.source
            sourceSize.width: 64
            sourceSize.height: 64
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
        }
        NixIcon {
            anchors.fill: parent
            visible: fileIcon.glyph
            iconSize: fileIcon.iconSize
            source: fileIcon.glyph ? fileIcon.source : ""
            color: fileIcon.tint
        }
    }

    // ── Les favoris, à gauche ────────────────────────────────────
    // L'onglet entier prend la hauteur de ses favoris (cf. implicitHeight),
    // entre placesMin et placesMax rangées ; au-delà, la liste défile.
    readonly property int placeH: 33
    readonly property int placesMin: 6
    readonly property int placesMax: 12
    readonly property int shownPlaces: Math.max(root.placesMin, Math.min(root.placesMax, root.places.length))
    implicitHeight: root.switchH + 8 + root.shownPlaces * (root.placeH + 1) - 1 + 12 + root.diskSpace

    Binding {
        target: Widgets
        property: "explorerHeight"
        value: root.implicitHeight
        restoreMode: Binding.RestoreNone
    }

    Rectangle {
        id: placesCard
        y: root.compact ? header.y + root.headerH + 8 : root.switchH + 8
        width: root.compact ? root.width : root.placesW
        height: root.compact ? 30 : parent.height - y - root.diskSpace
        radius: Theme.radius
        color: root.compact ? "transparent" : Qt.alpha(Theme.textPrimary, 0.05)

        // Plus de favoris que de place : la liste défile.
        ListView {
            anchors.fill: parent
            anchors.margins: root.compact ? 0 : 6
            spacing: root.compact ? 5 : 1
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            orientation: root.compact ? ListView.Horizontal : ListView.Vertical
            model: root.places

            delegate: Item {
                id: placeRow
                required property var modelData
                // Allumé dans le favori comme dans ses sous-dossiers.
                readonly property bool here: root.path === placeRow.modelData.path
                                             || (!placeRow.modelData.exact
                                                 && root.path.indexOf(placeRow.modelData.path + "/") === 0)
                // Étroit, des boutons-icônes, sans nom : le favori où l'on
                // est s'allume.
                readonly property bool labelled: !root.compact
                width: !root.compact ? placesCard.width - 12
                     : placeRow.labelled ? placeLabel.implicitWidth + 11 + 16 + 8 + 12 : 38
                height: root.compact ? 30 : root.placeH
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                // Étroit, des pastilles : un liseré tant qu'elles sont éteintes.
                Rectangle {
                    anchors.fill: parent
                    radius: root.compact ? height / 2 : Theme.radiusSmall
                    color: placeRow.here ? Theme.selectedFill
                                         : Qt.alpha(Theme.textPrimary, placeMa.containsMouse ? 0.08
                                                                       : root.compact ? 0.03 : 0)
                    border.width: root.compact && !placeRow.here ? 1 : 0
                    border.color: Theme.dividerColor
                    Behavior on color { ColorAnimation { duration: 140 } }
                }

                FileIcon {
                    id: placeIcon
                    anchors.left: parent.left
                    anchors.leftMargin: root.compact ? 11 : 10
                    anchors.verticalCenter: parent.verticalCenter
                    iconSize: root.compact ? 16 : 18
                    // Étroit, le glyphe de la sorte (plus lisible qu'un
                    // dossier du thème à cette taille), teint ; nixos garde
                    // son logo.
                    source: root.compact && placeRow.modelData.glyph ? placeRow.modelData.glyph
                                                                      : placeRow.modelData.icon
                    tint: placeRow.here ? Theme.accentColor : Theme.textSecondary
                }

                Text {
                    id: placeLabel
                    anchors.left: placeIcon.right
                    anchors.leftMargin: root.compact ? 8 : 9
                    anchors.verticalCenter: parent.verticalCenter
                    // Étroit, la pastille prend la largeur du nom (rien à
                    // élider) ; large, le nom tient dans la colonne.
                    width: root.compact ? implicitWidth : placeRow.width - x - 8
                    visible: placeRow.labelled
                    text: placeRow.modelData.label
                    elide: root.compact ? Text.ElideNone : Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: placeRow.here ? Font.DemiBold : Font.Medium
                    color: placeRow.here ? Theme.textPrimary : Theme.textSecondary
                }

                MouseArea {
                    id: placeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.go(placeRow.modelData.path)
                }
            }
        }
    }

    // ── Les disques, en bas ──────────────────────────────────────
    // Une pastille par disque, sur toute la largeur du widget : son nom, ce
    // qu'il contient, son remplissage. Un clic va à son point de montage.
    //   ( Micron 3400      255 / 953 Go · 27 %  )  ( WD 2TB   …           )
    //   ( ▬▬▬▬───────────────────────────────── )  ( ▬▬▬▬▬▬▬▬──────────── )
    Flow {
        id: diskBar
        visible: root.disks.length > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.compact ? root.disks.length * (root.diskH + 8) - 8 : root.diskH
        spacing: 8

        Repeater {
            model: root.disks

            Rectangle {
                id: disk
                required property var modelData
                required property int index
                readonly property real pct: disk.modelData.size > 0 ? disk.modelData.used / disk.modelData.size : 0
                readonly property bool here: root.path === disk.modelData.path

                width: root.compact ? diskBar.width
                                    : (diskBar.width - diskBar.spacing * (root.disks.length - 1)) / root.disks.length
                height: root.diskH
                radius: Theme.radiusSmall
                color: disk.here ? Theme.selectedFill
                                 : Qt.alpha(Theme.textPrimary, diskMa.containsMouse || disk.activeFocus ? 0.09 : 0.05)
                border.width: 1
                border.color: disk.here ? "transparent" : Theme.dividerColor
                Behavior on color { ColorAnimation { duration: 140 } }

                // Au clavier aussi : Tab, puis Entrée ou Espace.
                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.go(disk.modelData.path);
                        event.accepted = true;
                    }
                }

                // Celle du thème, comme les dossiers des lieux.
                FileIcon {
                    id: diskIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    iconSize: 22
                    source: root.themed(["drive-harddisk"], "disk")
                }

                Column {
                    anchors.left: diskIcon.right
                    anchors.leftMargin: 10
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Item {
                        width: parent.width
                        height: diskLabel.implicitHeight
                        Text {
                            id: diskLabel
                            width: parent.width - diskSize.implicitWidth - 6
                            text: disk.modelData.label
                            elide: Text.ElideRight
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: disk.here ? Font.DemiBold : Font.Medium
                            color: Theme.textPrimary
                        }
                        Text {
                            id: diskSize
                            anchors.right: parent.right
                            anchors.baseline: diskLabel.baseline
                            text: disk.modelData.used + " / " + I18n.tr("unit.gb", { n: disk.modelData.size }) + "  ·  " + I18n.tr("common.percent", { n: Math.round(disk.pct * 100) })
                            font.family: "Inter"
                            font.pixelSize: 10
                            font.features: { "tnum": 1 }
                            color: Theme.textDim
                        }
                    }
                    Rectangle {
                        width: parent.width
                        height: 5
                        radius: 2.5
                        color: Qt.alpha(Theme.textPrimary, 0.1)
                        Rectangle {
                            width: parent.width * disk.pct
                            height: parent.height
                            radius: parent.radius
                            color: Theme.diskSeriesColors[disk.index % Theme.diskSeriesColors.length]
                        }
                    }
                }

                MouseArea {
                    id: diskMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.go(disk.modelData.path)
                }

                FocusRing { radius: disk.radius + gap }
            }
        }
    }

    // ── La navigation et le chemin ───────────────────────────────
    //   (←) (→) (↑)  ( ▭  ~ › code › karenine               ✎ )  (⌕)
    // Le chemin se lit en segments cliquables. Un clic à côté d'eux, le
    // crayon, Ctrl+L, ou « / » et « ~ » tapés dans la liste le rendent
    // éditable (cf. startEditing). La loupe le change en filtre du dossier.
    Item {
        id: header
        x: root.sideW
        y: root.compact ? root.switchH + 8 : 0
        width: root.width - x
        height: root.headerH

        Row {
            id: nav
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            GlassButton {
                implicitHeight: 30
                icon: "../assets/icons/arrow-left.svg"
                opacity: root.backStack.length > 0 ? 1 : 0.35
                onClicked: root.back()
            }
            GlassButton {
                implicitHeight: 30
                icon: "../assets/icons/arrow-right.svg"
                opacity: root.forwardStack.length > 0 ? 1 : 0.35
                onClicked: root.forward()
            }
            GlassButton {
                implicitHeight: 30
                icon: "../assets/icons/up.svg"
                opacity: root.path === root.rootDir ? 0.35 : 1
                onClicked: root.up()
            }
        }

        Rectangle {
            id: address
            // Ce que montre la barre : le champ du chemin, celui du filtre,
            // ou les segments.
            readonly property bool typing: root.editing || root.filtering
            anchors.left: nav.right
            anchors.leftMargin: 8
            anchors.right: searchBtn.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            height: 30
            radius: Theme.radiusSmall
            color: address.typing ? Theme.bgInput
                                  : Qt.alpha(Theme.textPrimary, addressMa.containsMouse ? 0.08 : 0.05)
            border.width: 1
            border.color: root.addressError ? Qt.alpha(Theme.colorDanger, 0.75)
                        : address.typing ? Qt.alpha(Theme.accentColor, 0.55) : "transparent"
            Behavior on color { ColorAnimation { duration: 140 } }
            Behavior on border.color { ColorAnimation { duration: 140 } }

            // Un chemin introuvable : la barre fait non de la tête.
            transform: Translate { id: shakeShift }
            SequentialAnimation {
                id: shake
                NumberAnimation { target: shakeShift; property: "x"; to: -6; duration: 45 }
                NumberAnimation { target: shakeShift; property: "x"; to: 5; duration: 70 }
                NumberAnimation { target: shakeShift; property: "x"; to: -3; duration: 60 }
                NumberAnimation { target: shakeShift; property: "x"; to: 0; duration: 50 }
            }

            // Tout ce qui n'est pas un segment rend le chemin éditable.
            MouseArea {
                id: addressMa
                anchors.fill: parent
                hoverEnabled: true
                enabled: !address.typing
                cursorShape: Qt.IBeamCursor
                onClicked: root.startEditing("")
            }

            NixIcon {
                id: addressGlyph
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                iconSize: 14
                source: root.filtering && !root.editing ? "../assets/icons/search.svg"
                                                        : "../assets/icons/folder.svg"
                color: address.typing ? Theme.accentColor : Theme.textDim
            }

            // ── Les segments ──
            // Trop longs, le début glisse hors de vue et la fin (le dossier
            // courant) reste lisible.
            Flickable {
                id: crumbView
                visible: !address.typing
                anchors.left: addressGlyph.right
                anchors.leftMargin: 4
                anchors.right: editHint.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                height: 26
                contentWidth: crumbRow.width
                contentX: Math.max(0, contentWidth - width)
                interactive: contentWidth > width
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                // Le vide autour des segments, dans la vue : l'édition aussi.
                MouseArea {
                    z: -1
                    width: Math.max(crumbView.width, crumbRow.width)
                    height: crumbView.height
                    cursorShape: Qt.IBeamCursor
                    onClicked: root.startEditing("")
                }

                Row {
                    id: crumbRow
                    height: parent.height
                    spacing: 0

                    Repeater {
                        model: root.crumbs

                        Row {
                            id: crumb
                            required property var modelData
                            required property int index
                            readonly property bool last: crumb.index === root.crumbs.length - 1
                            height: crumbRow.height

                            NixIcon {
                                visible: crumb.index > 0
                                anchors.verticalCenter: parent.verticalCenter
                                iconSize: 9
                                source: "../assets/icons/chevron-down.svg"
                                rotation: -90
                                color: Theme.textDim
                            }

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: crumbLabel.implicitWidth + 12
                                height: 22
                                radius: 5
                                color: Qt.alpha(Theme.textPrimary, crumbMa.containsMouse && !crumb.last ? 0.1 : 0)
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Text {
                                    id: crumbLabel
                                    anchors.centerIn: parent
                                    text: crumb.modelData.label
                                    font.family: "Inter"
                                    font.pixelSize: 12
                                    font.weight: crumb.last ? Font.DemiBold : Font.Medium
                                    color: crumb.last ? Theme.textPrimary : Theme.textSecondary
                                }

                                MouseArea {
                                    id: crumbMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: crumb.last ? Qt.IBeamCursor : Qt.PointingHandCursor
                                    onClicked: crumb.last ? root.startEditing("") : root.go(crumb.modelData.path)
                                }
                            }
                        }
                    }
                }
            }

            // Le crayon, au survol : la barre s'édite.
            NixIcon {
                id: editHint
                visible: !address.typing
                anchors.right: parent.right
                anchors.rightMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                iconSize: 13
                source: "../assets/icons/pencil.svg"
                color: Theme.textSecondary
                opacity: addressMa.containsMouse ? 0.9 : 0
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }

            // ── Le chemin, tapé ──
            TextInput {
                id: pathInput
                visible: root.editing
                anchors.left: addressGlyph.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                verticalAlignment: TextInput.AlignVCenter
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                selectedTextColor: Theme.textPrimary
                selectByMouse: true
                clip: true

                onTextEdited: root.pathEdited(pathInput.text)
                onAccepted: root.acceptPath()
                onActiveFocusChanged: if (!activeFocus && root.editing) root.finishEditing()

                Keys.onPressed: (event) => {
                    var n = root.suggestions.length;
                    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        root.complete(event.key === Qt.Key_Backtab);
                    } else if (event.key === Qt.Key_Down && n > 0) {
                        root.suggestIndex = (root.suggestIndex + 1) % n;
                    } else if (event.key === Qt.Key_Up && n > 0) {
                        root.suggestIndex = root.suggestIndex <= 0 ? n - 1 : root.suggestIndex - 1;
                    } else if (event.key === Qt.Key_Escape) {
                        if (root.suggestIndex >= 0)
                            root.suggestIndex = -1;
                        else
                            root.finishEditing(true);
                    } else {
                        return;
                    }
                    event.accepted = true;
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: pathInput.text === ""
                    text: I18n.tr("explorer.pathPlaceholder")
                    font: pathInput.font
                    color: Theme.textDim
                }
            }

            // ── Le filtre ──
            TextInput {
                id: filterInput
                visible: root.filtering && !root.editing
                anchors.left: addressGlyph.right
                anchors.leftMargin: 8
                anchors.right: filterClear.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                verticalAlignment: TextInput.AlignVCenter
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                selectedTextColor: Theme.textPrimary
                selectByMouse: true
                clip: true

                onTextEdited: root.filter = filterInput.text
                onActiveFocusChanged: if (!activeFocus && filterInput.text === "") root.filterOpen = false
                // Entrée : le seul résultat s'ouvre ; sinon la liste prend la main.
                onAccepted: {
                    if (root.entries.length === 1)
                        root.activate(0);
                    else
                        root.focusGrid();
                }
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape) {
                        root.closeFilter();
                    } else if (event.key === Qt.Key_Down) {
                        root.focusGrid();
                    } else {
                        return;
                    }
                    event.accepted = true;
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: filterInput.text === ""
                    text: I18n.tr("explorer.filter")
                    font: filterInput.font
                    color: Theme.textDim
                }
            }
            Rectangle {
                id: filterClear
                visible: root.filtering && !root.editing
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: 20
                height: 20
                radius: 10
                color: Qt.alpha(Theme.textPrimary, filterClearMa.containsMouse ? 0.12 : 0)
                NixIcon {
                    anchors.centerIn: parent
                    iconSize: 9
                    source: "../assets/icons/close.svg"
                    color: Theme.textSecondary
                }
                MouseArea {
                    id: filterClearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeFilter()
                }
            }
        }

        GlassButton {
            id: searchBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 30
            icon: "../assets/icons/search.svg"
            accent: root.filtering
            onClicked: root.filtering ? root.closeFilter() : root.openFilter()
        }
    }

    // Un titre de colonne de la liste : un clic trie par lui, un second
    // inverse l'ordre.
    component SortLabel: Item {
        id: sortLabel
        property string label
        property int key
        property bool alignRight: false
        readonly property bool on: root.sortKey === sortLabel.key
        implicitWidth: sortText.implicitWidth + 14
        
        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: sortLabel.alignRight ? parent.right : undefined
            anchors.left: sortLabel.alignRight ? undefined : parent.left
            layoutDirection: sortLabel.alignRight ? Qt.RightToLeft : Qt.LeftToRight
            spacing: 4
            Text {
                id: sortText
                anchors.verticalCenter: parent.verticalCenter
                text: sortLabel.label
                font.family: "Inter"
                font.pixelSize: 10
                font.weight: sortLabel.on ? Font.DemiBold : Font.Medium
                font.letterSpacing: 0.3
                color: sortLabel.on ? Theme.textSecondary
                                    : sortMa.containsMouse ? Theme.textSecondary : Theme.textDim
            }
            NixIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: sortLabel.on
                iconSize: 8
                source: "../assets/icons/chevron-down.svg"
                rotation: root.sortReversed ? 180 : 0
                color: Theme.textSecondary
            }
        }
        MouseArea {
            id: sortMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.sortBy(sortLabel.key)
        }
    }

    // ── Le contenu du dossier ────────────────────────────────────
    // En tuiles (large), ou en liste : l'icône, le nom, puis la taille et la
    // date quand il y a la place ; les titres de colonnes trient.
    Rectangle {
        id: content
        x: root.sideW
        y: root.compact ? placesCard.y + placesCard.height + 8 : root.headerH + 8
        width: root.width - x
        height: root.height - y - root.diskSpace - root.footerH - 2
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, 0.03)
        border.width: 1
        border.color: Theme.dividerColor

        // ── Les titres de colonnes ──
        Item {
            id: columnsHead
            visible: root.listView
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 5
            height: root.listView ? 26 : 0

            SortLabel {
                height: parent.height
                x: 38
                label: I18n.tr("explorer.colName")
                key: 0
            }
            SortLabel {
                height: parent.height
                visible: root.details
                x: parent.width - root.dateW - root.sizeW - 18
                width: root.sizeW
                alignRight: true
                label: I18n.tr("explorer.colSize")
                key: 1
            }
            SortLabel {
                height: parent.height
                visible: root.details
                x: parent.width - root.dateW - 10
                width: root.dateW
                alignRight: true
                label: I18n.tr("explorer.colModified")
                key: 2
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Theme.dividerColor
            }
        }

        // Vide, ou rien ne correspond au filtre.
        Column {
            anchors.centerIn: grid
            visible: grid.count === 0
            spacing: 10
            NixIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                iconSize: 30
                source: root.filter !== "" ? "../assets/icons/search.svg" : "../assets/icons/folder.svg"
                color: Theme.textDim
                visible: folder.status !== FolderListModel.Loading
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: folder.status === FolderListModel.Loading ? I18n.tr("common.loading")
                    : root.filter !== "" ? I18n.tr("explorer.noMatch", { q: root.filter })
                    : I18n.tr("explorer.emptyFolder")
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textSecondary
            }
        }

        // Hors de la grille : posé dedans, il défilerait avec les tuiles.
        FocusRing {
            anchors.fill: parent
            watch: grid
            radius: Theme.radius
            gap: 2
        }

        GridView {
            id: grid
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: columnsHead.bottom
            anchors.bottom: parent.bottom
            anchors.margins: 5
            anchors.topMargin: root.listView ? 3 : 5

            model: root.entries
            readonly property int columns: root.listView ? 1 : Math.max(1, Math.floor(width / 104))
            cellWidth: width / columns
            cellHeight: root.listView ? 34 : 104
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: -1
            highlightFollowsCurrentItem: false
            keyNavigationEnabled: false
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, GridView.Contain)

            // Un arrêt de Tab ; la sélection apparaît en y arrivant.
            activeFocusOnTab: true
            onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0

            // Un clic dans le vide, sous les tuiles, vide la sélection.
            MouseArea {
                z: -1
                width: grid.width
                height: Math.max(grid.contentHeight, grid.height)
                onClicked: {
                    root.clearSelection();
                    grid.forceActiveFocus();
                }
            }

            // Les premières lettres d'un nom, tapées vite, y sautent.
            property string typed: ""
            Timer {
                id: typedReset
                interval: 900
                onTriggered: grid.typed = ""
            }
            function jumpTo(prefix) {
                var p = prefix.toLowerCase();
                for (var i = 0; i < root.entries.length; i++) {
                    if (root.entries[i].name.toLowerCase().indexOf(p) === 0) {
                        grid.currentIndex = i;
                        return;
                    }
                }
            }

            // Aller à `index` ; avec Maj, la sélection s'étend de l'ancre jusque-là.
            function moveTo(index, extend) {
                if (extend) {
                    if (root.anchorIndex < 0)
                        root.anchorIndex = Math.max(0, grid.currentIndex);
                    root.selectRange(index);
                }
                grid.currentIndex = index;
            }

            // ← → restent dans la grille (le hub ne change pas d'onglet sous
            // les doigts) ; ↑ depuis la première rangée en sort. Maj+flèches
            // étendent la sélection, Espace ajoute ou retire, Ctrl+A prend tout ;
            // Échap vide la sélection, puis le filtre. « / » ou « ~ » ouvrent
            // le chemin à l'édition. Avec Alt, rien : c'est l'historique.
            Keys.onPressed: (event) => {
                if (event.modifiers & Qt.AltModifier)
                    return;
                var n = grid.count;
                var i = grid.currentIndex;
                var c = grid.columns;
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                if (event.key === Qt.Key_Left && n > 0) {
                    grid.moveTo(Math.max(0, i - 1), shift);
                } else if (event.key === Qt.Key_Right && n > 0) {
                    grid.moveTo(Math.min(n - 1, i + 1), shift);
                } else if (event.key === Qt.Key_Up && i >= c) {
                    grid.moveTo(i - c, shift);
                } else if (event.key === Qt.Key_Down && n > 0 && i + c < n) {
                    grid.moveTo(i < 0 ? 0 : i + c, shift);
                } else if (event.key === Qt.Key_Home && n > 0) {
                    grid.moveTo(0, shift);
                } else if (event.key === Qt.Key_End && n > 0) {
                    grid.moveTo(n - 1, shift);
                } else if (event.key === Qt.Key_Space && i >= 0) {
                    root.toggle(i);
                } else if (ctrl && event.key === Qt.Key_A) {
                    root.selectAll();
                } else if (event.key === Qt.Key_Escape && root.selectedCount > 0) {
                    root.clearSelection();
                } else if (event.key === Qt.Key_Escape && root.filtering) {
                    root.closeFilter();
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (root.selectedCount > 1)
                        root.openSelection();
                    else
                        root.activate(i);
                } else if (event.key === Qt.Key_Backspace) {
                    root.up();
                    grid.currentIndex = 0;
                } else if (!ctrl && (event.text === "/" || event.text === "~")) {
                    root.startEditing(event.text);
                } else if (event.text.length === 1 && event.text > " " && !ctrl) {
                    grid.typed += event.text;
                    typedReset.restart();
                    grid.jumpTo(grid.typed);
                } else {
                    return;
                }
                event.accepted = true;
            }

            delegate: Item {
                id: tile
                required property int index
                required property var modelData
                readonly property string fileName: tile.modelData.name
                readonly property string filePath: tile.modelData.path
                readonly property bool fileIsDir: tile.modelData.isDir
                readonly property bool hidden: tile.fileName.charAt(0) === "."

                readonly property bool current: grid.currentIndex === tile.index
                readonly property bool selected: root.isSelected(tile.filePath)
                readonly property string icon: root.iconFor(tile.filePath, tile.fileIsDir,
                                                            tile.modelData.suffix, tile.fileName)
                // Une miniature (l'image elle-même), pas une icône du thème.
                readonly property bool thumb: tile.icon === root.urlOf(tile.filePath)
                // Ce qu'un glisser parti d'ici emporte.
                readonly property var carried: root.dragPaths(tile.filePath)

                width: grid.cellWidth
                height: grid.cellHeight

                // Sélectionnée : teintée franchement ; retenue au clavier :
                // liserée ; survolée : à peine marquée.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: root.listView ? 1 : 3
                    radius: Theme.radiusSmall
                    color: tile.selected ? Qt.alpha(Theme.accentColor, 0.2)
                         : tileMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.06) : "transparent"
                    border.width: tile.current && grid.activeFocus ? 1 : 0
                    border.color: Qt.alpha(Theme.accentColor, 0.7)
                    Behavior on color { ColorAnimation { duration: 110 } }
                }

                // La miniature d'une image, ou l'icône du thème (un glyphe à
                // défaut : les dossiers à l'accent, les fichiers en retrait).
                Item {
                    id: tileImage
                    x: root.listView ? 10 : (parent.width - width) / 2
                    y: root.listView ? (parent.height - height) / 2 : 14
                    width: root.listView ? 20 : 46
                    height: width
                    // Un fichier caché, un peu effacé.
                    opacity: tile.hidden ? 0.55 : 1

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -1
                        visible: tile.thumb
                        radius: 4
                        color: Qt.alpha(Theme.textPrimary, 0.06)
                    }
                    Image {
                        anchors.fill: parent
                        visible: tile.thumb
                        source: tile.thumb ? tile.icon : ""
                        sourceSize.width: 96
                        sourceSize.height: 96
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }
                    FileIcon {
                        anchors.centerIn: parent
                        visible: !tile.thumb
                        iconSize: tileImage.width
                        source: tile.thumb ? "" : tile.icon
                        tint: tile.fileIsDir ? Theme.accentColor : Theme.textSecondary
                    }
                }

                Text {
                    id: tileName
                    x: root.listView ? tileImage.x + tileImage.width + 10 : 6
                    y: root.listView ? (parent.height - height) / 2 : tileImage.y + tileImage.height + 8
                    width: root.listView
                           ? parent.width - x - (root.details ? root.sizeW + root.dateW + 30 : 10)
                           : parent.width - 12
                    text: tile.fileName
                    horizontalAlignment: root.listView ? Text.AlignLeft : Text.AlignHCenter
                    wrapMode: root.listView ? Text.NoWrap : Text.WrapAnywhere
                    maximumLineCount: root.listView ? 1 : 2
                    elide: Text.ElideMiddle
                    font.family: "Inter"
                    font.pixelSize: root.listView ? 13 : 11
                    font.weight: tile.fileIsDir ? Font.DemiBold : Font.Medium
                    lineHeight: 0.95
                    color: tile.hidden ? Theme.textSecondary : Theme.textPrimary
                }

                // La taille (des fichiers) et la date, en liste.
                Text {
                    visible: root.listView && root.details
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width - root.dateW - root.sizeW - 18
                    width: root.sizeW
                    horizontalAlignment: Text.AlignRight
                    text: tile.fileIsDir ? "—" : root.humanSize(tile.modelData.size)
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: tile.fileIsDir ? Theme.textSubtle : Theme.textDim
                }
                Text {
                    visible: root.listView && root.details
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width - root.dateW - 10
                    width: root.dateW
                    horizontalAlignment: Text.AlignRight
                    text: root.shortDate(tile.modelData.modified)
                    elide: Text.ElideLeft
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: Theme.textDim
                }

                // Le nombre d'éléments emportés, sur la tuile tenue : il figure
                // aussi sur la vignette du glisser, capturée à l'appui.
                Rectangle {
                    anchors.horizontalCenter: tileImage.right
                    anchors.verticalCenter: tileImage.bottom
                    visible: tileMa.pressed && tile.carried.length > 1
                    width: Math.max(20, badgeLabel.implicitWidth + 10)
                    height: 20
                    radius: 10
                    color: Theme.glow(0)

                    Text {
                        id: badgeLabel
                        anchors.centerIn: parent
                        text: tile.carried.length
                        font.family: "Inter"
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: Theme.selectedTextColor
                    }
                }

                // Le porteur du glisser vers les autres applications. La tuile ne
                // bouge pas : ce proxy invisible est la cible du drag, et son
                // passage en Drag.active démarre le glisser système (le montage
                // de dragType Automatic).
                // Une tuile sélectionnée emporte toute la sélection.
                Item {
                    id: dragProxy
                    width: tile.width
                    height: tile.height
                    opacity: 0

                    Drag.active: tileMa.drag.active
                    Drag.dragType: Drag.Automatic
                    Drag.supportedActions: Qt.CopyAction
                    Drag.proposedAction: Qt.CopyAction
                    Drag.mimeData: ({
                        "text/uri-list": tile.carried.map(p => root.urlOf(p) + "\r\n").join(""),
                        "text/plain": tile.carried.join("\n")
                    })

                    Drag.onDragStarted: DragState.begin(tile.filePath)
                    // Déposé dans une application : la barre s'efface pour lui
                    // laisser la main (et le clavier). Annulé, elle reste.
                    Drag.onDragFinished: (dropAction) => {
                        DragState.end();
                        dragProxy.x = 0;
                        dragProxy.y = 0;
                        if (dropAction !== Qt.IgnoreAction) {
                            root.clearSelection();
                            root.opened();
                        }
                    }
                }

                // Comme dans un gestionnaire de fichiers : un clic sélectionne
                // la tuile seule, Ctrl+clic l'ajoute ou la retire, Maj+clic prend
                // la plage depuis la dernière cliquée ; un double clic entre
                // dans le dossier ou ouvre le fichier.
                MouseArea {
                    id: tileMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    drag.target: dragProxy
                    drag.threshold: 10

                    // La vignette du glisser : la tuile telle qu'elle est à
                    // l'appui, avec le nombre d'éléments emportés.
                    onPressed: {
                        tile.grabToImage(function (result) {
                            dragProxy.Drag.imageSource = result.url;
                        });
                    }
                    // Filet de sécurité : un glisser annulé sans dragFinished ne
                    // doit pas laisser la barre bloquée ouverte.
                    onReleased: {
                        DragState.end();
                        dragProxy.x = 0;
                        dragProxy.y = 0;
                    }
                    // N'est pas émis après un glissé.
                    onClicked: (mouse) => {
                        grid.forceActiveFocus();
                        grid.currentIndex = tile.index;
                        if (mouse.modifiers & Qt.ShiftModifier)
                            root.selectRange(tile.index);
                        else if (mouse.modifiers & Qt.ControlModifier)
                            root.toggle(tile.index);
                        else
                            root.selectOnly(tile.index);
                    }
                    onDoubleClicked: {
                        root.clearSelection();
                        root.activate(tile.index);
                    }
                }
            }
        }
    }

    // ── Le pied : où l'on en est, et l'affichage ─────────────────
    //   24 éléments                                  (◉) (▦) (▭) (>_)
    //   3 sélectionnés · 4,2 Mo  ×  (▯)
    Item {
        id: footer
        x: root.sideW
        y: content.y + content.height + 2
        width: root.width - x
        height: root.footerH

        Row {
            id: footerLeft
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, footer.width - footerRight.width - 80)
                elide: Text.ElideRight
                text: root.selectedCount > 0
                      ? I18n.trn("explorer.selected", root.selectedCount)
                        + (root.selectedSize > 0 ? "  ·  " + root.humanSize(root.selectedSize) : "")
                      : root.filter !== "" ? I18n.trn("explorer.matches", root.entries.length)
                      : I18n.trn("explorer.items", root.entries.length)
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: root.selectedCount > 0 ? Font.DemiBold : Font.Medium
                font.features: { "tnum": 1 }
                color: root.selectedCount > 0 ? Theme.textPrimary : Theme.textDim
            }
            // Vider la sélection.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.selectedCount > 0
                width: 20
                height: 20
                radius: 10
                color: Qt.alpha(Theme.textPrimary, clearMa.containsMouse ? 0.12 : 0.05)
                NixIcon {
                    anchors.centerIn: parent
                    iconSize: 8
                    source: "../assets/icons/close.svg"
                    color: Theme.textSecondary
                }
                MouseArea {
                    id: clearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearSelection()
                }
            }
            // La sélection vers le téléphone (KDE Connect) ; estompé tant
            // qu'aucun n'est à portée.
            GlassButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.selectedCount > 0
                implicitHeight: 24
                icon: "../assets/icons/phone.svg"
                opacity: root.phone ? 1 : 0.4
                onClicked: root.sendToPhone()
            }
        }

        Row {
            id: footerRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            // Les fichiers cachés : allumé, ils apparaissent.
            GlassButton {
                implicitHeight: 24
                icon: "../assets/icons/eye.svg"
                accent: root.showHidden
                onClicked: root.showHidden = !root.showHidden
            }
            // Tuiles ou liste.
            GlassButton {
                implicitHeight: 24
                icon: Widgets.explorerListView ? "../assets/icons/view-grid.svg" : "../assets/icons/view-list.svg"
                onClicked: Widgets.explorerListView = !Widgets.explorerListView
            }
            GlassButton {
                implicitHeight: 24
                icon: "../assets/icons/folder.svg"
                onClicked: {
                    DefaultApps.openInExplorer(root.path);
                    root.opened();
                }
            }
            GlassButton {
                implicitHeight: 24
                icon: "../assets/icons/terminal.svg"
                onClicked: {
                    // À distance : une session ssh, dans le même dossier.
                    if (root.remote)
                        DefaultApps.runInTerminal("", ["ssh", "-t", root.machine.host,
                            "cd " + root.shellQuote(root.remotePath(root.path)) + " && exec \"$SHELL\" -l"]);
                    else
                        DefaultApps.openInTerminal(root.path);
                    root.opened();
                }
            }
        }
    }

    // ── Les propositions, sous le chemin tapé ────────────────────
    //   ( ~/code/ka|                                   )
    //   ╭──────────────────────────────────────────────╮
    //   │ ▭ karenine                                   │
    //   │ ▭ kakoune                                    │
    //   │ Tab complète · Entrée ouvre · Échap annule   │
    //   ╰──────────────────────────────────────────────╯
    Rectangle {
        id: suggestBox
        visible: root.editing && root.suggestions.length > 0
        x: header.x + address.x
        y: header.y + header.height + 4
        z: 30
        width: address.width
        height: suggestCol.implicitHeight + 10
        radius: Theme.radiusSmall
        color: Theme.bgElevated
        border.width: 1
        border.color: Qt.alpha(Theme.accentColor, 0.3)

        Column {
            id: suggestCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 5

            Repeater {
                model: root.suggestions

                Rectangle {
                    id: sugg
                    required property var modelData
                    required property int index
                    readonly property bool on: root.suggestIndex === sugg.index
                    width: suggestCol.width
                    height: 28
                    radius: 6
                    color: sugg.on ? Theme.selectedFill
                                   : Qt.alpha(Theme.textPrimary, suggMa.containsMouse ? 0.06 : 0)

                    FileIcon {
                        id: suggIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        iconSize: 16
                        source: root.iconFor(sugg.modelData.path, sugg.modelData.isDir, sugg.modelData.suffix,
                                             sugg.modelData.name)
                        tint: sugg.modelData.isDir ? Theme.accentColor : Theme.textSecondary
                    }
                    // Ce qui correspond à ce qu'on a tapé, en gras.
                    Text {
                        anchors.left: suggIcon.right
                        anchors.leftMargin: 9
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.StyledText
                        text: root.highlight(sugg.modelData.name, sugg.modelData.at, root.suggestBase.length)
                              + (sugg.modelData.isDir ? "/" : "")
                        elide: Text.ElideMiddle
                        font.family: "Inter"
                        font.pixelSize: 12
                        color: sugg.on ? Theme.textPrimary : Theme.textSecondary
                    }
                    MouseArea {
                        id: suggMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Un dossier se complète (on continue à taper), un
                        // fichier s'ouvre dans son dossier.
                        onClicked: {
                            root.takeSuggestion(sugg.index);
                            if (!sugg.modelData.isDir)
                                root.acceptPath();
                            else
                                pathInput.forceActiveFocus();
                        }
                    }
                }
            }

            Text {
                width: suggestCol.width
                topPadding: 4
                leftPadding: 8
                bottomPadding: 1
                text: I18n.tr("explorer.pathHint")
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 10
                color: Theme.textDim
            }
        }
    }

    // ── La connexion en cours, ou son échec ──────────────────────
    // Une pastille en bas de la liste : le dossier d'avant reste affiché
    // en attendant. Un clic sur l'erreur la congédie. Hors connexion, elle
    // dit aussi où en est l'envoi au téléphone, ou un chemin introuvable.
    Rectangle {
        id: statusPill
        // La croix qui suit une erreur : sa place, écart compris.
        readonly property real closeWidth: root.error !== "" ? 10 + 10 : 0
        anchors.horizontalCenter: content.horizontalCenter
        anchors.bottom: content.bottom
        anchors.bottomMargin: 10
        z: 5
        visible: root.connecting !== "" || root.error !== "" || root.notice !== ""
        width: Math.min(statusLabel.implicitWidth + statusPill.closeWidth + 28, content.width - 20)
        height: 30
        radius: Theme.radiusSmall
        color: Theme.bgElevated
        border.width: 1
        border.color: root.error !== "" ? Qt.alpha(Theme.colorDanger, 0.5) : Qt.alpha(Theme.glow(0), 0.4)

        Row {
            anchors.centerIn: parent
            spacing: 10

            Text {
                id: statusLabel
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, statusPill.width - statusPill.closeWidth - 28)
                text: root.error !== "" ? root.error
                    : root.connecting !== "" ? I18n.tr("explorer.connecting", { name: root.connecting })
                    : root.notice
                elide: Text.ElideMiddle
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: root.error !== "" ? Theme.colorDanger : Theme.textPrimary
            }
            NixIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.error !== ""
                iconSize: 10
                source: "../assets/icons/close.svg"
                color: Theme.colorDanger
            }
        }
        MouseArea {
            anchors.fill: parent
            enabled: root.error !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: root.error = ""
        }
    }
}
