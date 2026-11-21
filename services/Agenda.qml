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
// la coche ici tout de suite, puis chez Google (`anna tasks done`). Elles se
// relisent toutes les cinq minutes tant que le compte est connecté : le
// bouton des tâches de la barre compte celles du jour et en retard.
//
// Créer, modifier (déplacer, c'est modifier le début ou l'échéance) et
// supprimer passent par `anna agenda create|update|delete` et `anna tasks
// create|update|delete`, l'un après l'autre. Un changement s'affiche ici
// tout de suite ; Google répondu, l'agenda se relit. Un échec s'affiche dans
// `error` (ou `tasksError`) et la relecture remet ce que Google garde.
Singleton {
    id: agenda

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    // Les listes ({ id, title }) et les tâches ({ list, id, title, notes,
    // due, done, parent, position }).
    property var lists: []
    property var tasks: []
    property string tasksError: ""
    // La liste où vont les tâches créées d'un mot (TaskList) ; vide : la
    // première, celle par défaut chez Google.
    property string quickList: ""

    // Aujourd'hui, "AAAA-MM-JJ" : relu toutes les minutes (passer minuit).
    property string todayKey: agenda.dayKey(new Date())
    // À faire, dues aujourd'hui ou avant.
    readonly property int dueCount: agenda.tasks.filter(t => !t.done && t.due !== "" && t.due <= agenda.todayKey).length
    // Toutes celles qui restent à faire : la pastille du bouton de la barre.
    readonly property int pendingCount: agenda.tasks.filter(t => !t.done).length

    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: agenda.todayKey = agenda.dayKey(new Date())
    }
    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: Google.connected
        onTriggered: agenda.loadTasks()
    }
    Component.onCompleted: if (Google.connected) agenda.loadTasks()

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
        function onConnectedChanged() {
            if (Google.connected)
                agenda.loadTasks();
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

    // Une lecture déjà en cours est relancée à sa fin : elle a pu partir
    // avant ce qu'on vient d'écrire.
    function loadTasks() {
        if (taskProc.running)
            taskProc.again = true;
        else
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

    // Une tâche confiée à Claude Code : un terminal s'ouvre sur une session
    // dont la première demande est son titre (et ses notes). Le dossier :
    // celui de ~/code qui porte le nom de sa liste (« karenine » →
    // ~/code/karenine, la casse ignorée), sinon le dossier personnel. Le
    // texte passe en argument, jamais dans le script.
    function openInClaude(task) {
        var prompt = (task.title || "").trim();
        if ((task.notes || "").trim() !== "")
            prompt += "\n\n" + task.notes.trim();
        if (prompt === "")
            return;
        var script = "d=\"$HOME\"; " +
            "for c in \"$HOME/code\"/*/; do " +
            "  n=$(basename \"$c\"); " +
            "  [ \"$(printf %s \"$n\" | tr '[:upper:]' '[:lower:]')\" = \"$(printf %s \"$2\" | tr '[:upper:]' '[:lower:]')\" ] && { d=\"$c\"; break; }; " +
            "done; cd \"$d\" && exec claude \"$1\"";
        DefaultApps.runInTerminal("", ["sh", "-c", script, "sh", prompt, agenda.listTitle(task.list)]);
    }

    function _mark(task, done) {
        agenda.tasks = agenda.tasks.map(t => t.list === task.list && t.id === task.id
                                             ? Object.assign({}, t, { done: done }) : t);
    }

    Process {
        id: taskProc
        property bool again: false
        command: [agenda.anna, "tasks"]
        stdout: StdioCollector { id: taskOut }
        onRunningChanged: {
            if (running)
                return;
            if (taskProc.again) {
                taskProc.again = false;
                taskProc.running = true;
                return;
            }
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

    // ── Écrire ───────────────────────────────────────────────────

    // Une Date → ce qu'anna attend : l'instant en UTC, ou le jour seul pour
    // une journée entière.
    function stamp(d, allDay) {
        return allDay ? agenda.dayKey(d) : d.toISOString();
    }

    // input : { title, location, notes, start: Date, end: Date, allDay }.
    function _eventJson(input) {
        var out = {};
        ["title", "location", "notes"].forEach(k => {
            if (input[k] !== undefined)
                out[k] = input[k];
        });
        if (input.start)
            out.start = agenda.stamp(input.start, input.allDay);
        if (input.end)
            out.end = agenda.stamp(input.end, input.allDay);
        return JSON.stringify(out);
    }

    function createEvent(calendar, input) {
        agenda._write([agenda.anna, "agenda", "create", calendar || "", agenda._eventJson(input)], "events");
    }

    // Affiché tout de suite à sa nouvelle place, puis écrit chez Google.
    function updateEvent(ev, input) {
        agenda.events = agenda.events.map(e => e.calendar === ev.calendar && e.uid === ev.uid
            ? Object.assign({}, e, {
                title: input.title !== undefined ? input.title : e.title,
                location: input.location !== undefined ? input.location : e.location,
                notes: input.notes !== undefined ? input.notes : e.notes,
                startDate: input.start || e.startDate,
                endDate: input.end || e.endDate,
                allDay: input.allDay !== undefined ? input.allDay : e.allDay
            }) : e);
        agenda._write([agenda.anna, "agenda", "update", ev.calendar, ev.uid, agenda._eventJson(input)], "events");
    }

    function deleteEvent(ev) {
        agenda.events = agenda.events.filter(e => !(e.calendar === ev.calendar && e.uid === ev.uid));
        agenda._write([agenda.anna, "agenda", "delete", ev.calendar, ev.uid], "events");
    }

    // input : { title, notes, due: "AAAA-MM-JJ" ou "" }. Elle s'affiche
    // tout de suite (`pending`, sans id de Google), et la relecture qui suit
    // l'écriture la remplace par la vraie.
    function createTask(list, input) {
        var l = list || (agenda.lists.length > 0 ? agenda.lists[0].id : "");
        agenda.tasks = agenda.tasks.concat([{
            list: l, id: "pending:" + Date.now(), title: input.title || "", notes: input.notes || "",
            due: input.due || "", done: false, parent: "", position: "~", pending: true
        }]);
        agenda._write([agenda.anna, "tasks", "create", l, JSON.stringify(input)], "tasks");
    }

    function updateTask(task, input) {
        agenda.tasks = agenda.tasks.map(t => t.list === task.list && t.id === task.id
                                             ? Object.assign({}, t, input) : t);
        agenda._write([agenda.anna, "tasks", "update", task.list, task.id, JSON.stringify(input)], "tasks");
    }

    function deleteTask(task) {
        agenda.tasks = agenda.tasks.filter(t => !(t.list === task.list && t.id === task.id));
        agenda._write([agenda.anna, "tasks", "delete", task.list, task.id], "tasks");
    }

    function _write(args, what) {
        writeProc.queue.push({ args: args, what: what });
        writeProc.next();
    }

    // Les écritures, l'une après l'autre ; chacune finie, ce qu'elle touche
    // se relit.
    Process {
        id: writeProc
        property var queue: []
        property var current: null
        stdout: StdioCollector { id: writeOut }

        function next() {
            if (writeProc.running || writeProc.queue.length === 0)
                return;
            writeProc.current = writeProc.queue.shift();
            writeProc.command = writeProc.current.args;
            writeProc.running = true;
        }

        onRunningChanged: {
            if (running)
                return;
            var c = writeProc.current;
            writeProc.current = null;
            var failed = "";
            try {
                var r = JSON.parse(writeOut.text);
                if (!r.ok)
                    failed = r.error || I18n.tr("common.failedSentence");
            } catch (e) {
                failed = I18n.tr("anna.noAnswer");
            }
            if (c.what === "tasks") {
                agenda.tasksError = failed;
                agenda.loadTasks();
            } else {
                agenda.reloadAll();
                agenda.error = failed;
            }
            writeProc.next();
        }
    }
}
