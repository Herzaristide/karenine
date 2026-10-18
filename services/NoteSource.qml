import QtQuick
import Quickshell
import Quickshell.Io

// Source « note » : les notes de l'onglet Notes (anna/src/notes.rs), et de
// quoi en créer une avec ce qu'on vient de taper.
//
//   « pain »  →  ▣ Liste de courses · pain, lait     (Note)    ouvre l'onglet
//                ✎ pain                             (Créer une note)
//
// Les notes sont lues dans notes.json, suivi sur le disque : une recherche ne
// lance pas anna à chaque lettre. La création, elle, passe par
// `anna notes add`, comme l'onglet.
QtObject {
    id: src

    readonly property string type:  "note"
    readonly property string label: "Note"
    readonly property int    limit: 3

    signal produced(int seq, var items)

    property var notes: []

    property FileView file: FileView {
        path: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share")
              + "/anna/notes/notes.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                src.notes = JSON.parse(text()) || [];
            } catch (e) {
                src.notes = [];
            }
        }
    }

    // Le titre : la première ligne non vide ; le reste, en une ligne.
    function _lines(text) {
        return (text || "").split("\n").map(l => l.trim()).filter(l => l.length > 0);
    }

    function search(query, seq) {
        var q = query.trim();
        if (q.length === 0) {
            src.produced(seq, []);
            return;
        }

        var found = [];
        for (var i = 0; i < src.notes.length; i++) {
            var n = src.notes[i];
            var lines = src._lines(n.text);
            var title = lines.length > 0 ? lines[0] : "";
            var rest = lines.slice(1).join(" · ");
            var score = Fuzzy.best(q, [title, rest]);
            if (score <= 0)
                continue;
            found.push({
                type: src.type,
                id: "note:" + n.id,
                title: title.length > 0 ? title : I18n.tr("memo.image"),
                subtitle: n.image !== "" ? I18n.tr("memo.image") : rest,
                meta: "",
                tone: Theme.accentColor,
                score: score + (n.pinned ? 20 : 0),
                payload: { note: n }
            });
        }
        found.sort(function (a, b) { return b.score - a.score; });
        found = found.slice(0, src.limit);

        // Toujours là, sous les résultats qui comptent : ce qu'on tape peut
        // devenir une note (Search la garde hors du seuil, comme le web).
        found.push({
            type: src.type,
            id: "note:create",
            title: q,
            subtitle: I18n.tr("memo.create"),
            meta: "",
            tone: Theme.accentColor,
            score: 65,
            always: true,
            payload: { create: true }
        });

        src.produced(seq, found);
    }

    function activate(item, actionId) {
        if (actionId !== "open")
            return;
        if (item.payload.create)
            Quickshell.execDetached(["anna", "notes", "add", item.title]);
        else
            Widgets.apply("notes", "ouvrir");
    }
}
