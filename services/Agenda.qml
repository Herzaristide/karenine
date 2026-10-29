pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les événements de l'onglet Agenda, lus par `anna agenda <du> <au>` dans
// les calendriers du compte Nextcloud (anna/src/cloud/caldav.rs). Un mois
// demandé s'affiche tout de suite s'il a déjà été lu (le cache vit tant que
// le shell tourne), puis se relit derrière.
//
// anna donne les heures en texte : `…T14:00:00Z` (UTC), `…T14:00:00`
// (heure locale), `2026-10-22` (toute la journée, `end` exclue). Ici, elles
// deviennent des Date, et chaque jour local reçoit ses événements.
Singleton {
    id: agenda

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

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
        target: Cloud
        function onGenerationChanged() {
            agenda.calendars = [];
            agenda.events = [];
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
}
