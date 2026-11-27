pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les dossiers récents : ceux de zoxide (fréquence et récence, alimenté par
// le shell et par visit()), complétés des sessions Claude de la semaine, qui
// ne passent pas toujours par un `cd`. Lus d'avance et gardés en mémoire :
// une frappe ne lance aucun processus. Sans zoxide, restent les sessions.
//
//   dirs      [{ path, score }]  chaque dossier, le plus utilisé d'abord
//   projects  [{ dir, name }]    ramenés à leur projet, les premiers
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || "/home"
    property var dirs: []
    // Le score de chaque dossier, et son projet : { chemin: … }.
    property var scores: ({})
    property var roots: ({})
    property real top: 0

    readonly property int maxProjects: 10
    readonly property var projects: {
        var by = {};
        root.dirs.forEach(d => {
            var r = root.projectOf(d.path);
            if (root.isProject(r))
                by[r] = (by[r] || 0) + d.score;
        });
        return root.named(Object.keys(by).sort((a, b) => by[b] - by[a] || a.localeCompare(b))
                                .slice(0, root.maxProjects));
    }

    // Des dossiers avec leur nom ; deux du même nom se distinguent par le
    // dossier qui les contient.
    function named(list) {
        var base = p => p.substring(p.lastIndexOf("/") + 1);
        return list.map(p => {
            var twin = list.some(o => o !== p && base(o) === base(p));
            return { dir: p, name: twin ? p.split("/").slice(-2).join("/") : base(p) };
        });
    }

    // Le projet d'un dossier : son dépôt git, sinon son dossier dans ~/code.
    function projectOf(path) {
        return root.roots[path] || path;
    }

    // Ni jetable ou monté, ni le dossier personnel, ni celui qui les range.
    function temporary(p) {
        return p === "/tmp" || p.startsWith("/tmp/") || p.startsWith("/run/") || p.startsWith("/nix/store/")
            || p.indexOf("/.config/Claude/scratch-workspaces/") >= 0 || p.indexOf("/.local/share/Trash/") >= 0;
    }
    function isProject(p) {
        return p !== "" && p !== "/" && p !== root.home && p !== root.home + "/code" && !root.temporary(p);
    }

    // De 0 à 250, sur une échelle logarithmique : départage des noms qui
    // correspondent aussi bien, sans qu'un dossier très visité écrase tout.
    function boost(path) {
        var s = root.scores[path] || 0;
        return s > 0 && root.top > 0 ? 250 * Math.log(1 + s) / Math.log(1 + root.top) : 0;
    }

    // Un dossier vraiment utilisé (ouvert, choisi), à compter comme un `cd`.
    function visit(path) {
        if (!path || path.charAt(0) !== "/" || path === root.home || root.temporary(path))
            return;
        Quickshell.execDetached(["zoxide", "add", "--", path]);
        later.restart();
    }

    property bool _again: false
    function refresh() {
        if (proc.running) {
            root._again = true;
            return;
        }
        var weights = {};
        var args = [];
        root._sessions().forEach(s => {
            if (weights[s.cwd] === undefined)
                args.push(s.cwd);
            weights[s.cwd] = (weights[s.cwd] || 0) + s.weight;
        });
        proc.weights = weights;
        proc.command = ["sh", "-c", root._script, "--"].concat(args);
        proc.running = true;
    }

    // Les sessions de la semaine, pondérées par leur âge comme zoxide.
    function _sessions() {
        var now = Date.now();
        return ClaudeSessions.live.concat(ClaudeSessions.recent)
            .filter(s => s.cwd && s.cwd.indexOf("\n") < 0 && now - s.updated < 7 * 86400000)
            .map(s => ({ cwd: s.cwd, weight: now - s.updated < 3600000 ? 4 : now - s.updated < 86400000 ? 2 : 0.5 }));
    }

    // Une ligne « score<TAB>projet<TAB>dossier » par dossier qui existe ; le
    // score est vide pour un dossier de session. Un worktree (.git fichier)
    // n'est pas une racine : on remonte au dépôt. Les montages (/run) ne
    // sont pas touchés : un sshfs mort bloquerait.
    readonly property string _script:
        "h=$HOME\n" +
        "one() {\n" +
        "  case $2 in /run/*|/tmp/*|/nix/store/*) return;; esac\n" +
        "  [ -d \"$2\" ] || return\n" +
        "  d=$2; r=\n" +
        "  while [ -n \"$d\" ] && [ \"$d\" != \"$h\" ]; do\n" +
        "    if [ -d \"$d/.git\" ]; then r=$d; break; fi\n" +
        "    d=${d%/*}\n" +
        "  done\n" +
        "  if [ -z \"$r\" ]; then\n" +
        "    case $2 in\n" +
        "      \"$h\"/code/*) x=${2#\"$h\"/code/}; r=$h/code/${x%%/*};;\n" +
        "      *) r=$2;;\n" +
        "    esac\n" +
        "  fi\n" +
        "  printf '%s\\t%s\\t%s\\n' \"$1\" \"$r\" \"$2\"\n" +
        "}\n" +
        "zoxide query -ls 2>/dev/null | while read -r s p; do one \"$s\" \"$p\"; done\n" +
        "for p in \"$@\"; do one '' \"$p\"; done\n"

    Process {
        id: proc
        property var weights: ({})
        stdout: StdioCollector {
            onStreamFinished: root._parse(this.text, proc.weights)
        }
        onRunningChanged: {
            if (!running && root._again) {
                root._again = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    function _parse(text, weights) {
        var scores = {};
        var roots = {};
        text.split("\n").forEach(line => {
            var f = line.split("\t");
            if (f.length !== 3)
                return;
            roots[f[2]] = f[1];
            scores[f[2]] = (scores[f[2]] || 0) + (f[0] === "" ? weights[f[2]] || 0 : parseFloat(f[0]) || 0);
        });
        var list = Object.keys(scores).map(p => ({ path: p, score: scores[p] }))
            .sort((a, b) => b.score - a.score || a.path.localeCompare(b.path));
        root.roots = roots;
        root.scores = scores;
        root.top = list.length > 0 ? list[0].score : 0;
        root.dirs = list;
    }

    // Les dossiers des sessions changent : relus ; leur activité, non.
    readonly property string _sessionKey: root._sessions().map(s => s.cwd).sort()
        .filter((c, i, all) => i === 0 || c !== all[i - 1]).join("\n")
    on_SessionKeyChanged: later.restart()

    // `zoxide add` vient d'être lancé : le temps qu'il écrive.
    Timer {
        id: later
        interval: 400
        onTriggered: root.refresh()
    }
    // Les `cd` des terminaux.
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
