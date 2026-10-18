pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les conversations Claude vues depuis le shell : l'index de ce qui existe sur
// le disque.
//
// Un seul indexeur pour deux consommateurs — la recherche de la barre
// ([ClaudeSource]) et l'historique du dock IA.
//
// Sur le disque, une session Claude Code est un JSONL append-only :
//   ~/.claude/projects/<cwd-slugifié>/<sessionId>.jsonl
// une ligne JSON par événement, le fichier même que `claude --resume` rouvre.
//
// Le travail sale est dans un script voisin, claude-index.sh : du shell qui
// reste lisible et testable en shell, plutôt que la même chose échappée au
// travers d'une chaîne JavaScript.
QtObject {
    id: root

    readonly property string home: Quickshell.env("HOME") || "/home"

    // Les scripts vivent à côté de ce fichier. `Qt.resolvedUrl` suit le QML où
    // qu'il soit installé — dépôt de travail ou store Nix —, ce qui garde le
    // layout relocalisable.
    readonly property string scriptDir:
        Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

    // ── Index ────────────────────────────────────────────────────
    // Balayé une fois puis gardé en mémoire : aucune relecture disque par
    // frappe. Un index vide reste un index, sinon une machine sans session
    // relancerait le balayage à chaque appel.
    property var sessions: []
    property bool indexing: false
    property double indexedAt: 0
    readonly property int staleMs: 60000

    signal indexed()

    // Le mode IA ne montre que les sessions Claude Code : ce sont les seules
    // dont on sache lire le transcript et reprendre le fil.
    readonly property var liveSessions: root.sessions.filter(function (s) {
        return s.kind === "cli" && s.path.length > 0;
    })

    function ensureIndex() {
        if (root.indexing)
            return;
        if (root.indexedAt > 0 && Date.now() - root.indexedAt < root.staleMs)
            return;
        root.indexing = true;
        indexProc.running = true;
    }

    function refresh() {
        root.indexedAt = 0;
        root.ensureIndex();
    }

    property Process indexProc: Process {
        command: ["sh", root.scriptDir + "claude-index.sh"]
        stdout: StdioCollector { id: indexOut }

        onRunningChanged: {
            if (running)
                return;
            root._buildIndex(indexOut.text);
            root.indexing = false;
            root.indexedAt = Date.now();
            root.indexed();
        }
    }

    function _buildIndex(text) {
        var lines = text.split("\n");
        var out = [];

        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length < 6 || f[1].length === 0)
                continue;

            var title = f[5].trim();
            if (title.length === 0)
                title = I18n.tr("session.untitled");

            var ts = parseFloat(f[3]) || 0;
            if (ts > 1e11)      // millisecondes côté Claude Desktop
                ts = ts / 1000;

            var cwd = f[2];
            var slash = cwd.lastIndexOf("/");

            out.push({
                kind:    f[0],
                id:      f[1],
                cwd:     cwd,
                project: slash >= 0 ? cwd.substring(slash + 1) : cwd,
                at:      ts,
                path:    f[4],
                title:   title.length > 90 ? title.substring(0, 89) + "…" : title
            });
        }

        out.sort(function (a, b) { return b.at - a.at; });
        root.sessions = out;
    }

    function ago(ts) {
        if (!ts)
            return "";
        var s = Date.now() / 1000 - ts;
        if (s < 3600)   return I18n.tr("time.minutes", { n: Math.max(1, Math.round(s / 60)) });
        if (s < 86400)  return I18n.tr("time.hours", { n: Math.round(s / 3600) });
        if (s < 604800) return I18n.tr("time.days", { n: Math.round(s / 86400) });
        return Qt.formatDateTime(new Date(ts * 1000), "dd/MM");
    }
}
