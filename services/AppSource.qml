import QtQuick
import Quickshell

// Source « applications » : les entrées .desktop, exposées nativement par
// Quickshell. Aucun processus, aucun index — la liste est déjà en mémoire.
QtObject {
    id: src

    readonly property string type:  "app"
    readonly property string label: "Applications"
    readonly property int    limit: 6

    signal produced(int seq, var items)

    // La liste des .desktop se peuple de façon asynchrone au démarrage : une
    // recherche lancée trop tôt ne verrait rien. On rejoue donc la dernière
    // requête quand elle arrive — Search jette la réponse si elle a vieilli.
    property string _lastQuery: ""
    property int    _lastSeq: -1

    property Connections _watch: Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            if (src._lastSeq >= 0)
                src.search(src._lastQuery, src._lastSeq);
        }
    }

    function search(query, seq) {
        src._lastQuery = query;
        src._lastSeq = seq;

        var apps = DesktopEntries.applications.values;
        var out = [];

        for (var i = 0; i < apps.length; i++) {
            var e = apps[i];
            if (!e || e.noDisplay)
                continue;

            var score = Fuzzy.best(query, [e.name, e.genericName, e.comment,
                                           (e.keywords || []).join(" ")]);
            if (score <= 0)
                continue;

            out.push({
                type:     src.type,
                id:       "app:" + e.id,
                title:    e.name,
                subtitle: e.genericName || e.comment || "",
                meta:     "",
                tone:     Theme.accentColor,
                score:    score,
                payload:  { entry: e }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    function activate(item, actionId) {
        if (actionId === "open" && item.payload.entry)
            item.payload.entry.execute();
    }
}
