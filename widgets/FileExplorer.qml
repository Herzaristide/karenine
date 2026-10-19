pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "../services"

// L'onglet « Explorer » : les dossiers du PC, sans quitter la barre. À
// gauche, les favoris (les dossiers du dossier personnel, et /etc/nixos) ; à
// droite, le chemin, cliquable segment par segment, et le contenu du
// dossier en tuiles, les dossiers d'abord.
//
//   (▣ zola       ▾)  (↑)  ~ › ciph3r › karenine         (◉) (▭) (>_)
//   ╭──────────────╮
//   │ ▭ ciph3r     │  ╭────╮ ╭────╮ ╭────╮ ╭────╮ ╭────╮
//   │ ▭ Documents  │  │ ▭  │ │ ▭  │ │ ▭  │ │ ≡  │ │ ▣  │
//   │ ▭ Images     │  │ai  │ │anna│ │docs│ │flake│ │logo│
//   │ …            │  ╰────╯ ╰────╯ ╰────╯ ╰────╯ ╰────╯
//   │ ❄ nixos      │  …
//   ╰──────────────╯
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

    readonly property int placesW: 150
    readonly property int headerH: 34
    readonly property int switchH: 34
    // La bande des disques, en bas sur toute la largeur (rien sans disque).
    readonly property int diskH: 46
    readonly property int diskSpace: root.disks.length > 0 ? root.diskH + 10 : 0

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

    function go(p) {
        if (p === root.path)
            return;
        Widgets.explorerPath = p;
        root.clearSelection();
        grid.currentIndex = -1;
        grid.positionViewAtBeginning();
    }

    // ── La sélection ─────────────────────────────────────────────
    // Par chemin plutôt que par index : l'ordre du modèle bouge (fichiers
    // cachés montrés, dossier qui change sur le disque). Réaffectée en
    // entier à chaque changement pour que les liaisons suivent.
    property var selection: ({})
    readonly property var selectedPaths: Object.keys(root.selection)
    readonly property int selectedCount: root.selectedPaths.length
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
        var p = folder.get(index, "filePath");
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
        s[folder.get(index, "filePath")] = true;
        root.selection = s;
        root.anchorIndex = index;
    }
    // De l'ancre à `index`, à la place de la sélection en cours.
    function selectRange(index) {
        var from = root.anchorIndex < 0 ? index : root.anchorIndex;
        var s = {};
        for (var i = Math.min(from, index); i <= Math.max(from, index); i++)
            s[folder.get(i, "filePath")] = true;
        root.selection = s;
        root.anchorIndex = from;
    }
    function selectAll() {
        var s = {};
        for (var i = 0; i < folder.count; i++)
            s[folder.get(i, "filePath")] = true;
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
        for (var i = 0; i < folder.count; i++) {
            var p = folder.get(i, "filePath");
            if (root.isSelected(p) && !folder.get(i, "fileIsDir"))
                files.push(p);
        }
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
        if (index < 0 || index >= folder.count)
            return;
        var p = folder.get(index, "filePath");
        if (folder.get(index, "fileIsDir")) {
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
    readonly property var imageSuffixes: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
    readonly property var suffixIcons: ({
        pdf: "application-pdf",
        mp3: "audio-x-generic", flac: "audio-x-generic", wav: "audio-x-generic",
        ogg: "audio-x-generic", opus: "audio-x-generic", m4a: "audio-x-generic",
        mp4: "video-x-generic", mkv: "video-x-generic", webm: "video-x-generic",
        mov: "video-x-generic", avi: "video-x-generic",
        zip: "package-x-generic", tar: "package-x-generic", gz: "package-x-generic",
        xz: "package-x-generic", zst: "package-x-generic", "7z": "package-x-generic",
        rar: "package-x-generic",
        qml: "text-x-script", js: "text-x-script", ts: "text-x-script",
        rs: "text-x-script", py: "text-x-script", sh: "text-x-script",
        nix: "text-x-script", c: "text-x-script", cpp: "text-x-script",
        h: "text-x-script", go: "text-x-script", json: "text-x-script",
        toml: "text-x-script", yaml: "text-x-script", yml: "text-x-script",
        html: "text-html", md: "text-x-generic", txt: "text-x-generic"
    })

    // Une image se montre elle-même ; le reste prend l'icône du thème.
    function iconFor(p, isDir, suffix) {
        if (isDir)
            return Theme.icon("folder", true);
        var s = (suffix || "").toLowerCase();
        // À distance, pas de miniature : chaque image traverserait le réseau.
        if (!root.remote && root.imageSuffixes.indexOf(s) !== -1)
            return root.urlOf(p);
        return Theme.icon(root.suffixIcons[s] || "text-x-generic", true)
            || Theme.icon("text-x-generic", true);
    }

    // ── Les favoris ──────────────────────────────────────────────
    // Les dossiers du dossier personnel (sans les cachés), puis la
    // configuration NixOS. `get()` n'est pas observable : la liste se relit
    // à chaque changement du modèle.
    // Sur un serveur, sa configuration NixOS s'il en a une. Pas de favori
    // pour la racine : il engloberait tout le reste, donc resterait allumé ;
    // le disque « / » de la bande du bas, le chemin et ↑ y mènent.
    readonly property var extraPlaces: !root.remote
        ? [{ label: "nixos", icon: "nix-snowflake", path: "/etc/nixos" }]
        : (root.machine.nixos ? [{ label: "nixos", icon: "nix-snowflake", path: root.rootDir + "/etc/nixos" }] : [])
    // Les icônes du thème pour les dossiers XDG, en français ou en anglais.
    readonly property var placeIcons: ({
        Bureau: "user-desktop", Desktop: "user-desktop",
        Documents: "folder-documents",
        "Téléchargements": "folder-download", Downloads: "folder-download",
        Images: "folder-pictures", Pictures: "folder-pictures",
        Musique: "folder-music", Music: "folder-music",
        "Vidéos": "folder-videos", Videos: "folder-videos"
    })
    property var places: root.extraPlaces

    function rebuildPlaces() {
        var out = [];
        for (var i = 0; i < homeDirs.count; i++) {
            var name = homeDirs.get(i, "fileName");
            out.push({ label: name, icon: root.placeIcons[name] || "folder",
                       path: homeDirs.get(i, "filePath") });
        }
        root.places = out.concat(root.extraPlaces);
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
    // disque. Sur un serveur, la même chose par ssh (des commandes simples :
    // son shell peut être fish). Relu à l'affichage, au changement de
    // machine et chaque minute.
    property var disks: []   // [{ label, used, size, path }], en Go

    // -l : sans les systèmes de fichiers réseau, dont nos montages sshfs (un
    // serveur qui ne répond plus figerait df).
    readonly property string diskScript: "df -P -B1 -l; echo @@; lsblk -J -o NAME,PATH,TYPE,MODEL"

    function refreshDisks() {
        // Un relevé en cours : celui-ci est refait juste après (sinon un
        // changement de machine pendant un relevé n'aurait plus de disques).
        if (diskProc.running) {
            diskProc.again = true;
            return;
        }
        diskProc.again = false;
        diskProc.mount = root.machine ? root.machine.mount : "";
        diskProc.command = root.machine
            ? ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", root.machine.host, root.diskScript]
            : ["sh", "-c", root.diskScript];
        diskProc.running = true;
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
                // La machine a changé entre-temps : son relevé suit.
                if (diskProc.mount !== (root.machine ? root.machine.mount : ""))
                    return;
                // ssh a échoué (rien ne revient) : on garde ce qu'on montrait
                // et on réessaie bientôt, plutôt que de vider la bande.
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
            if (!running && (diskProc.again || diskProc.mount !== (root.machine ? root.machine.mount : "")))
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
        sortField: FolderListModel.Name
        sortCaseSensitive: false
    }

    // Le bouton « précédent » de la souris remonte.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.BackButton
        onClicked: root.up()
    }

    // ── La machine, au-dessus des favoris ────────────────────────
    MachinePicker {
        width: root.placesW
        height: root.switchH
        busy: root.connecting
    }

    // ── Les favoris, à gauche ────────────────────────────────────
    Rectangle {
        id: placesCard
        y: root.switchH + 8
        width: root.placesW
        height: parent.height - y - root.diskSpace
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, 0.05)

        // Plus de favoris que de place : la liste défile.
        ListView {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 1
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.places

            delegate: Item {
                id: placeRow
                required property var modelData
                // Allumé dans le favori comme dans ses sous-dossiers.
                readonly property bool here: root.path === placeRow.modelData.path
                                             || root.path.indexOf(placeRow.modelData.path + "/") === 0
                width: ListView.view.width
                height: 33

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSmall
                    color: placeRow.here ? Theme.selectedFill
                                         : Qt.alpha(Theme.textPrimary, placeMa.containsMouse ? 0.07 : 0)
                    Behavior on color { ColorAnimation { duration: 140 } }
                }

                Image {
                    id: placeIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    source: Theme.icon(placeRow.modelData.icon, true)
                            || Theme.icon("folder", true)
                    sourceSize.width: 36
                    sourceSize.height: 36
                    asynchronous: true
                }

                Text {
                    anchors.left: placeIcon.right
                    anchors.leftMargin: 9
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: placeRow.modelData.label
                    elide: Text.ElideRight
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
    Row {
        id: diskBar
        visible: root.disks.length > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.diskH
        spacing: 8

        Repeater {
            model: root.disks

            Rectangle {
                id: disk
                required property var modelData
                required property int index
                readonly property real pct: disk.modelData.size > 0 ? disk.modelData.used / disk.modelData.size : 0
                readonly property bool here: root.path === disk.modelData.path

                width: (diskBar.width - diskBar.spacing * (root.disks.length - 1)) / root.disks.length
                height: diskBar.height
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

                Image {
                    id: diskIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    height: 20
                    source: Theme.icon("drive-harddisk", true)
                    sourceSize.width: 40
                    sourceSize.height: 40
                    asynchronous: true
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

    // ── Le chemin et les actions ─────────────────────────────────
    Item {
        id: header
        x: root.placesW + 12
        width: root.width - x
        height: root.headerH

        GlassButton {
            id: upBtn
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 30
            icon: "../assets/icons/up.svg"
            opacity: root.path === root.rootDir ? 0.4 : 1
            onClicked: root.up()
        }

        // Les segments ; trop longs, le début glisse hors de vue et la fin
        // (le dossier courant) reste lisible.
        Flickable {
            id: crumbView
            anchors.left: upBtn.right
            anchors.leftMargin: 8
            anchors.right: actions.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: 26
            contentWidth: crumbRow.width
            contentX: Math.max(0, contentWidth - width)
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Row {
                id: crumbRow
                height: parent.height
                spacing: 2

                Repeater {
                    model: root.crumbs

                    Row {
                        id: crumb
                        required property var modelData
                        required property int index
                        readonly property bool last: crumb.index === root.crumbs.length - 1
                        height: crumbRow.height
                        spacing: 2

                        Text {
                            visible: crumb.index > 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: "›"
                            font.family: "Inter"
                            font.pixelSize: 13
                            color: Theme.textDim
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: crumbLabel.implicitWidth + 14
                            height: 24
                            radius: 6
                            color: Qt.alpha(Theme.textPrimary, crumbMa.containsMouse && !crumb.last ? 0.08 : 0)
                            Behavior on color { ColorAnimation { duration: 140 } }

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
                                cursorShape: crumb.last ? Qt.ArrowCursor : Qt.PointingHandCursor
                                onClicked: root.go(crumb.modelData.path)
                            }
                        }
                    }
                }
            }
        }

        Row {
            id: actions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            // La sélection en cours : combien, et de quoi la vider.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.selectedCount > 0
                width: countLabel.implicitWidth + 36
                height: 30
                radius: Theme.radiusSmall
                color: Qt.alpha(Theme.glow(0), clearMa.containsMouse ? 0.26 : 0.18)
                Behavior on color { ColorAnimation { duration: 140 } }

                Text {
                    id: countLabel
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.trn("explorer.selected", root.selectedCount)
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 11
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✕"
                    font.family: "Inter"
                    font.pixelSize: 10
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
                implicitHeight: 30
                visible: root.selectedCount > 0
                icon: "../assets/icons/phone.svg"
                opacity: root.phone ? 1 : 0.4
                onClicked: root.sendToPhone()
            }

            // Les fichiers cachés : allumé, ils apparaissent.
            GlassButton {
                implicitHeight: 30
                icon: "../assets/icons/eye.svg"
                accent: root.showHidden
                onClicked: root.showHidden = !root.showHidden
            }
            GlassButton {
                implicitHeight: 30
                icon: "../assets/icons/folder.svg"
                onClicked: {
                    DefaultApps.openInExplorer(root.path);
                    root.opened();
                }
            }
            GlassButton {
                implicitHeight: 30
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

    // ── Le contenu du dossier ────────────────────────────────────
    Text {
        anchors.centerIn: grid
        visible: grid.count === 0
        text: folder.status === FolderListModel.Loading ? "…" : I18n.tr("explorer.emptyFolder")
        font.family: "Inter"
        font.pixelSize: 13
        color: Theme.textSecondary
    }

    // Hors de la grille : posé dedans, il défilerait avec les tuiles.
    FocusRing {
        anchors.fill: grid
        watch: grid
        radius: Theme.radius
        gap: 2
    }

    GridView {
        id: grid
        x: root.placesW + 12
        y: root.headerH + 8
        width: root.width - x
        height: root.height - y - root.diskSpace

        model: folder
        readonly property int columns: Math.max(1, Math.floor(width / 96))
        cellWidth: width / columns
        cellHeight: 88
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
            onClicked: root.clearSelection()
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
            for (var i = 0; i < folder.count; i++) {
                if (String(folder.get(i, "fileName")).toLowerCase().indexOf(p) === 0) {
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
        // Échap vide la sélection, puis rend le clavier au champ.
        Keys.onPressed: (event) => {
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
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.selectedCount > 1)
                    root.openSelection();
                else
                    root.activate(i);
            } else if (event.key === Qt.Key_Backspace) {
                root.up();
                grid.currentIndex = 0;
            } else if (event.text.length === 1 && event.text > " " && !ctrl
                       && !(event.modifiers & Qt.AltModifier)) {
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
            required property string fileName
            required property string filePath
            required property bool fileIsDir
            required property string fileSuffix

            readonly property bool current: grid.currentIndex === tile.index
            readonly property bool selected: root.isSelected(tile.filePath)
            readonly property string icon: root.iconFor(tile.filePath, tile.fileIsDir, tile.fileSuffix)
            readonly property bool thumb: tile.icon.indexOf("file://") === 0
            // Ce qu'un glisser parti d'ici emporte.
            readonly property var carried: root.dragPaths(tile.filePath)

            width: grid.cellWidth
            height: grid.cellHeight

            // Sélectionnée : teintée franchement ; retenue au clavier : teintée ;
            // survolée : à peine marquée.
            Rectangle {
                anchors.fill: parent
                anchors.margins: 3
                radius: Theme.radiusSmall
                color: tile.selected ? Qt.alpha(Theme.accentColor, 0.22)
                     : tile.current ? Theme.selectedFill : Theme.hoverOverlay
                opacity: tile.current || tile.selected || tileMa.containsMouse ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on color { ColorAnimation { duration: 120 } }
            }

            Image {
                id: tileImage
                anchors.horizontalCenter: parent.horizontalCenter
                y: 10
                width: 36
                height: 36
                source: tile.icon
                sourceSize.width: 72
                sourceSize.height: 72
                fillMode: tile.thumb ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                // Un fichier caché, un peu effacé.
                opacity: tile.fileName.charAt(0) === "." ? 0.55 : 1
            }

            Text {
                anchors.top: tileImage.bottom
                anchors.topMargin: 6
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 12
                text: tile.fileName
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 2
                elide: Text.ElideMiddle
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: Font.Medium
                lineHeight: 0.95
                color: tile.fileName.charAt(0) === "." ? Theme.textSecondary : Theme.textPrimary
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
            // de dragType Automatic,).
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

    // ── La connexion en cours, ou son échec ──────────────────────
    // Une pastille en bas de la grille : le dossier d'avant reste affiché
    // en attendant. Un clic sur l'erreur la congédie. Hors connexion, elle
    // dit aussi où en est l'envoi au téléphone.
    Rectangle {
        anchors.horizontalCenter: grid.horizontalCenter
        anchors.bottom: grid.bottom
        anchors.bottomMargin: 8
        z: 5
        visible: root.connecting !== "" || root.error !== "" || root.notice !== ""
        width: Math.min(statusLabel.implicitWidth + 28, grid.width - 20)
        height: 30
        radius: Theme.radiusSmall
        color: Theme.bgElevated
        border.width: 1
        border.color: root.error !== "" ? Qt.alpha(Theme.colorDanger, 0.5) : Qt.alpha(Theme.glow(0), 0.4)

        Text {
            id: statusLabel
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - 28)
            text: root.error !== "" ? root.error + "   ✕"
                : root.connecting !== "" ? I18n.tr("explorer.connecting", { name: root.connecting })
                : root.notice
            elide: Text.ElideMiddle
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: root.error !== "" ? Theme.colorDanger : Theme.textPrimary
        }
        MouseArea {
            anchors.fill: parent
            enabled: root.error !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: root.error = ""
        }
    }
}
