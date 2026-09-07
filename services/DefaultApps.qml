pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Résout les trois outils que le dock utilise pour ouvrir un fichier — éditeur,
// explorateur, terminal — à partir des réglages du système, jamais en dur. Si
// tu changes de défaut, la carte suit : icône comprise.
//
//   éditeur      xdg-mime query default text/plain
//   explorateur  xdg-mime query default inode/directory
//   terminal     $TERMINAL, puis XDG_TERMINAL_EMULATOR, puis x-terminal-emulator
//
// Chaque rôle retombe sur le premier outil connu trouvé dans le $PATH si le
// système ne déclare rien.
QtObject {
    id: root

    // ── Ce que le résolveur shell a rapporté ─────────────────────
    property string editorRef:   ""
    property string explorerRef: ""
    property string terminalRef: ""
    property string browserRef:  ""
    property string editorFallback:   ""
    property string explorerFallback: ""

    // Le premier accès à DesktopEntries déclenche son scan, qui est asynchrone.
    // Lire le compte ici l'amorce au démarrage *et* fait dépendre les rôles
    // ci-dessous de son arrivée : sans ça, les icônes resteraient vides.
    readonly property int appCount: DesktopEntries.applications.values.length

    readonly property var editor: root.appCount >= 0
        ? root._role(root.editorRef, root.editorFallback, "text-editor")
        : null

    readonly property var explorer: {
        var r = root._role(root.explorerRef, root.explorerFallback, "system-file-manager");
        // Un éditeur déclaré gestionnaire de dossiers n'est pas un explorateur :
        // on retombe alors sur un vrai gestionnaire de fichiers.
        if (root.editor && r.bin === root.editor.bin && root.explorerFallback.length > 0)
            return root._role(root.explorerFallback, "", "system-file-manager");
        return r;
    }

    readonly property var terminal: root.appCount >= 0
        ? root._role(root.terminalRef, "", "utilities-terminal")
        : null

    readonly property var browser: root.appCount >= 0
        ? root._role(root.browserRef, "", "web-browser")
        : null

    // ── Résolution ───────────────────────────────────────────────
    // `ref` est soit un identifiant .desktop, soit un nom de binaire.
    function _role(ref, fallbackBin, generic) {
        var entry = null;
        var bin = "";

        if (ref && ref.length > 0) {
            if (ref.length > 8 && ref.lastIndexOf(".desktop") === ref.length - 8) {
                var id = ref.substring(0, ref.length - 8);
                // Un handler d'URL (celui que posent Zed ou VS Code) n'ouvre pas
                // un chemin comme le ferait l'outil lui-même.
                if (id.indexOf("url-handler") === -1)
                    entry = DesktopEntries.byId(id);
            } else {
                bin = ref;
            }
        }

        if (!entry && bin.length === 0 && fallbackBin && fallbackBin.length > 0)
            bin = fallbackBin;
        if (!entry && bin.length > 0)
            entry = root._entryForBin(bin);

        var argv = [];
        var icon = "";

        if (entry) {
            for (var i = 0; i < entry.command.length; i++)
                argv.push(entry.command[i]);
            icon = Quickshell.iconPath(entry.icon, true);
        }
        if (argv.length === 0 && bin.length > 0)
            argv = [bin];
        if (icon.length === 0 && argv.length > 0)
            icon = Quickshell.iconPath(argv[0], true);
        if (icon.length === 0)
            icon = Quickshell.iconPath(generic, true);

        return {
            bin:  argv.length > 0 ? argv[0] : "",
            argv: argv,
            icon: icon,
            name: entry ? entry.name : (argv.length > 0 ? argv[0] : "")
        };
    }

    function _entryForBin(bin) {
        var apps = DesktopEntries.applications.values;
        for (var i = 0; i < apps.length; i++) {
            var c = apps[i].command;
            if (!c || c.length === 0)
                continue;
            var b = c[0];
            var slash = b.lastIndexOf("/");
            if (slash >= 0)
                b = b.substring(slash + 1);
            if (b === bin)
                return apps[i];
        }
        return null;
    }

    // ── Résolveur ────────────────────────────────────────────────
    property Process resolver: Process {
        command: ["sh", "-c",
            "printf 'editorRef\\t%s\\n' \"$(xdg-mime query default text/plain 2>/dev/null)\"; " +
            "printf 'explorerRef\\t%s\\n' \"$(xdg-mime query default inode/directory 2>/dev/null)\"; " +
            "printf 'browserRef\\t%s\\n' \"$(xdg-mime query default x-scheme-handler/https 2>/dev/null)\"; " +
            "t=\"$TERMINAL\"; " +
            "[ -n \"$t\" ] || t=\"$XDG_TERMINAL_EMULATOR\"; " +
            "[ -n \"$t\" ] || t=\"$(xdg-mime query default x-terminal-emulator 2>/dev/null)\"; " +
            "[ -n \"$t\" ] || for c in alacritty foot kitty wezterm ghostty konsole gnome-terminal xterm; do " +
            "  command -v \"$c\" >/dev/null 2>&1 && { t=\"$c\"; break; }; done; " +
            "printf 'terminalRef\\t%s\\n' \"$t\"; " +
            "for c in dolphin nautilus thunar nemo pcmanfm-qt pcmanfm; do " +
            "  command -v \"$c\" >/dev/null 2>&1 && { printf 'explorerFallback\\t%s\\n' \"$c\"; break; }; done; " +
            "for c in zeditor zed code codium nvim micro; do " +
            "  command -v \"$c\" >/dev/null 2>&1 && { printf 'editorFallback\\t%s\\n' \"$c\"; break; }; done"
        ]
        stdout: StdioCollector { id: resolverOut }
        onRunningChanged: if (!running) root._parse(resolverOut.text)
    }

    function _parse(text) {
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length < 2)
                continue;
            var v = f[1].trim();
            switch (f[0]) {
            case "editorRef":        root.editorRef = v; break;
            case "explorerRef":      root.explorerRef = v; break;
            case "terminalRef":      root.terminalRef = v; break;
            case "browserRef":       root.browserRef = v; break;
            case "explorerFallback": root.explorerFallback = v; break;
            case "editorFallback":   root.editorFallback = v; break;
            }
        }
    }

    function refresh() {
        if (!resolver.running)
            resolver.running = true;
    }

    // Les associations changent sans prévenir (xdg-mime default, réglages KDE…).
    // On relit dès que le fichier bouge, donc sans redémarrer le shell.
    property FileView mimeWatch: FileView {
        path: Quickshell.env("HOME") + "/.config/mimeapps.list"
        watchChanges: true
        printErrors: false
        onFileChanged: root.refresh()
    }

    Component.onCompleted: root.refresh()

    // ── Lancement ────────────────────────────────────────────────
    // `execDetached` plutôt qu'un `Process` : un Process est tué avec le shell,
    // donc redémarrer quickshell fermerait l'éditeur et le terminal qu'on vient
    // d'ouvrir. Détaché, il n'y a pas non plus d'instance unique à partager,
    // donc deux ouvertures rapprochées ne s'écrasent plus l'une l'autre.
    function _launch(argv, cwd) {
        if (!argv || argv.length === 0)
            return;
        Quickshell.execDetached({
            command: argv,
            workingDirectory: cwd || ""
        });
    }

    function openInEditor(path)   { root._launch(root.editor   ? root.editor.argv.concat([path])   : []); }
    function openInExplorer(path) { root._launch(root.explorer ? root.explorer.argv.concat([path]) : []); }

    // Le terminal hérite simplement du répertoire de travail : aucun drapeau
    // spécifique à un émulateur, donc ça marche avec n'importe lequel.
    function openInTerminal(dir)  { root._launch(root.terminal ? root.terminal.argv : [], dir); }

    // Drapeau « exécute cette commande » de l'émulateur. `-e` est la convention
    // quasi universelle ; les trois exceptions courantes tiennent ici, et un
    // terminal inconnu retombe sur `-e`, qui a toutes les chances de marcher.
    function _execFlag(bin) {
        var b = bin;
        var slash = b.lastIndexOf("/");
        if (slash >= 0)
            b = b.substring(slash + 1);

        switch (b) {
        case "gnome-terminal": return ["--"];
        case "wezterm":        return ["start", "--"];
        case "kitty":          return [];
        }
        return ["-e"];
    }

    // Lance une commande dans le terminal par défaut, depuis `dir`. Même règle
    // que le reste du fichier : l'émulateur est celui du système, jamais un nom
    // en dur chez l'appelant.
    function runInTerminal(dir, argv) {
        if (!root.terminal || root.terminal.argv.length === 0 || !argv || argv.length === 0)
            return;
        root._launch(root.terminal.argv
                         .concat(root._execFlag(root.terminal.bin))
                         .concat(argv),
                     dir);
    }

    // Repli sur xdg-open si aucun navigateur n'est déclaré : le lien s'ouvre
    // quand même.
    function openInBrowser(url) {
        if (root.browser && root.browser.argv.length > 0)
            root._launch(root.browser.argv.concat([url]));
        else
            root._launch(["xdg-open", url]);
    }
}
