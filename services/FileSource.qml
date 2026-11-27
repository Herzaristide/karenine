import QtQuick
import Quickshell
import Quickshell.Io

// Source « fichiers et dossiers » : `fd` dans un processus séparé, donc jamais
// sur le thread de rendu. Une seule requête en vol à la fois — la précédente
// est tuée — et un délai de garde qui coupe court si l'arborescence est énorme.
QtObject {
    id: src

    readonly property string type:  "file"
    readonly property string label: I18n.tr("search.files")
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

        // `fd` termine les chemins des dossiers par « / », ce qui suffit à
        // les distinguer des fichiers dans la sortie.
        // `shift` laisse toutes les racines dans "$@" : une seule commande, quel
        // que soit leur nombre.
        // Les gros arbres sans fichier qu'on chercherait (caches, chaînes
        // d'outils, builds, environnements Python, couches de Docker)
        // restent hors du parcours : à chaque requête, fd les traversait pour
        // rien. Docker seul pesait 490 000 fichiers sur 590 000, et une
        // recherche sans résultat proche plus d'une seconde. Il en reste
        // 7 000 : ce qu'on a écrit ou posé soi-même.
        var excl = "--exclude .git --exclude .cache --exclude node_modules " +
                   "--exclude .cargo --exclude .rustup --exclude .npm --exclude target " +
                   "--exclude .direnv --exclude .venv " +
                   "--exclude .local/share/Trash --exclude .local/share/Steam " +
                   "--exclude .local/share/docker --exclude .local/share/containers " +
                   "--exclude .local/share/uv --exclude .local/share/zed " +
                   // Corbeilles des autres disques, index, modèles, caches GL.
                   "--exclude '.Trash-*' --exclude .codegraph --exclude .ollama --exclude .nv " +
                   // Thèmes d'icônes : des milliers de SVG.
                   "--exclude .icons --exclude .local/share/icons " +
                   // L'intérieur des applications (profil du navigateur,
                   // Claude Desktop, Claude Code ; ~/.claude/skills et
                   // CLAUDE.md restent trouvables).
                   "--exclude .config/chromium --exclude .config/Claude " +
                   "--exclude .claude/plugins --exclude .claude/projects " +
                   "--exclude .claude/paste-cache --exclude .claude/shell-snapshots " +
                   "--exclude .claude/jobs --exclude .claude/telemetry " +
                   "--exclude .claude/backups --exclude .claude/sessions --exclude .claude/cache " +
                   // Les extraits d'entraînement des mots d'éveil
                   // (code/lab/wakeword-*/model/<mot>/) : 42 000 fichiers.
                   "--exclude positive_train --exclude positive_test " +
                   "--exclude negative_train --exclude negative_test ";
        // Les deux parcours en même temps ; les dossiers passent par un
        // fichier pour que leurs lignes ne se mêlent pas à celles des
        // fichiers.
        src.fdProc.command = [
            "sh", "-c",
            "q=\"$1\"; shift; d=$(mktemp); " +
            "trap 'kill $! 2>/dev/null; rm -f \"$d\"; exit' TERM; " +
            "fd -HFi --max-results 12 --type d " + excl + "-- \"$q\" \"$@\" > \"$d\" & " +
            "fd -HFi --max-results 24 --type f " + excl + "-- \"$q\" \"$@\"; " +
            "wait; cat \"$d\"; rm -f \"$d\"",
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
        var seen = {};

        // Les dossiers récents dont le nom correspond : fd s'arrête aux
        // premiers trouvés, qui ne sont pas les plus utilisés.
        lines = Places.dirs.filter(d => Fuzzy.score(src.runQuery, d.path.substring(d.path.lastIndexOf("/") + 1)) > 150)
            .slice(0, 8).map(d => d.path + "/").concat(lines);

        // Tout le flux est parcouru avant d'être classé : s'arrêter à `limit` ici
        // reviendrait à classer les premières lignes de `fd` au lieu des
        // meilleures. Comme la commande émet les fichiers puis les dossiers, une
        // poignée des uns suffirait sinon à évincer tous les autres, quel que
        // soit leur score.
        for (var i = 0; i < lines.length; i++) {
            var path = lines[i];
            if (path.length === 0)
                continue;

            var isDir = path.charAt(path.length - 1) === "/";
            while (path.length > 1 && path.charAt(path.length - 1) === "/")
                path = path.substring(0, path.length - 1);

            if (seen[path])
                continue;
            seen[path] = true;

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
                meta:     isDir ? I18n.tr("search.folder") : suffix.toUpperCase(),
                tone:     isDir ? Theme.accentColor : src.toneFor(suffix),
                // Les correspondances sur le nom priment sur celles du chemin :
                // le repli doit donc rester sous le plus faible score de nom,
                // qui est celui d'une sous-séquence (150).
                score:    src._rank(Fuzzy.score(src.runQuery, name) || 100, path) + src._usage(path, isDir),
                payload:  { path: path, isDir: isDir, suffix: suffix }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    // Un fichier caché ou enfoui est rarement celui qu'on cherche : `fd -H`
    // remonte ~/.local, ~/.mozilla… qui noyaient les vrais résultats.
    function _rank(score, path) {
        var rel = path.indexOf(src.home) === 0 ? path.substring(src.home.length) : path;
        var depth = rel.split("/").length - 2;
        var hidden = /\/\./.test(rel);
        return Math.max(1, score - (hidden ? 250 : 0) - Math.min(depth, 8) * 15);
    }

    // Ce qu'on utilise passe devant ; un fichier, un peu, par son projet.
    function _usage(path, isDir) {
        if (isDir)
            return Places.boost(path);
        for (var p = src._parentOf(path); p.length > 1; p = src._parentOf(p))
            if (Places.scores[p] !== undefined)
                return Places.boost(p) * 0.4;
        return 0;
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

        if (actionId !== "copy")
            Places.visit(dir);

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
