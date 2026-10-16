import QtQuick
import Quickshell
import Quickshell.Io

// Source « fonds d'écran » : les vidéos que la commande `wallpaper` (fournie
// par la configuration NixOS, qui lance mpvpaper) trouve dans son dossier.
// Taper « fond » les liste toutes ; taper un bout de nom filtre. Ouvrir une
// carte la met en fond, à chaud — le lecteur ne redémarre pas.
//
// La liste est relue à chaque recherche : c'est un `find` sur un seul dossier,
// et une vidéo qu'on vient d'y déposer apparaît sans rien relancer.
QtObject {
    id: src

    readonly property string type:  "wallpaper"
    readonly property string label: "Fonds d'écran"
    readonly property int    limit: 8

    readonly property string keywords: "fond fonds écran ecran wallpaper vidéo video animé anime"

    signal produced(int seq, var items)

    property int    runSeq:   -1
    property string runQuery: ""

    function search(query, seq) {
        // Une seule liste en vol : la précédente est périmée, on la laisse
        // finir mais on ne publiera que la dernière.
        src.runSeq = seq;
        src.runQuery = query;
        if (!listProc.running)
            listProc.running = true;
    }

    property Process listProc: Process {
        command: ["wallpaper", "list"]
        stdout: StdioCollector { id: listOut }
        onRunningChanged: {
            if (running || src.runSeq < 0)
                return;
            src._parse(src.runSeq, src.runQuery, listOut.text);
        }
    }

    function _parse(seq, query, text) {
        var lines = text.split("\n");
        var out = [];

        for (var i = 0; i < lines.length; i++) {
            var tab = lines[i].indexOf("\t");
            if (tab < 0)
                continue;
            var current = lines[i].substring(0, tab) === "*";
            var path = lines[i].substring(tab + 1);
            var name = path.substring(path.lastIndexOf("/") + 1);
            var dot = name.lastIndexOf(".");
            var stem = dot > 0 ? name.substring(0, dot) : name;

            // Le nom prime ; les mots-clés ne servent qu'à tout faire remonter
            // d'un coup quand on demande « fond ».
            var score = Math.max(Fuzzy.score(query, stem),
                                 Fuzzy.score(query, src.keywords) - 200);
            if (score <= 0)
                continue;

            out.push({
                type:     src.type,
                id:       "wallpaper:" + path,
                title:    stem,
                subtitle: current ? "fond actuel" : "fond d'écran",
                meta:     dot > 0 ? name.substring(dot + 1).toUpperCase() : "",
                tone:     current ? Theme.accentColor : Theme.colorCyan,
                score:    score,
                payload:  { path: path, current: current }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    function activate(item, actionId) {
        if (actionId === "open")
            Quickshell.execDetached(["wallpaper", "set", item.payload.path]);
    }
}
