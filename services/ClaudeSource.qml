import QtQuick
import Quickshell

// Source « conversations Claude » pour la recherche du dock. Elle ne balaye
// rien elle-même : l'index vit dans [ClaudeSessions], partagé avec le mode IA
// du dock, et il est construit une fois pour toutes les deux.
//
// Les sessions de Claude Code (CLI) se reprennent dans un terminal ; celles de
// Claude Desktop s'ouvrent dans l'application par claude://code/continue —
// exactement l'URL qu'utilise le search provider GNOME livré avec.
QtObject {
    id: src

    readonly property string type:  "conversation"
    readonly property string label: "Conversations"
    readonly property int    limit: 5

    signal produced(int seq, var items)

    property string _lastQuery: ""
    property int    _lastSeq: -1

    // L'index arrive après coup : on rejoue la dernière requête quand il tombe.
    property Connections _onIndexed: Connections {
        target: ClaudeSessions
        function onIndexed() {
            if (src._lastSeq >= 0)
                src.search(src._lastQuery, src._lastSeq);
        }
    }

    function search(query, seq) {
        src._lastQuery = query;
        src._lastSeq = seq;
        ClaudeSessions.ensureIndex();

        var all = ClaudeSessions.sessions;
        var out = [];

        for (var i = 0; i < all.length; i++) {
            var c = all[i];
            var score = Fuzzy.best(query, [c.title, c.project]);
            if (score <= 0)
                continue;

            out.push({
                type:     src.type,
                id:       "conv:" + c.id,
                title:    c.title,
                subtitle: c.project,
                meta:     ClaudeSessions.ago(c.at),
                tone:     Theme.colorCoral,
                score:    score,
                payload:  { id: c.id, kind: c.kind, cwd: c.cwd, path: c.path }
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
            DefaultApps.runInTerminal(p.cwd || ClaudeSessions.home,
                                      ["claude", "--resume", p.id]);
            break;
        case "copy":
            Quickshell.clipboardText = p.id;
            break;
        }
    }
}
