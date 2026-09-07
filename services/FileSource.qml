import QtQuick
import Quickshell
import Quickshell.Io

// Source « fichiers et dossiers » : `fd` dans un processus séparé, donc jamais
// sur le thread de rendu. Une seule requête en vol à la fois — la précédente
// est tuée — et un délai de garde qui coupe court si l'arborescence est énorme.
QtObject {
    id: src

    readonly property string type:  "file"
    readonly property string label: "Fichiers"
    readonly property int    limit: 8

    // En dessous, le bruit dépasse l'intérêt et `fd` traverse tout pour rien.
    readonly property int minChars: 2
    readonly property int timeoutMs: 2000

    readonly property string home: Quickshell.env("HOME") || "/home"

    // Racines parcourues. Le dossier personnel ne suffit pas : la configuration
    // NixOS vit dans /etc, qui est petit et vaut donc largement son parcours.
    // Ajouter une racine = une entrée ici.
    readonly property var roots: [src.home, "/etc"]

    signal produced(int seq, var items)

    // Requête en cours d'exécution, et celle qui attend son tour. Les deux
    // ensemble suffisent à garantir qu'aucun résultat périmé n'est publié.
    property int    runSeq:     -1
    property string runQuery:   ""
    property int    pendingSeq: -1
    property string pendingQuery: ""

    function search(query, seq) {
        if (query.length < src.minChars) {
            src.pendingSeq = -1;
            if (fdProc.running)
                fdProc.running = false;
            src.produced(seq, []);
            return;
        }

        src.pendingQuery = query;
        src.pendingSeq   = seq;

        if (fdProc.running)
            fdProc.running = false;   // annule ; onRunningChanged relancera
        else
            src._launch();
    }

    function _launch() {
        if (src.pendingSeq < 0)
            return;

        src.runSeq   = src.pendingSeq;
        src.runQuery = src.pendingQuery;
        var q = src.pendingQuery;
        src.pendingSeq = -1;
        src.pendingQuery = "";

        // Dossiers d'abord : `fd` termine déjà leurs chemins par « / », ce qui
        // suffit à les distinguer des fichiers dans la sortie.
        // `shift` laisse toutes les racines dans "$@" : une seule commande, quel
        // que soit leur nombre.
        src.fdProc.command = [
            "sh", "-c",
            "q=\"$1\"; shift; " +
            "fd -HFi --max-results 12 --type d " +
            "--exclude .git --exclude .cache --exclude node_modules -- \"$q\" \"$@\"; " +
            "fd -HFi --max-results 24 --type f " +
            "--exclude .git --exclude .cache --exclude node_modules -- \"$q\" \"$@\"",
            "--", q
        ].concat(src.roots);
        src.fdProc.running = true;
        src.guard.restart();
    }

    property Process fdProc: Process {
        stdout: StdioCollector { id: fdOut }
        onRunningChanged: {
            if (running)
                return;
            src.guard.stop();
            // Une requête en attente signifie que celle-ci a été annulée :
            // sa sortie est périmée, on ne la publie pas.
            if (src.runSeq >= 0 && src.pendingSeq < 0)
                src._parse(src.runSeq, fdOut.text);
            src.runSeq = -1;
            if (src.pendingSeq >= 0)
                src._launch();
        }
    }

    // Délai de garde : on coupe et on publie ce qui est déjà arrivé.
    property Timer guard: Timer {
        interval: src.timeoutMs
        onTriggered: if (src.fdProc.running) src.fdProc.running = false
    }

    function _parse(seq, text) {
        var lines = text.split("\n");
        var out = [];

        // Tout le flux est parcouru avant d'être classé : s'arrêter à `limit` ici
        // reviendrait à classer les premières lignes de `fd` au lieu des
        // meilleures. Comme la commande émet les dossiers d'abord, une poignée de
        // dossiers suffirait sinon à évincer tous les fichiers, quel que soit
        // leur score.
        for (var i = 0; i < lines.length; i++) {
            var path = lines[i];
            if (path.length === 0)
                continue;

            var isDir = path.charAt(path.length - 1) === "/";
            while (path.length > 1 && path.charAt(path.length - 1) === "/")
                path = path.substring(0, path.length - 1);

            var slash = path.lastIndexOf("/");
            var name  = slash >= 0 ? path.substring(slash + 1) : path;
            var dir   = slash >= 0 ? path.substring(0, slash) : "";
            var suffix = "";
            if (!isDir) {
                var dot = name.lastIndexOf(".");
                if (dot > 0)
                    suffix = name.substring(dot + 1);
            }

            out.push({
                type:     src.type,
                id:       "file:" + path,
                title:    name,
                subtitle: dir.indexOf(src.home) === 0 ? "~" + dir.substring(src.home.length) : dir,
                meta:     isDir ? "dossier" : suffix.toUpperCase(),
                tone:     isDir ? Theme.accentColor : src.toneFor(suffix),
                // Les correspondances sur le nom priment sur celles du chemin :
                // le repli doit donc rester sous le plus faible score de nom,
                // qui est celui d'une sous-séquence (150).
                score:    Fuzzy.score(src.runQuery, name) || 100,
                payload:  { path: path, isDir: isDir, suffix: suffix }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    readonly property var tones: [
        Theme.accentColor, Theme.colorCyan, Theme.colorSuccess,
        Theme.colorAmber,  Theme.colorCoral, Theme.colorAltBlue
    ]

    function toneFor(suffix) {
        if (!suffix || suffix.length === 0)
            return Theme.textSecondary;
        var h = 0;
        for (var i = 0; i < suffix.length; i++)
            h = (h * 31 + suffix.charCodeAt(i)) % 997;
        return src.tones[h % src.tones.length];
    }

    function _parentOf(path) {
        var slash = path.lastIndexOf("/");
        return slash > 0 ? path.substring(0, slash) : "/";
    }

    // Les outils viennent de DefaultApps, jamais d'un nom en dur : changer
    // d'éditeur, d'explorateur ou de terminal par défaut suffit à les rediriger.
    // « ouvrir » est la seule exception, et n'en est pas vraiment une : xdg-open
    // n'est pas une application, c'est le résolveur du système.
    function activate(item, actionId) {
        var p = item.payload.path;
        var dir = item.payload.isDir ? p : src._parentOf(p);

        switch (actionId) {
        case "open":     Quickshell.execDetached(["xdg-open", p]); break;
        case "editor":   DefaultApps.openInEditor(p); break;
        // Tous les gestionnaires de fichiers n'ouvrent pas un fichier de la
        // même façon ; on leur passe donc toujours un dossier.
        case "explorer": DefaultApps.openInExplorer(dir); break;
        case "terminal": DefaultApps.openInTerminal(dir); break;
        case "copy":     Quickshell.clipboardText = p; break;
        }
    }
}
