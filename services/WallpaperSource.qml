import QtQuick
import Quickshell
import Quickshell.Io

// Source « fonds d'écran » : les vidéos que la commande `wallpaper` (fournie
// par la configuration NixOS, qui lance mpvpaper) trouve dans son dossier.
// Taper « fond » les liste toutes ; taper un bout de nom filtre. Ouvrir une
// carte la met en fond, à chaud — le lecteur ne redémarre pas.
//
// La liste est gardée `freshMs` : les lettres d'une même frappe la
// réutilisent au lieu de relancer `wallpaper list` chacune. Au-delà, elle est
// relue : une vidéo qu'on vient de déposer apparaît sans rien relancer.
QtObject {
    id: src

    readonly property string type:  "wallpaper"
    readonly property string label: I18n.tr("search.wallpapers")
    readonly property int    limit: 8

    readonly property string keywords: "fond fonds écran ecran wallpaper background vidéo video animé anime animated"

    signal produced(int seq, var items)

    property int    runSeq:   -1
    property string runQuery: ""

    readonly property int freshMs: 10000
    property string _list: ""
    property double _listAt: 0

    function search(query, seq) {
        src.runSeq = seq;
        src.runQuery = query;
        if (src._listAt > 0 && Date.now() - src._listAt < src.freshMs) {
            src._parse(seq, query, src._list);
            return;
        }
        // Une seule liste en vol : la précédente est périmée, on la laisse
        // finir mais on ne publiera que la dernière.
        if (!listProc.running)
            listProc.running = true;
    }

    property Process listProc: Process {
        command: ["wallpaper", "list"]
        stdout: StdioCollector { id: listOut }
        onRunningChanged: {
            if (running)
                return;
            src._list = listOut.text;
            src._listAt = Date.now();
            if (src.runSeq >= 0)
                src._parse(src.runSeq, src.runQuery, src._list);
        }
    }

    // Une vidéo mise en fond change la liste (son « * ») : relue au prochain coup.
    function _forget() {
        src._listAt = 0;
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
                subtitle: current ? I18n.tr("search.wallpaperCurrent") : I18n.tr("search.wallpaper"),
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
        if (actionId === "open") {
            Quickshell.execDetached(["wallpaper", "set", item.payload.path]);
            src._forget();
        }
    }
}
