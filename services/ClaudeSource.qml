import QtQuick
import Quickshell
import Quickshell.Io

// Source « conversations Claude ». Deux corpus locaux, indexés une fois puis
// gardés en mémoire — jamais de relecture disque par frappe :
//   • les sessions Claude Code (~/.claude/projects/*/*.jsonl), présentes tout
//     de suite, reprenables dans un terminal ;
//   • les sessions de Claude Desktop (~/.config/Claude/claude-code-sessions),
//     qui n'apparaissent qu'une fois les « OS entry points » activés dans
//     l'app, et qui s'ouvrent par claude://code/continue — exactement l'URL
//     qu'utilise le search provider GNOME livré avec Claude Desktop.
QtObject {
    id: src

    readonly property string type:  "conversation"
    readonly property string label: "Conversations"
    readonly property int    limit: 5

    readonly property string home: Quickshell.env("HOME") || "/home"
    readonly property int    staleMs: 60000

    signal produced(int seq, var items)

    property string _lastQuery: ""
    property int    _lastSeq: -1

    property var _index: []
    property double _indexedAt: 0
    property bool _indexing: false

    // Un index vide reste un index : sans cette nuance, une machine sans session
    // Claude relancerait le balayage à chaque frappe — et, le rejeu de la requête
    // ci-dessous repassant par ici, en boucle sans fin.
    function _ensureIndex() {
        if (src._indexing)
            return;
        if (src._indexedAt > 0 && Date.now() - src._indexedAt < src.staleMs)
            return;
        src._indexing = true;
        indexProc.running = true;
    }

    property Process indexProc: Process {
        command: ["sh", "-c",
            'for f in "$HOME"/.claude/projects/*/*.jsonl; do ' +
            '  [ -e "$f" ] || continue; ' +
            '  id=$(basename "$f" .jsonl); ' +
            '  t=$(grep -a \'"type":"ai-title"\' "$f" | tail -1 | jq -r \'.aiTitle // empty\' 2>/dev/null); ' +
            '  [ -n "$t" ] || t=$(grep -a \'"type":"last-prompt"\' "$f" | tail -1 | jq -r \'.lastPrompt // empty\' 2>/dev/null); ' +
            '  c=$(grep -ao \'"cwd":"[^"]*"\' "$f" | head -1 | cut -d\'"\' -f4); ' +
            '  printf \'cli\\t%s\\t%s\\t%s\\t%s\\n\' "$id" "$c" "$(stat -c %Y "$f")" "$t"; ' +
            'done; ' +
            'for f in "$HOME"/.config/Claude/claude-code-sessions/*/*/local_*.json; do ' +
            '  [ -e "$f" ] || continue; ' +
            '  jq -r \'["desktop", .sessionId, (.cwd // ""), ((.lastActivityAt // 0)|tostring), (.title // "")] | @tsv\' "$f" 2>/dev/null; ' +
            'done'
        ]
        stdout: StdioCollector { id: indexOut }
        onRunningChanged: {
            if (running)
                return;
            src._buildIndex(indexOut.text);
            src._indexing = false;
            src._indexedAt = Date.now();
            // L'index arrive après coup : on rejoue la dernière requête.
            if (src._lastSeq >= 0)
                src.search(src._lastQuery, src._lastSeq);
        }
    }

    function _buildIndex(text) {
        var lines = text.split("\n");
        var out = [];

        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length < 5 || f[1].length === 0)
                continue;

            var title = f[4].trim();
            if (title.length === 0)
                title = "Session sans titre";

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
                title:   title.length > 90 ? title.substring(0, 89) + "…" : title
            });
        }

        out.sort(function (a, b) { return b.at - a.at; });
        src._index = out;
    }

    function _ago(ts) {
        if (!ts)
            return "";
        var s = Date.now() / 1000 - ts;
        if (s < 3600)  return Math.max(1, Math.round(s / 60)) + " min";
        if (s < 86400) return Math.round(s / 3600) + " h";
        if (s < 604800) return Math.round(s / 86400) + " j";
        return Qt.formatDateTime(new Date(ts * 1000), "dd/MM");
    }

    function search(query, seq) {
        src._lastQuery = query;
        src._lastSeq = seq;
        src._ensureIndex();

        var out = [];
        for (var i = 0; i < src._index.length; i++) {
            var c = src._index[i];
            var score = Fuzzy.best(query, [c.title, c.project]);
            if (score <= 0)
                continue;

            out.push({
                type:     src.type,
                id:       "conv:" + c.id,
                title:    c.title,
                subtitle: c.project,
                meta:     src._ago(c.at),
                tone:     Theme.colorCoral,
                score:    score,
                payload:  { id: c.id, kind: c.kind, cwd: c.cwd }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    function activate(item, actionId) {
        var p = item.payload;
        switch (actionId) {
        case "open":
            // Détaché : la session ouverte doit survivre à un redémarrage du shell.
            Quickshell.execDetached(["claude-desktop",
                "claude://code/continue?session=" + encodeURIComponent(p.id)
                + "&source=karenine"]);
            break;
        case "resume":
            // L'émulateur vient de DefaultApps, comme partout ailleurs : le nom
            // en dur d'un terminal ne survit pas au premier changement de défaut.
            DefaultApps.runInTerminal(p.cwd || src.home,
                                      ["claude", "--resume", p.id]);
            break;
        case "copy":
            Quickshell.clipboardText = p.id;
            break;
        }
    }
}
