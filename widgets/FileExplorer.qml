pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
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
// Le clic droit sur un dossier ou un fichier (ou dans le vide) ouvre un
// menu : l'ouvrir dessous, dans l'éditeur, le terminal ou le gestionnaire
// de fichiers du système.
//
// Le mode split (« Ouvrir en dessous » du menu, ou un clic du milieu sur un
// dossier)
// ouvre un second dossier dessous (ExplorerPane), qui reste où il est
// pendant qu'on navigue au-dessus. Glisser de l'un à l'autre, ou sur un
// dossier, déplace (mv, sans écraser ce qui existe déjà) ; ce qui vient
// d'une autre application est copié.
//
// En haut, sur toute la largeur, les disques de toutes les machines, en cases
// remplies d'accent selon leur remplissage : celle-ci et les serveurs du
// tailnet (relevés par anna). Un clic sur un disque choisit sa machine, la
// même que dans l'onglet Système. Un serveur se monte par sshfs et
// l'Explorer y montre ses dossiers comme les locaux. Les favoris restent
// ceux de cette machine : un clic sur l'un d'eux y ramène.
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
    // Les disques, en haut sur toute la largeur, en une rangée : ils se
    // partagent la place à parts égales, selon leur nombre.
    readonly property int diskGap: 6
    readonly property real diskW: root.disks.length === 0 ? 0
        : (root.width - root.diskGap * (root.disks.length - 1)) / root.disks.length
    readonly property int switchH: 46

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

    // ── Le split : un second dossier, dessous ────────────────────
    // Ouvert sur un dossier (le menu du clic droit, ou le clic du milieu), il reste là pendant qu'on navigue au-dessus ; on
    // glisse de l'un à l'autre pour déplacer (cf. ExplorerPane).
    readonly property bool split: Widgets.explorerSplitPath !== ""
    readonly property int splitGap: 8
    // Relire les dossiers après un déplacement : sshfs ne prévient pas.
    property int reloadTick: 0
    function folderUrl(p) {
        return root.urlOf(p) + (root.reloadTick % 2 === 1 && p !== "/" ? "/" : "");
    }

    function openSplit(p) {
        Widgets.explorerSplitPath = p;
    }
    function closeSplit() {
        var sp = Widgets.explorerSplitPath;
        Widgets.explorerSplitPath = "";
        // Un serveur que seul le dossier du bas tenait monté.
        var m = root.mountOf(sp);
        if (m !== "" && !(root.remote && root.machine.mount === m))
            Quickshell.execDetached(["fusermount3", "-uz", m]);
    }
    // Le point de montage sshfs qui contient `p`, ou "".
    function mountOf(p) {
        var base = root.mountBase + "/";
        if (p.indexOf(base) !== 0)
            return "";
        var rest = p.substring(base.length);
        var slash = rest.indexOf("/");
        return base + (slash < 0 ? rest : rest.substring(0, slash));
    }

    // ── Le menu du clic droit ────────────────────────────────────
    // Sur un dossier ou un fichier (ou dans le vide : le dossier montré),
    // dans l'un ou l'autre dossier : l'ouvrir dessous (un dossier, depuis
    // celui du haut), dans l'éditeur, le terminal ou le gestionnaire de
    // fichiers du système (cf. DefaultApps) ; un fichier, depuis son dossier
    // pour ces deux derniers. Sur un serveur monté, le terminal est une
    // session ssh et Zed s'y connecte lui-même (ssh://).
    // { path, isDir, below (le dossier du bas), paths (ce que la sélection
    // emporte), isVoid (le dossier montré, cliqué dans le vide) }
    property var menuTarget: null
    // « Supprimer » appuyé une fois : le second appui supprime.
    property bool menuArmed: false
    function showMenu(path, isDir, below, x, y, paths, isVoid) {
        root.menuArmed = false;
        root.menuTarget = { path: path, isDir: isDir, below: below,
                            paths: paths && paths.length > 0 ? paths : [path], isVoid: isVoid === true };
        contextMenu.x = Math.max(4, Math.min(x, root.width - contextMenu.width - 4));
        // Sa hauteur à venir (le Repeater n'a pas encore suivi).
        var h = root.menuActions.reduce((s, a) => s + (a.divider ? 10 : 31), 11)
              + (root.menuInline.length > 0 ? 35 : 0);
        contextMenu.y = Math.max(4, Math.min(y, root.height - h - 4));
        contextMenu.forceActiveFocus();
    }
    readonly property var menuActions: {
        var t = root.menuTarget;
        if (!t)
            return [];
        var dir = t.isDir ? t.path : root.parentOf(t.path);
        var out = [];
        if (!t.isVoid)
            out.push({ glyph: t.isDir ? "../assets/icons/folder.svg" : "../assets/icons/file.svg",
                       label: I18n.tr("explorer.open"), run: () => root.openPath(t.path, t.isDir, t.below),
                       leaves: !t.isDir });
        if (!t.isVoid) {
            if (t.paths.length === 1)
                out.push({ glyph: "../assets/icons/pencil.svg", label: I18n.tr("explorer.rename"),
                           run: () => root.startRename(t.path), leaves: false });
            var hard = root.mountOf(t.path) !== "";
            out.push({ glyph: "../assets/icons/trash.svg", danger: true, leaves: false,
                       label: t.paths.length > 1 ? I18n.trn("explorer.deleteMany", t.paths.length) : I18n.tr("explorer.delete"),
                       // Sur un serveur, pas de corbeille : c'est pour de bon.
                       confirm: I18n.tr(hard ? "explorer.deleteForever" : "explorer.deleteConfirm"),
                       run: () => root.removePaths(t.paths) });
        }
        return out;
    }
    // La rangée d'icônes en tête du menu : ouvrir dessous, l'éditeur, le
    // terminal, le gestionnaire de fichiers et le téléphone, des glyphes (pas les logos des applications : l'éditeur
    // ou le terminal du système peut changer, le geste reste le même), sans
    // intitulé.
    readonly property var menuInline: {
        var t = root.menuTarget;
        if (!t)
            return [];
        var dir = t.isDir ? t.path : root.parentOf(t.path);
        var out = [];
        if (t.isDir && !t.below)
            out.push({ glyph: "../assets/icons/split.svg", label: I18n.tr("explorer.openBelow"),
                       run: () => root.openSplit(t.path), leaves: false });
        if (DefaultApps.editor && DefaultApps.editor.argv.length > 0)
            out.push({ glyph: "../assets/icons/code.svg",
                       label: I18n.tr("explorer.openIn", { app: DefaultApps.editor.name }),
                       run: () => root.openInEditor(t.path), leaves: true });
        if (DefaultApps.terminal && DefaultApps.terminal.argv.length > 0)
            out.push({ glyph: "../assets/icons/terminal.svg", label: I18n.tr("explorer.openTerminal"),
                       run: () => root.openTerminalAt(dir), leaves: true });
        if (DefaultApps.explorer && DefaultApps.explorer.argv.length > 0)
            out.push({ glyph: "../assets/icons/folder.svg",
                       label: I18n.tr("explorer.openIn", { app: DefaultApps.explorer.name }),
                       run: () => DefaultApps.openInExplorer(dir), leaves: true });
        // Seulement des fichiers (KDE Connect n'envoie pas de dossier) ;
        // estompé tant qu'aucun téléphone n'est à portée.
        var files = t.isVoid ? [] : t.paths.filter(p => !root.isDirPath(p, t));
        if (files.length > 0)
            out.push({ glyph: "../assets/icons/phone.svg", dim: !root.phone,
                       label: root.phone ? I18n.tr("explorer.sendTo", { name: root.phone.name })
                                         : I18n.tr("explorer.noPhone"),
                       // Le téléphone du menu, figé : runMenu() referme le menu
                       // avant de lancer l'action, ce qui coupe phoneSock et
                       // remet root.phone à null.
                       run: ((phone) => () => root.sendToPhone(files, phone))(root.phone),
                       leaves: false });
        return out;
    }
    // Un chemin de la cible est-il un dossier : la cible elle-même, sinon ce
    // qu'en disent les deux listes.
    function isDirPath(p, t) {
        if (p === t.path)
            return t.isDir;
        var e = root.entries.find(x => x.path === p);
        return e ? e.isDir : splitPane.isDir(p);
    }

    function runMenu(action) {
        if (action.confirm && !root.menuArmed) {
            root.menuArmed = true;
            return;
        }
        root.menuTarget = null;
        action.run();
        if (action.leaves)
            root.opened();
    }

    // Ouvrir : un dossier, on y entre (dans son dossier, haut ou bas) ; un
    // fichier, dans son application par défaut.
    function openPath(p, isDir, below) {
        if (!isDir)
            Quickshell.execDetached(["xdg-open", p]);
        else if (below)
            Widgets.explorerSplitPath = p;
        else
            root.go(p);
    }

    // ── Renommer, supprimer ──────────────────────────────────────
    // Renommer : un champ à la place du menu, le nom sans son extension
    // sélectionné ; Entrée renomme (sans écraser), Échap annule.
    property string renaming: ""
    function startRename(p) {
        root.renaming = p;
        var name = p.substring(p.lastIndexOf("/") + 1);
        renameInput.text = name;
        var dot = name.lastIndexOf(".");
        renameInput.select(0, dot > 0 ? dot : name.length);
        renameInput.forceActiveFocus();
    }
    function finishRename(accept) {
        var p = root.renaming;
        root.renaming = "";
        var name = renameInput.text.trim();
        if (!accept || name === "" || name === "." || name === ".." || name.indexOf("/") >= 0
                || name === p.substring(p.lastIndexOf("/") + 1))
            return;
        root.fileOp(["sh", "-c", "[ -e \"$2\" ] || [ -L \"$2\" ] && echo exists || { mv -- \"$1\" \"$2\" && echo done || echo failed; }",
                     "--", p, root.parentOf(p) + "/" + name], "rename");
    }

    // Supprimer : ici, dans la corbeille (la freedesktop, que les
    // gestionnaires de fichiers savent vider ou restaurer) ; sur un serveur
    // monté, définitivement (après une confirmation qui le dit).
    readonly property string trashScript:
        "T=\"$HOME/.local/share/Trash\"; mkdir -p \"$T/files\" \"$T/info\" || exit 1; " +
        "now=$(date +%Y-%m-%dT%H:%M:%S); " +
        "while [ $# -gt 1 ]; do p=\"$1\"; enc=\"$2\"; shift 2; " +
        "  b=$(basename \"$p\"); n=\"$b\"; i=1; " +
        "  while [ -e \"$T/files/$n\" ] || [ -e \"$T/info/$n.trashinfo\" ]; do i=$((i+1)); n=\"$b.$i\"; done; " +
        "  printf '[Trash Info]\\nPath=%s\\nDeletionDate=%s\\n' \"$enc\" \"$now\" > \"$T/info/$n.trashinfo\" " +
        "  && mv -- \"$p\" \"$T/files/$n\" && echo done || { rm -f \"$T/info/$n.trashinfo\"; echo failed; }; " +
        "done"
    function removePaths(paths) {
        var local = paths.filter(p => root.mountOf(p) === "");
        var remote = paths.filter(p => root.mountOf(p) !== "");
        if (local.length > 0) {
            var args = [];
            local.forEach(p => args.push(p, p.split("/").map(encodeURIComponent).join("/")));
            root.fileOp(["sh", "-c", root.trashScript, "--"].concat(args), "trash");
        } else if (remote.length > 0) {
            root.fileOp(["sh", "-c", "for p; do rm -rf -- \"$p\" && echo done || echo failed; done", "--"].concat(remote),
                        "delete");
        }
    }

    // Une opération sur des fichiers à la fois : ce qu'elle dit (done,
    // exists, failed par élément), puis les deux dossiers relus.
    function fileOp(command, kind) {
        if (fileOpProc.running) {
            root.say(I18n.tr("explorer.busy"));
            return;
        }
        fileOpProc.kind = kind;
        fileOpProc.command = command;
        fileOpProc.running = true;
    }
    Process {
        id: fileOpProc
        property string kind: ""
        stdout: StdioCollector { id: fileOpOut }
        stderr: StdioCollector { id: fileOpErr }
        onExited: {
            var lines = fileOpOut.text.trim().split("\n");
            var count = w => lines.filter(l => l === w).length;
            var done = count("done"), exists = count("exists"), failed = count("failed");
            var k = fileOpProc.kind;
            var says = [];
            if (k === "rename") {
                if (exists > 0)
                    says.push(I18n.tr("explorer.nameTaken"));
            } else if (done > 0) {
                says.push(I18n.trn(k === "trash" ? "explorer.trashed" : "explorer.deleted", done));
            }
            if (failed > 0 || (done + exists === 0 && fileOpErr.text.trim() !== ""))
                says.push(fileOpErr.text.trim().split("\n").pop() || I18n.tr("common.failedSentence"));
            if (says.length > 0)
                root.say(says.join("  ·  "));
            root.clearSelection();
            splitPane.selection = {};
            root.reloadTick++;
        }
    }

    // Le serveur d'un point de montage sshfs : son hôte ssh.
    function hostOfMount(m) {
        var name = m.substring(root.mountBase.length + 1);
        if (root.remote && root.machine.mount === m)
            return root.machine.host;
        var d = root.disks.find(x => x.machine === name);
        return d ? d.host : name;
    }
    function openInEditor(p) {
        var m = root.mountOf(p);
        var bin = DefaultApps.editor.bin;
        bin = bin.substring(bin.lastIndexOf("/") + 1);
        if (m !== "" && (bin === "zed" || bin === "zeditor"))
            Quickshell.execDetached(DefaultApps.editor.argv.concat(
                ["ssh://" + root.hostOfMount(m) + (p.substring(m.length) || "/")]));
        else
            DefaultApps.openInEditor(p);
    }
    function openTerminalAt(dir) {
        var m = root.mountOf(dir);
        if (m !== "")
            DefaultApps.runInTerminal("", ["ssh", "-t", root.hostOfMount(m),
                "cd " + root.shellQuote(dir.substring(m.length) || "/") + " && exec \"$SHELL\" -l"]);
        else
            DefaultApps.openInTerminal(dir);
    }

    // Un dépôt d'ici (l'un des deux dossiers) : la barre reste ouverte,
    // contrairement à un dépôt dans une autre application.
    property bool internalDrop: false
    function dragFinished(dropAction) {
        if (root.internalDrop) {
            root.internalDrop = false;
            root.clearSelection();
            return;
        }
        if (dropAction !== Qt.IgnoreAction) {
            root.clearSelection();
            root.opened();
        }
    }

    // Déposé sur `dest` : déplacé s'il vient d'ici, copié s'il vient d'une
    // autre application (on ne lui retire pas ses fichiers).
    function dropInto(drop, dest) {
        var paths = (drop.urls || []).map(u => root.pathOf(u)).filter(p => p.charAt(0) === "/");
        var inside = drop.source !== null && drop.source !== undefined;
        drop.accept(Qt.CopyAction);
        if (inside)
            root.internalDrop = true;
        root.transfer(paths, dest, !inside);
    }

    // mv (ou cp -a) un à un, sans jamais écraser : ce qui existe déjà à
    // destination reste où il est, et on le dit.
    readonly property string transferScript:
        "op=\"$1\"; dest=\"$2\"; shift 2; " +
        "for p; do t=\"$dest/$(basename \"$p\")\"; " +
        "  if [ -e \"$t\" ] || [ -L \"$t\" ]; then echo exists; continue; fi; " +
        "  if [ \"$op\" = copy ]; then cp -a -- \"$p\" \"$dest/\"; else mv -- \"$p\" \"$dest/\"; fi " +
        "  && echo done || echo failed; " +
        "done"
    function transfer(paths, dest, copy) {
        // Ni sur place, ni un dossier dans lui-même.
        var list = paths.filter(p => p !== dest && root.parentOf(p) !== dest && dest.indexOf(p + "/") !== 0);
        if (list.length === 0)
            return;
        if (transferProc.running) {
            root.say(I18n.tr("explorer.busy"));
            return;
        }
        transferProc.copy = copy;
        transferProc.command = ["sh", "-c", root.transferScript, "--", copy ? "copy" : "move", dest].concat(list);
        transferProc.running = true;
        root.notice = I18n.trn(copy ? "explorer.copying" : "explorer.moving", list.length);
        noticeTimer.stop();
    }
    Process {
        id: transferProc
        property bool copy: false
        stdout: StdioCollector { id: transferOut }
        stderr: StdioCollector { id: transferErr }
        onExited: {
            var lines = transferOut.text.trim().split("\n");
            var count = w => lines.filter(l => l === w).length;
            var done = count("done"), exists = count("exists"), failed = count("failed");
            var says = [];
            if (done > 0)
                says.push(I18n.trn(transferProc.copy ? "explorer.copied" : "explorer.moved", done));
            if (exists > 0)
                says.push(I18n.trn("explorer.exists", exists));
            if (failed > 0)
                says.push(transferErr.text.trim().split("\n").pop() || I18n.trn("explorer.failed", failed));
            root.say(says.join("  ·  "));
            root.clearSelection();
            root.reloadTick++;
        }
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
        if (root.picking) {
            if (root.pick.mode !== "save")
                root.confirmPick();
            return;
        }
        for (var i = 0; i < root.selectedPaths.length; i++)
            Quickshell.execDetached(["xdg-open", root.selectedPaths[i]]);
        root.clearSelection();
        root.opened();
    }

    // ── L'envoi au téléphone ─────────────────────────────────────
    // Les fichiers du menu (le clic droit, la sélection s'il y est) partent
    // vers le téléphone appairé avec KDE
    // Connect (anna phone share, un à la fois), comme un dépôt sur la carte
    // de l'onglet Téléphone. Les dossiers restent : KDE Connect n'envoie que
    // des fichiers. Le téléphone n'est suivi (phone_watch) que tant qu'il y a
    // une sélection ou un menu ouvert : le premier appairé et à portée.
    property var phone: null
    // Le retour du dernier envoi, dans la pastille du bas, effacé seul.
    property string notice: ""

    Socket {
        id: phoneSock
        path: Anna.socketPath
        connected: root.visible && (root.selectedCount > 0 || root.menuTarget !== null)
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

    function sendToPhone(paths, target) {
        // Un envoi en cours : il finit d'abord.
        if (shareProc.running || shareProc.pending.length > 0)
            return;
        var phone = target || root.phone;
        if (!phone) {
            root.say(I18n.tr("explorer.noPhone"));
            return;
        }
        var files = paths;
        if (files.length === 0) {
            root.say(I18n.tr("explorer.onlyFiles"));
            return;
        }
        shareProc.device = phone.id;
        shareProc.name = phone.name;
        shareProc.pending = files;
        shareProc.sent = 0;
        shareProc.failure = "";
        root.say(I18n.trn("explorer.sending", files.length, { name: phone.name }));
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
        if (root.picking) {
            // Un fichier, en mode choix : ouvrir le prend, enregistrer
            // reprend son nom (le bouton dit alors « Remplacer »).
            if (root.pick.mode === "open")
                Widgets.explorerPickFinish([p]);
            else if (root.pick.mode === "save")
                pickName.text = root.entries[index].name;
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
    // Toujours ceux de cette machine, même sur un serveur (on n'y va que par
    // ses disques) : le dossier personnel, les dossiers XDG (ceux de
    // ~/.config/user-dirs.dirs, cf. xdg-user-dirs), puis la configuration
    // NixOS. Depuis un serveur, un favori ramène ici (openPlace) ; il ne
    // s'allume qu'ici. Le dossier personnel ne s'allume que chez lui
    // (`exact`) : il engloberait les autres favoris. Pas de favori pour la
    // racine : il engloberait tout le reste ; les disques, le chemin et ↑ y
    // mènent.
    readonly property var extraPlaces: [{ label: "nixos", icon: "../assets/nixos.svg", path: "/etc/nixos" }]

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
        path: root.localHome + "/.config/user-dirs.dirs"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parseUserDirs(userDirs.text())
        onLoadFailed: {
            root.xdgDirs = null;
            root.rebuildPlaces();
        }
    }

    // Des lignes XDG_DOCUMENTS_DIR="$HOME/Documents" ; un dossier réglé sur
    // le dossier personnel lui-même est désactivé.
    function parseUserDirs(text) {
        var dirs = {};
        var homeVirt = root.localHome;
        text.split("\n").forEach(line => {
            var m = line.match(/^\s*XDG_([A-Z]+)_DIR\s*=\s*"(.*)"\s*$/);
            if (!m)
                return;
            var v = m[2].replace(/^\$HOME/, homeVirt).replace(/\/+$/, "");
            if (v === "" || v === homeVirt || v.charAt(0) !== "/")
                return;
            dirs[m[1]] = v;
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
                     glyph: root.glyph("home"), path: root.localHome, exact: true }];
        var byPath = {};
        root.xdgKinds.forEach(kind => {
            var p = "";
            if (root.xdgDirs) {
                p = root.xdgDirs[kind.key] || "";
                // Sous le dossier personnel, il doit exister ; ailleurs, on
                // lui fait confiance.
                if (p !== "" && root.parentOf(p) === root.localHome && !present[p])
                    p = "";
            } else {
                for (var k = 0; k < kind.names.length && p === ""; k++)
                    if (present[root.localHome + "/" + kind.names[k]])
                        p = root.localHome + "/" + kind.names[k];
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
                        || (root.parentOf(p) === root.localHome && !present[p]))
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
        folder: root.urlOf(root.localHome)
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
    // coûte pas une nouvelle connexion. On la choisit par un de ses disques
    // (openDisk), ou dans l'onglet Système (MachinePicker).
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
        // Le dossier du bas y est encore : il reste monté (closeSplit le
        // démontera).
        if (m && root.mountOf(Widgets.explorerSplitPath) !== m.mount)
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
        function onExplorerRequestChanged() { root.takeRequest(); }
    }
    Component.onCompleted: {
        root.follow();
        root.takeRequest();
        root.pickSetup();
    }

    // Ce qu'on demande de montrer de l'extérieur (Widgets.explorerShow) :
    // toujours un chemin local, gardé tant qu'un serveur est encore monté.
    function takeRequest() {
        var r = Widgets.explorerRequest;
        if (!r || root.remote)
            return;
        Widgets.explorerRequest = null;
        if (r.isDir)
            root.go(r.path);
        else
            root.reveal(r.path);
    }

    // ── Le mode choix (le sélecteur de fichiers des applications) ─
    // Widgets.explorerPick, posé par karenine-pick : le pied laisse place à
    // la barre de choix (cf. pickBar). Ouvrir (open) rend les fichiers
    // sélectionnés, ou celui qu'on double-clique ; un dossier (dir), le
    // dossier sélectionné, sinon celui qu'on montre ; enregistrer (save), le
    // nom tapé dans le dossier montré.
    readonly property var pick: Widgets.explorerPick
    readonly property bool picking: root.pick !== null
    onPickChanged: root.pickSetup()
    function pickSetup() {
        if (root.pick && root.pick.mode === "save") {
            pickName.text = root.pick.name;
            pickName.forceActiveFocus();
            pickName.selectAll();
        }
    }
    function entryOf(p) {
        for (var i = 0; i < root.entries.length; i++)
            if (root.entries[i].path === p)
                return root.entries[i];
        return null;
    }
    readonly property string pickNameText: pickName.text.trim()
    readonly property var pickPaths: {
        var k = root.pick;
        if (!k)
            return [];
        if (k.mode === "save") {
            var n = root.pickNameText;
            if (n === "" || n === "." || n === ".." || n.indexOf("/") >= 0)
                return [];
            return [(root.path === "/" ? "" : root.path) + "/" + n];
        }
        var sel = root.selectedPaths.filter(p => {
            var e = root.entryOf(p);
            return e !== null && e.isDir === (k.mode === "dir");
        });
        if (k.mode === "dir")
            return [sel.length === 1 ? sel[0] : root.path];
        return k.multiple ? sel : sel.slice(0, 1);
    }
    // Enregistrer par-dessus un fichier qui existe : le bouton le dit.
    readonly property bool pickReplaces: root.picking && root.pick.mode === "save"
        && root.entries.some(e => e.name === root.pickNameText)
    function confirmPick() {
        if (root.pickPaths.length > 0)
            Widgets.explorerPickFinish(root.pickPaths);
    }

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
                root.pendingDisk = null;
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
            // Choisie par un de ses disques : on y va plutôt qu'au dossier
            // personnel.
            var want = root.pendingDisk;
            root.pendingDisk = null;
            if (want && want.machine === srv.name)
                Widgets.explorerPath = mountProc.mount + (want.main === "/" ? "" : want.main);
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
    // Les disques physiques de toutes les machines : celle-ci et chaque
    // serveur en ligne, tels qu'anna les relève (servers_watch sans nom :
    // lsblk ici, node_exporter sur les serveurs ; un relevé, puis on
    // raccroche). Un par disque, avec ce que ses systèmes de fichiers
    // occupent et son point de montage principal, sans ceux qui ne portent
    // que /boot, /efi ou le store. Un clic choisit sa machine (la montant au
    // besoin) et va à ce point de montage. Relu à l'affichage et chaque
    // minute.
    // [{ machine ("" ici), host, hostLabel, name, label, used, size (octets), main }]
    property var disks: []
    // Le disque cliqué d'un serveur en cours de montage : on y va une fois monté.
    property var pendingDisk: null

    function drivesOf(drives, machine, host, hostLabel) {
        var shown = m => m.indexOf("/boot") !== 0 && m.indexOf("/efi") !== 0 && m.indexOf("/nix/store") !== 0;
        var list = (drives || []).filter(d => d.fs_size > 0 && (d.mounts || []).some(shown))
            .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
        return list.map(d => ({
                machine: machine, host: host, hostLabel: hostLabel, name: d.name,
                // « Micron 3400 MTFDKBA1T0TFH » → « Micron 3400 ».
                label: (d.model || "").trim().split(/\s+/).slice(0, 2).join(" ") || d.name,
                used: d.fs_used, size: d.fs_size, main: d.mounts.find(shown)
            }));
    }

    // Celle-ci d'abord, puis les serveurs. Un relevé raté (node_exporter
    // muet) garde ce qu'on montrait de la machine ; hors ligne, elle n'en a plus.
    function applyDisks(msg) {
        var keep = m => root.disks.filter(d => d.machine === m);
        var local = msg.local || {};
        var out = (local.drives || []).length > 0
            ? root.drivesOf(local.drives, "", "", local.hostname || I18n.tr("machine.thisComputer"))
            : keep("");
        (msg.servers || []).forEach(s => {
            if (!s.host || !s.online)
                return;
            out = out.concat(s.measured && !s.error ? root.drivesOf(s.drives, s.name, s.host, s.name)
                                                    : keep(s.name));
        });
        root.disks = out;
    }

    // Son point de montage, vu d'ici : "" pour un serveur qui n'est pas monté.
    // « 300 / 954 Go » : l'occupé dans l'unité du total, entier (une
    // décimale sous 10).
    function diskUsage(used, size) {
        var units = ["unit.bytes", "unit.kb", "unit.mb", "unit.gb", "unit.tb"];
        var i = 0, div = 1;
        while (size / div >= 1024 && i < units.length - 1) {
            div *= 1024;
            i++;
        }
        var fmt = v => i === 0 ? String(Math.round(v)) : v.toLocaleString(I18n.locale, "f", size / div < 10 ? 1 : 0);
        return fmt(used / div) + " / " + I18n.tr(units[i], { n: fmt(size / div) });
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function diskPath(d) {
        if (d.machine === "")
            return d.main;
        if (!root.remote || root.machine.name !== d.machine)
            return "";
        return root.machine.mount + (d.main === "/" ? "" : d.main);
    }

    // Le disque où l'on est : sur la machine montrée, le point de montage le
    // plus long qui contient le dossier.
    readonly property int currentDisk: {
        var best = -1, len = -1;
        var here = root.machine ? root.machine.name : "";
        for (var i = 0; i < root.disks.length; i++) {
            var d = root.disks[i];
            var p = root.diskPath(d);
            if (d.machine !== here || p === "")
                continue;
            var prefix = p.charAt(p.length - 1) === "/" ? p : p + "/";
            if ((root.path === p || root.path.indexOf(prefix) === 0) && p.length > len) {
                best = i;
                len = p.length;
            }
        }
        return best;
    }

    // Un favori : toujours de cette machine ; depuis un serveur, on revient
    // ici (cf. follow), puis on y va.
    function openPlace(p) {
        root.pendingDisk = null;
        if (Widgets.machine)
            Widgets.machine = null;
        root.go(p);
    }

    function openDisk(d) {
        if (d.machine === "") {
            root.pendingDisk = null;
            // Revenir ici (cf. follow) remet le dossier au personnel : on
            // part du disque ensuite.
            if (Widgets.machine)
                Widgets.machine = null;
            root.go(d.main);
        } else if (root.remote && root.machine.name === d.machine) {
            root.pendingDisk = null;
            root.go(root.diskPath(d));
        } else {
            root.pendingDisk = { machine: d.machine, main: d.main };
            Widgets.machine = { name: d.machine, host: d.host };
        }
    }

    Socket {
        id: diskSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    const msg = JSON.parse(line);
                    if (!msg.servers)
                        return;
                    diskSock.connected = false;
                    root.applyDisks(msg);
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write(JSON.stringify({ cmd: "servers_watch" }) + "\n");
        }
    }
    function refreshDisks() {
        diskSock.connected = false;
        diskSock.connected = true;
    }
    // Chaque minute ; toutes les 5 s tant qu'anna n'a rien donné.
    Timer {
        interval: root.disks.length === 0 ? 5000 : 60000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshDisks()
    }
    onMachineChanged: {
        root.backStack = [];
        root.forwardStack = [];
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
        folder: root.folderUrl(root.path)
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

    // ── Les disques de toutes les machines, en haut ──────────────
    // Une case par disque, à parts égales sur toute la largeur, remplie d'un liquide à l'accent autant qu'il est
    // plein ; sa machine et son nom en haut, l'occupé sur le total en bas (le pourcentage au
    // survol). Un clic va à sa racine. Celui où l'on est est cerclé d'accent. Un clic y va, sur sa
    // machine.
    //   ┌────────┐ ┌────────┐ ┌────────┐
    //   │  zola  │ │  gary  │ │  gary  │
    //   │▓▓▓▓▓▓▓▓│ │        │ │▓▓▓▓▓▓▓▓│
    //   └────────┘ └────────┘ └────────┘
    Row {
        id: diskBar
        width: root.width
        height: root.switchH
        spacing: root.diskGap

        Repeater {
            model: root.disks

            Rectangle {
                id: disk
                required property var modelData
                required property int index
                readonly property real pct: disk.modelData.size > 0
                                            ? Math.min(1, disk.modelData.used / disk.modelData.size) : 0
                readonly property bool here: root.currentDisk === disk.index
                // Sa machine est en train d'être montée.
                readonly property bool joining: root.connecting !== "" && root.connecting === disk.modelData.machine

                width: root.diskW
                height: root.switchH
                radius: Theme.radiusSmall
                color: Qt.alpha(Theme.textPrimary, diskMa.containsMouse || disk.activeFocus ? 0.09 : 0.05)
                border.width: disk.here ? 1.5 : 1
                border.color: disk.here ? Theme.accentColor : Theme.dividerColor
                Behavior on color { ColorAnimation { duration: 140 } }

                Accessible.role: Accessible.Button
                Accessible.name: disk.modelData.hostLabel + " · " + disk.modelData.label + " · "
                                 + root.humanSize(disk.modelData.used) + " / " + root.humanSize(disk.modelData.size)

                // Au clavier aussi : Tab, puis Entrée ou Espace.
                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.openDisk(disk.modelData);
                        event.accepted = true;
                    }
                }

                // Le liquide : deux vagues à la surface, qui roulent en sens
                // contraires, la plus claire derrière ; le niveau monte avec
                // un rebond (un ressort), la houle se creuse au survol.
                // Peint opaque dans une couche, puis découpé aux coins du
                // carré et rendu translucide d'un coup (sans recouvrement
                // plus foncé entre la vague et le corps).
                Item {
                    id: liquid
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true

                    property real level: disk.pct
                    Behavior on level { SpringAnimation { spring: 2.2; damping: 0.16; epsilon: 0.002 } }
                    // La surface, depuis le haut.
                    readonly property real surface: liquid.height * (1 - liquid.level)
                    property real amp: diskMa.containsMouse ? 5.5 : 3.5
                    Behavior on amp { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    readonly property real period: 60
                    readonly property bool wet: liquid.level > 0.004

                    LiquidWave {
                        tone: Qt.lighter(Theme.accentColor, 1.35)
                        duration: 3400
                        reversed: true
                        a: liquid.amp
                        p: liquid.period
                        y: liquid.surface - liquid.amp - 1
                        width: liquid.width + liquid.period
                        visible: liquid.wet
                        running: root.visible
                    }
                    Rectangle {
                        visible: liquid.wet
                        y: liquid.surface + liquid.amp
                        width: liquid.width
                        height: Math.max(0, liquid.height - liquid.surface - liquid.amp)
                        color: Theme.accentColor
                    }
                    LiquidWave {
                        tone: Theme.accentColor
                        duration: 2200
                        a: liquid.amp
                        p: liquid.period
                        y: liquid.surface - liquid.amp
                        width: liquid.width + liquid.period
                        visible: liquid.wet
                        running: root.visible
                    }
                }
                Rectangle {
                    id: diskShape
                    anchors.fill: parent
                    radius: disk.radius
                    visible: false
                    layer.enabled: true
                }
                MultiEffect {
                    anchors.fill: parent
                    source: liquid
                    maskEnabled: true
                    maskSource: diskShape
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                    opacity: disk.here ? 0.7 : 0.5
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                Text {
                    anchors.top: parent.top
                    anchors.topMargin: 5
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 8
                    horizontalAlignment: Text.AlignHCenter
                    // Sa machine en gras, puis le disque : « gary · Micron 3400 ».
                    textFormat: Text.StyledText
                    text: "<b>" + root.escapeHtml(disk.modelData.hostLabel) + "</b> · "
                          + root.escapeHtml(disk.modelData.label)
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 10
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                }
                Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 5
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 4
                    horizontalAlignment: Text.AlignHCenter
                    text: diskMa.containsMouse ? I18n.tr("common.percent", { n: Math.round(disk.pct * 100) })
                                               : root.diskUsage(disk.modelData.used, disk.modelData.size)
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 9
                    font.features: { "tnum": 1 }
                    color: Theme.textPrimary
                    opacity: 0.8
                }

                // Le montage de sa machine : le carré respire.
                SequentialAnimation on opacity {
                    running: disk.joining
                    loops: Animation.Infinite
                    onStopped: disk.opacity = 1
                    NumberAnimation { to: 0.45; duration: 500; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutSine }
                }

                MouseArea {
                    id: diskMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openDisk(disk.modelData)
                }

                FocusRing { radius: disk.radius + gap }
            }
        }
    }

    // Une vague de liquide (les disques) : sur la largeur du carré et une
    // période `p` de plus, d'amplitude `a`, qui glisse d'une période en
    // boucle : la reprise ne se voit pas. Pleine sous la crête.
    component LiquidWave: Shape {
        id: wave
        property color tone
        property real a: 1.5
        property real p: 40
        property int duration: 2400
        property bool reversed: false
        property bool running: true
        height: wave.a * 2 + 2
        preferredRendererType: Shape.CurveRenderer
        NumberAnimation on x {
            from: wave.reversed ? -wave.p : 0
            to: wave.reversed ? 0 : -wave.p
            duration: wave.duration
            loops: Animation.Infinite
            running: wave.running && wave.visible
        }
        ShapePath {
            fillColor: wave.tone
            strokeWidth: -1
            PathSvg {
                path: {
                    var a = wave.a, h = wave.p / 2;
                    // Avant la mise en page, la largeur (donc la période)
                    // est nulle : la boucle ne finirait pas.
                    if (!(h >= 1) || !(wave.width > 0))
                        return "";
                    var d = "M 0 " + a + " Q " + (h / 2) + " " + (-a) + " " + h + " " + a;
                    for (var x = 2 * h; x <= wave.width + h; x += h)
                        d += " T " + x + " " + a;
                    return d + " L " + (wave.width + h) + " " + wave.height
                         + " L 0 " + wave.height + " Z";
                }
            }
        }
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
    implicitHeight: root.switchH + 8 + root.shownPlaces * (root.placeH + 1) - 1 + 12
                    + (root.split ? root.splitH + root.splitGap : 0)
    // Le dossier du bas : la moitié de la place, que l'onglet gagne en hauteur.
    readonly property int splitH: 240

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
        height: root.compact ? 30 : parent.height - y
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
                readonly property bool here: !root.remote && root.path === placeRow.modelData.path
                                             || (!placeRow.modelData.exact
                                                 && !root.remote && root.path.indexOf(placeRow.modelData.path + "/") === 0)
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
                    onClicked: root.openPlace(placeRow.modelData.path)
                }
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
        y: root.switchH + 8
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
        y: root.compact ? placesCard.y + placesCard.height + 8 : header.y + root.headerH + 8
        width: root.width - x
        height: root.height - y - root.footerH - 2 - (root.split ? root.splitH + root.splitGap : 0)
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, 0.03)

        // Déposé dans le vide (pas sur un dossier) : dans le dossier montré.
        DropArea {
            id: contentDrop
            anchors.fill: parent
            keys: ["text/uri-list"]
            onEntered: (drag) => drag.accept(Qt.CopyAction)
            onDropped: (drop) => root.dropInto(drop, root.path)
        }
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: 1.5
            border.color: Theme.accentColor
            // Pas quand ce qu'on glisse en vient déjà.
            visible: contentDrop.containsDrag && !(DragState.active && root.parentOf(DragState.path) === root.path)
            z: 3
        }
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

            // Un clic dans le vide, sous les tuiles, vide la sélection ; le
            // droit, le menu du dossier montré.
            MouseArea {
                id: voidMa
                z: -1
                width: grid.width
                height: Math.max(grid.contentHeight, grid.height)
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        var at = voidMa.mapToItem(root, mouse.x, mouse.y);
                        root.showMenu(root.path, true, false, at.x, at.y, [], true);
                        return;
                    }
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
                    color: tileDrop.containsDrag ? Qt.alpha(Theme.accentColor, 0.3)
                         : tile.selected ? Qt.alpha(Theme.accentColor, 0.2)
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

                // Un dossier reçoit ce qu'on y dépose (pas lui-même).
                DropArea {
                    id: tileDrop
                    anchors.fill: parent
                    enabled: tile.fileIsDir
                    keys: ["text/uri-list"]
                    onEntered: (drag) => {
                        if (DragState.path === tile.filePath)
                            drag.accepted = false;
                        else
                            drag.accept(Qt.CopyAction);
                    }
                    onDropped: (drop) => root.dropInto(drop, tile.filePath)
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
                        root.dragFinished(dropAction);
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
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
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
                        if (mouse.button === Qt.RightButton) {
                            var at = tileMa.mapToItem(root, mouse.x, mouse.y);
                            root.showMenu(tile.filePath, tile.fileIsDir, false, at.x, at.y, root.dragPaths(tile.filePath), false);
                            return;
                        }
                        // Clic du milieu sur un dossier : il s'ouvre dessous.
                        if (mouse.button === Qt.MiddleButton) {
                            if (tile.fileIsDir)
                                root.openSplit(tile.filePath);
                            return;
                        }
                        grid.forceActiveFocus();
                        grid.currentIndex = tile.index;
                        if (mouse.modifiers & Qt.ShiftModifier)
                            root.selectRange(tile.index);
                        else if (mouse.modifiers & Qt.ControlModifier)
                            root.toggle(tile.index);
                        else
                            root.selectOnly(tile.index);
                    }
                    onDoubleClicked: (mouse) => {
                        if (mouse.button !== Qt.LeftButton)
                            return;
                        root.clearSelection();
                        root.activate(tile.index);
                    }
                }
            }
        }
    }

    // ── Le dossier du bas (le split) ─────────────────────────────
    ExplorerPane {
        id: splitPane
        visible: root.split
        explorer: root
        path: Widgets.explorerSplitPath
        reloadTick: root.reloadTick
        x: content.x
        y: content.y + content.height + root.splitGap
        width: content.width
        height: root.split ? root.splitH : 0
        onNavigate: (p) => Widgets.explorerSplitPath = p
        onCloseRequested: root.closeSplit()
    }

    // ── Le pied : où l'on en est, et l'affichage ─────────────────
    //   24 éléments                                              (◉) (▦)
    //   3 sélectionnés · 4,2 Mo  ×
    Item {
        id: footer
        x: root.sideW
        y: (root.split ? splitPane.y + splitPane.height : content.y + content.height) + 2
        width: root.width - x
        height: root.footerH
        // En mode choix, la barre de choix prend sa place.
        visible: !root.picking

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
        }
    }

    // ── La barre de choix (le mode choix, cf. pick) ──────────────
    //   Choisir un fichier : rapport.pdf               (Annuler) (Choisir)
    //   Enregistrer sous ( notes.txt            )   (Annuler) (Enregistrer)
    Item {
        id: pickBar
        x: footer.x
        y: footer.y
        width: footer.width
        height: root.footerH
        visible: root.picking

        Row {
            id: pickButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            GlassButton {
                implicitHeight: 24
                text: I18n.tr("explorer.pickCancel")
                fontSize: 11
                onClicked: Widgets.explorerPickFinish([])
            }
            GlassButton {
                implicitHeight: 24
                accent: true
                danger: root.pickReplaces
                fontSize: 11
                enabled: root.pickPaths.length > 0
                opacity: enabled ? 1 : 0.4
                text: !root.picking ? ""
                      : root.pick.mode === "save"
                        ? (root.pickReplaces ? I18n.tr("explorer.pickReplace") : I18n.tr("explorer.pickSave"))
                        : I18n.tr("explorer.pickConfirm")
                onClicked: root.confirmPick()
            }
        }

        Text {
            id: pickLabel
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: !root.picking ? ""
                  : root.pick.mode === "save" ? I18n.tr("explorer.pickSaveAs")
                  : root.pick.mode === "dir" ? I18n.tr("explorer.pickDir")
                  : root.pick.multiple ? I18n.tr("explorer.pickFiles")
                  : I18n.tr("explorer.pickFile")
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            color: Theme.accentColor
        }

        // Ce qui sera rendu (ouvrir, dossier), ou le nom à donner (enregistrer).
        Text {
            anchors.left: pickLabel.right
            anchors.leftMargin: 8
            anchors.right: pickButtons.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            visible: root.picking && root.pick.mode !== "save"
            elide: Text.ElideMiddle
            text: root.pickPaths.map(p => p.substring(p.lastIndexOf("/") + 1) || "/").join(", ")
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textSecondary
        }
        Rectangle {
            anchors.left: pickLabel.right
            anchors.leftMargin: 8
            anchors.right: pickButtons.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: 24
            visible: root.picking && root.pick.mode === "save"
            radius: 12
            color: Qt.alpha(Theme.textPrimary, 0.05)
            border.width: 1
            border.color: pickName.activeFocus ? Qt.alpha(Theme.accentColor, 0.6) : Theme.dividerColor

            TextInput {
                id: pickName
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                selectByMouse: true
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                selectedTextColor: Theme.textPrimary
                Keys.onReturnPressed: root.confirmPick()
                Keys.onEnterPressed: root.confirmPick()
                Keys.onEscapePressed: Widgets.explorerPickFinish([])
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

    // ── Le menu du clic droit (cf. showMenu) ─────────────────────
    //   ╭──────────────────────────╮
    //   │ (▤) (</>) (>_) (▭) (▯)   │
    //   │ ▤ Ouvrir                 │
    //   │ ✎ Renommer               │
    //   │ 🗑 Supprimer              │
    //   ╰──────────────────────────╯
    // Un clic ailleurs, ou Échap, le referme.
    MouseArea {
        anchors.fill: parent
        z: 19
        visible: root.menuTarget !== null
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: root.menuTarget = null
    }
    Rectangle {
        id: contextMenu
        z: 20
        visible: root.menuTarget !== null
        width: 220
        height: menuColumn.implicitHeight + 12
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: Theme.dividerColor
        Keys.onEscapePressed: root.menuTarget = null

        Column {
            id: menuColumn
            anchors.fill: parent
            anchors.margins: 6
            spacing: 1

            // ── La rangée d'icônes ──
            Item {
                visible: root.menuInline.length > 0
                width: menuColumn.width
                height: 34

                Row {
                    id: inlineRow
                    anchors.left: parent.left
                    anchors.top: parent.top
                    spacing: 4

                    Repeater {
                        model: root.menuInline

                        Rectangle {
                            id: inlineBtn
                            required property var modelData
                            width: 34
                            height: 32
                            radius: Theme.radiusSmall
                            color: Qt.alpha(Theme.textPrimary, inlineMa.containsMouse ? 0.1 : 0.04)
                            opacity: inlineBtn.modelData.dim ? 0.45 : 1
                            Behavior on color { ColorAnimation { duration: 120 } }

                            NixIcon {
                                anchors.centerIn: parent
                                iconSize: 17
                                source: inlineBtn.modelData.glyph
                                color: inlineMa.containsMouse ? Theme.accentColor : Theme.textPrimary
                            }
                            Accessible.role: Accessible.Button
                            Accessible.name: inlineBtn.modelData.label
                            MouseArea {
                                id: inlineMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runMenu(inlineBtn.modelData)
                            }
                        }
                    }
                }
            }
            Repeater {
                model: root.menuActions

                Rectangle {
                    id: menuItem
                    required property var modelData
                    readonly property bool divider: menuItem.modelData.divider === true
                    readonly property bool danger: menuItem.modelData.danger === true
                    // Supprimer, appuyé une fois : il demande confirmation.
                    readonly property bool armed: menuItem.danger && root.menuArmed
                    width: menuColumn.width
                    height: menuItem.divider ? 9 : 30
                    radius: Theme.radiusSmall
                    color: menuItem.divider ? "transparent"
                         : menuItem.armed ? Qt.alpha(Theme.colorDanger, 0.18)
                         : Qt.alpha(menuItem.danger ? Theme.colorDanger : Theme.textPrimary,
                                    menuItemMa.containsMouse ? 0.1 : 0)
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Rectangle {
                        visible: menuItem.divider
                        anchors.verticalCenter: parent.verticalCenter
                        x: 6
                        width: parent.width - 12
                        height: 1
                        color: Theme.dividerColor
                    }
                    FileIcon {
                        id: menuIcon
                        visible: !menuItem.divider
                        anchors.left: parent.left
                        anchors.leftMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        iconSize: 16
                        tint: menuItem.danger ? Theme.colorDanger : Theme.accentColor
                        source: menuItem.divider ? "" : menuItem.modelData.glyph
                    }
                    Text {
                        visible: !menuItem.divider
                        anchors.left: menuIcon.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: menuItem.armed ? menuItem.modelData.confirm : (menuItem.modelData.label || "")
                        elide: Text.ElideRight
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: menuItem.armed ? Font.DemiBold : Font.Medium
                        color: menuItem.danger ? Theme.colorDanger : Theme.textPrimary
                    }
                    MouseArea {
                        id: menuItemMa
                        anchors.fill: parent
                        enabled: !menuItem.divider
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.runMenu(menuItem.modelData)
                    }
                }
            }
        }
    }

    // ── Le nouveau nom (cf. startRename) ─────────────────────────
    // À la place du menu ; un clic ailleurs annule.
    MouseArea {
        anchors.fill: parent
        z: 19
        visible: root.renaming !== ""
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: root.finishRename(false)
    }
    Rectangle {
        id: renameBox
        z: 20
        visible: root.renaming !== ""
        x: Math.min(contextMenu.x, root.width - width - 4)
        y: contextMenu.y
        width: 260
        height: 40
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: Qt.alpha(Theme.accentColor, 0.6)

        TextInput {
            id: renameInput
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            selectByMouse: true
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textPrimary
            selectionColor: Qt.alpha(Theme.accentColor, 0.45)
            selectedTextColor: Theme.textPrimary
            Keys.onReturnPressed: root.finishRename(true)
            Keys.onEnterPressed: root.finishRename(true)
            Keys.onEscapePressed: root.finishRename(false)
        }
    }
}
