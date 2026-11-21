import QtQuick

// Source « tâche » : ce qu'on tape devient une tâche de Google Tâches
// (Agenda.createTask, la liste choisie dans le volet des tâches). Une seule
// ligne, et seulement quand le compte Google est connecté.
//
// Commencer par « tâche », « todo » ou « + » la met en tête de liste (et ôte
// le mot) ; sinon elle reste proposée en dernier, hors du seuil (`always`).
// « demain » ou « aujourd'hui » au début ou à la fin donne l'échéance.
QtObject {
    id: src

    readonly property string type:  "task"
    readonly property string label: I18n.tr("tasks.title")

    signal produced(int seq, var items)

    readonly property var prefixes: /^(?:t[âa]che|task|todo|\+)\s*:?\s+/i
    readonly property var dueWords: [
        { re: /^(?:demain|tomorrow)\s+|\s+(?:demain|tomorrow)$/i, days: 1 },
        { re: /^(?:aujourd['’]hui|today)\s+|\s+(?:aujourd['’]hui|today)$/i, days: 0 }
    ]

    // { title, due: "AAAA-MM-JJ" ou "", asked: préfixe présent }.
    function parse(query) {
        var t = query.trim();
        var asked = src.prefixes.test(t);
        if (asked)
            t = t.replace(src.prefixes, "");
        var due = "";
        for (var i = 0; i < src.dueWords.length; i++) {
            var w = src.dueWords[i];
            if (w.re.test(t)) {
                t = t.replace(w.re, "").trim();
                var d = new Date();
                d.setDate(d.getDate() + w.days);
                due = Agenda.dayKey(d);
                break;
            }
        }
        return { title: t.trim(), due: due, asked: asked };
    }

    function search(query, seq) {
        var p = src.parse(query);
        if (!Google.connected || p.title.length === 0) {
            src.produced(seq, []);
            return;
        }
        var when = p.due === "" ? ""
                 : p.due === Agenda.todayKey ? I18n.tr("tasks.due.today")
                 : I18n.tr("tasks.due.tomorrow");
        src.produced(seq, [{
            type:     src.type,
            id:       "task:new",
            title:    p.title,
            subtitle: I18n.tr("search.addTask") + (when !== "" ? " · " + when : ""),
            meta:     "",
            tone:     Theme.colorSuccess,
            // Demandée : au-dessus de tout ; sinon tout en bas.
            score:    p.asked ? 5000 : 0,
            always:   true,
            payload:  { title: p.title, due: p.due, asked: p.asked }
        }]);
    }

    function activate(item, actionId) {
        if (actionId !== "open")
            return;
        var list = Agenda.lists.some(l => l.id === Agenda.quickList) ? Agenda.quickList : "";
        Agenda.createTask(list, { title: item.payload.title, notes: "", due: item.payload.due });
    }
}
