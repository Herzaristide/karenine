pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les événements et les tâches de l'onglet Agenda, lus par
// `anna agenda <du> <au>` et `anna tasks` dans le compte Google
// (anna/src/google/). Un mois demandé s'affiche tout de suite s'il a déjà
// été lu (le cache vit tant que le shell tourne), puis se relit derrière.
//
// anna donne les heures en texte : `…T14:00:00Z` (UTC), `2026-10-22`
// (toute la journée, `end` exclue). Ici, elles deviennent des Date, et
// chaque jour local reçoit ses événements.
//
// Les tâches, toutes listes confondues, se lisent d'un coup ; Google ne
// garde que leur jour d'échéance (`due`, "" sans échéance). Cocher une tâche
// la coche ici tout de suite, puis chez Google (`anna tasks done`).
Singleton {
    id: agenda

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    // Les listes ({ id, title }) et les tâches ({ list, id, title, notes,
    // due, done, parent, position }).
    property var lists: []
    property var tasks: []
    property string tasksError: ""

    // Les calendriers ({ id, name, color }) et les événements (avec
    // `startDate`, `endDate`) du dernier mois lu.
    property var calendars: []
    property var events: []
    property bool loading: false
    property string error: ""
    // Le mois affiché : "2026-10".
    property string month: ""

    property var _cache: ({})
    property string _want: ""

    // "AAAA-MM-JJ" d'une Date, en heure locale.
    function dayKey(d) {
        function two(n) { return n < 10 ? "0" + n : "" + n; }
        return d.getFullYear() + "-" + two(d.getMonth() + 1) + "-" + two(d.getDate());
    }

    function _parse(text) {
        // Un jour entier : à minuit, heure locale (Date("2026-10-22") serait
        // minuit UTC).
        if (text.length === 10) {
            var p = text.split("-");
            return new Date(+p[0], +p[1] - 1, +p[2]);
        }
        return new Date(text);
    }

    // Le premier jour de la grille d'un mois : le lundi (ou le premier jour
    // de la semaine de la langue) qui le précède.
    function gridStart(year, month) {
        var first = new Date(year, month, 1);
        var weekStart = I18n.locale.firstDayOfWeek % 7;
        var back = (first.getDay() - weekStart + 7) % 7;
        return new Date(year, month, 1 - back);
    }

    // Le mois (0-11) de `year` : six semaines, de quoi remplir la grille.
    function load(year, month) {
        var key = year + "-" + (month + 1);
        var start = agenda.gridStart(year, month);
        var end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 42);
        agenda.month = key;
        var cached = agenda._cache[key];
        if (cached) {
            agenda.calendars = cached.calendars;
            agenda.events = cached.events;
        }
        agenda._want = key;
        agenda.error = "";
        proc.key = key;
        proc.command = [agenda.anna, "agenda", agenda.dayKey(start), agenda.dayKey(end)];
        if (proc.running) {
            // Le mois change pendant une lecture : relancée à sa fin.
            proc.again = true;
            return;
        }
        agenda.loading = true;
        proc.running = true;
        agenda.loadTasks();
    }

    function reloadAll() {
        agenda._cache = ({});
        if (agenda.month !== "") {
            var p = agenda.month.split("-");
            agenda.load(+p[0], +p[1] - 1);
        }
    }

    // Le compte change : rien de l'ancien ne reste.
    Connections {
        target: Google
        function onGenerationChanged() {
            agenda.calendars = [];
            agenda.events = [];
            agenda.lists = [];
            agenda.tasks = [];
            agenda.reloadAll();
        }
    }

    // Les événements d'un jour local, du plus tôt au plus tard (les journées
    // entières d'abord).
    function on(day) {
        var from = new Date(day.getFullYear(), day.getMonth(), day.getDate());
        var to = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
        return agenda.events
            .filter(e => e.startDate < to && (e.endDate > from || (+e.endDate === +e.startDate && e.startDate >= from)))
            .sort((a, b) => (b.allDay - a.allDay) || (a.startDate - b.startDate));
    }

    function color(calendarId) {
        var c = agenda.calendars.find(c => c.id === calendarId);
        return c && c.color ? c.color : Theme.accentColor;
    }

    Process {
        id: proc
        property string key: ""
        property bool again: false
        stdout: StdioCollector { id: out }
        onRunningChanged: {
            if (running)
                return;
            if (proc.again) {
                proc.again = false;
                proc.running = true;
                return;
            }
            agenda.loading = false;
            try {
                var r = JSON.parse(out.text);
                if (!r.ok) {
                    agenda.error = r.error || I18n.tr("common.failedSentence");
                    return;
                }
                var events = r.events.map(e => Object.assign({}, e, {
                    startDate: agenda._parse(e.start),
                    endDate: agenda._parse(e.end)
                }));
                var c = Object.assign({}, agenda._cache);
                c[proc.key] = { calendars: r.calendars, events: events };
                agenda._cache = c;
                if (proc.key === agenda._want) {
                    agenda.calendars = r.calendars;
                    agenda.events = events;
                }
            } catch (e) {
                agenda.error = I18n.tr("anna.noAnswer");
            }
        }
    }

    // ── Les tâches ───────────────────────────────────────────────

    function loadTasks() {
        if (!taskProc.running)
            taskProc.running = true;
    }

    // Les tâches dues un jour local : à faire d'abord, dans l'ordre de Google.
    function tasksOn(day) {
        var key = agenda.dayKey(day);
        return agenda.tasks
            .filter(t => t.due === key)
            .sort((a, b) => (a.done - b.done) || (a.position < b.position ? -1 : a.position > b.position ? 1 : 0));
    }

    function listTitle(listId) {
        var l = agenda.lists.find(l => l.id === listId);
        return l ? l.title : "";
    }

    // Cochée (ou décochée) ici tout de suite, puis chez Google ; un échec
    // la remet comme elle était.
    function setDone(task, done) {
        agenda._mark(task, done);
        doneProc.queue.push({ task: task, done: done });
        doneProc.next();
    }

    function _mark(task, done) {
        agenda.tasks = agenda.tasks.map(t => t.list === task.list && t.id === task.id
                                             ? Object.assign({}, t, { done: done }) : t);
    }

    Process {
        id: taskProc
        command: [agenda.anna, "tasks"]
        stdout: StdioCollector { id: taskOut }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(taskOut.text);
                if (!r.ok) {
                    agenda.tasksError = r.error || I18n.tr("common.failedSentence");
                    return;
                }
                agenda.tasksError = "";
                agenda.lists = r.lists;
                // Une coche partie pendant la lecture : la sienne reste.
                var waiting = doneProc.queue.concat(doneProc.current ? [doneProc.current] : []);
                agenda.tasks = r.tasks.map(t => {
                    var w = waiting.find(w => w.task.list === t.list && w.task.id === t.id);
                    return w ? Object.assign({}, t, { done: w.done }) : t;
                });
            } catch (e) {
                agenda.tasksError = I18n.tr("anna.noAnswer");
            }
        }
    }

    // Les coches, l'une après l'autre.
    Process {
        id: doneProc
        property var queue: []
        property var current: null
        stdout: StdioCollector { id: doneOut }

        function next() {
            if (doneProc.running || doneProc.queue.length === 0)
                return;
            doneProc.current = doneProc.queue.shift();
            var t = doneProc.current.task;
            doneProc.command = [agenda.anna, "tasks", "done", t.list, t.id, doneProc.current.done ? "yes" : "no"];
            doneProc.running = true;
        }

        onRunningChanged: {
            if (running)
                return;
            var c = doneProc.current;
            doneProc.current = null;
            try {
                var r = JSON.parse(doneOut.text);
                if (!r.ok)
                    throw r.error;
                agenda.tasksError = "";
            } catch (e) {
                agenda._mark(c.task, !c.done);
                agenda.tasksError = typeof e === "string" && e !== "" ? e : I18n.tr("anna.noAnswer");
            }
            doneProc.next();
        }
    }
}
