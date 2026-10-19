pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Ce que porte le tableau noir (panels/Blackboard.qml) : les notes qu'on y a
// posées et les traits de craie, lus dans le dossier des notes d'anna
// (anna/src/notes.rs) et suivis sur le disque. Lire ne lance pas anna ;
// écrire passe par `anna notes …`, une commande à la fois, qui réécrit ces
// fichiers, et le tableau suit.
//
// Les positions sont des fractions de l'écran (0 à 1) : `board` d'une note
// est le coin haut gauche de son texte, `points` d'un trait ses sommets.
//
// Chaque geste du tableau garde de quoi se défaire (Ctrl+Z) et se refaire
// (Ctrl+Maj+Z) : un trait effacé est redessiné sous le même id, une note
// déplacée revient à sa place.
Singleton {
    id: board

    readonly property string dir: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share")
                                   + "/anna/notes"

    // Le client anna. KARENINE_ANNA le remplace, pour essayer un anna
    // fraîchement compilé sans réinstaller.
    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    // Les notes posées au tableau, dans l'ordre du fichier (la plus ancienne
    // d'abord : une nouvelle passe devant).
    property var notes: []
    // Les traits, dans l'ordre où ils ont été tracés.
    property var strokes: []
    // La dernière erreur d'anna, effacée seule.
    property string feedback: ""

    FileView {
        path: board.dir + "/notes.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                var all = JSON.parse(text()) || [];
                board.notes = all.filter(n => n.board !== undefined && n.board !== null);
            } catch (e) {
                // Un fichier à moitié lu : on garde ce qu'on avait.
            }
        }
        onLoadFailed: board.notes = []
    }

    FileView {
        path: board.dir + "/board.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                board.strokes = JSON.parse(text()) || [];
            } catch (e) {
                // Idem.
            }
        }
        onLoadFailed: board.strokes = []
    }

    // ── Les commandes ────────────────────────────────────────────
    // `anna notes <args…>`, dans l'ordre ; `done(réponse)` reçoit la ligne
    // JSON quand elle dit ok.
    property var _queue: []

    function act(args, done) {
        board._queue = board._queue.concat([{ args: args, done: done || null }]);
        board._next();
    }

    function _next() {
        if (proc.running || board._queue.length === 0)
            return;
        var job = board._queue[0];
        board._queue = board._queue.slice(1);
        proc.done = job.done;
        proc.command = [board.anna, "notes"].concat(job.args);
        proc.running = true;
    }

    Process {
        id: proc
        property var done: null
        stdout: StdioCollector { id: out }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(out.text);
                if (r.ok) {
                    if (proc.done)
                        proc.done(r);
                } else {
                    board.say(r.error || I18n.tr("common.failedSentence"));
                }
            } catch (e) {
                board.say(I18n.tr("anna.noAnswer"));
            }
            board._next();
        }
    }

    function say(text) {
        board.feedback = text;
        feedbackTimer.restart();
    }

    Timer {
        id: feedbackTimer
        interval: 4000
        onTriggered: board.feedback = ""
    }

    // ── Défaire, refaire ─────────────────────────────────────────
    // Un pas : { undo: function, redo: function }. Chaque fonction lance ses
    // commandes ; celles qui créent quelque chose mettent à jour le pas
    // (l'id d'une note recréée change).
    property var _undo: []
    property var _redo: []
    readonly property int historyLimit: 100

    function record(step) {
        var u = board._undo.concat([step]);
        board._undo = u.length > board.historyLimit ? u.slice(u.length - board.historyLimit) : u;
        board._redo = [];
    }

    function undo() {
        if (board._undo.length === 0)
            return;
        var step = board._undo[board._undo.length - 1];
        board._undo = board._undo.slice(0, -1);
        board._redo = board._redo.concat([step]);
        step.undo();
    }

    function redo() {
        if (board._redo.length === 0)
            return;
        var step = board._redo[board._redo.length - 1];
        board._redo = board._redo.slice(0, -1);
        board._undo = board._undo.concat([step]);
        step.redo();
    }

    // ── Les gestes ───────────────────────────────────────────────
    // Un trait : ses points déjà en fractions.
    function draw(stroke) {
        var step = { stroke: stroke, id: "" };
        var drawIt = function () {
            var s = Object.assign({}, step.stroke, { id: step.id });
            board.act(["board", "draw", JSON.stringify(s)], function (r) {
                if (r.strokes.length > 0)
                    step.id = r.strokes[0].id;
            });
        };
        step.undo = function () { board.act(["board", "erase", step.id]); };
        step.redo = drawIt;
        drawIt();
        board.record(step);
    }

    function erase(ids) {
        if (ids.length === 0)
            return;
        var step = { gone: [] };
        step.redo = function () {
            board.act(["board", "erase"].concat(ids), function (r) { step.gone = r.strokes; });
        };
        step.undo = function () {
            if (step.gone.length > 0)
                board.act(["board", "draw", JSON.stringify(step.gone)]);
        };
        step.redo();
        board.record(step);
    }

    function addNote(text, x, y) {
        var step = { id: "" };
        var at = Chalk.fraction(x) + "," + Chalk.fraction(y);
        step.redo = function () {
            board.act(["add", "--at", at, text], function (r) { step.id = r.note.id; });
        };
        step.undo = function () { board.act(["delete", step.id]); };
        step.redo();
        board.record(step);
    }

    function move(note, x, y) {
        var from = [note.board.x, note.board.y];
        var to = [Chalk.fraction(x), Chalk.fraction(y)];
        board.act(["place", note.id, to[0], to[1]]);
        board.record({
            undo: function () { board.act(["place", note.id, from[0], from[1]]); },
            redo: function () { board.act(["place", note.id, to[0], to[1]]); }
        });
    }

    // Une note glissée depuis l'onglet Notes : posée au tableau, ou déplacée
    // si elle y était déjà. Défaire la remet où elle était (ou hors du
    // tableau).
    function placeFromTab(id, x, y) {
        var known = board.notes.find(n => n.id === id);
        var from = known ? [known.board.x, known.board.y] : null;
        var to = [Chalk.fraction(x), Chalk.fraction(y)];
        board.act(["place", id, to[0], to[1]]);
        board.record({
            undo: function () {
                if (from)
                    board.act(["place", id, from[0], from[1]]);
                else
                    board.act(["unplace", id]);
            },
            redo: function () { board.act(["place", id, to[0], to[1]]); }
        });
    }

    // Retirée du tableau, la note reste dans l'onglet Notes.
    function unplace(note) {
        var at = [note.board.x, note.board.y];
        board.act(["unplace", note.id]);
        board.record({
            undo: function () { board.act(["place", note.id, at[0], at[1]]); },
            redo: function () { board.act(["unplace", note.id]); }
        });
    }

    // Vider une note la supprime (comme dans l'onglet) : défaire la recrée
    // à sa place, sous un nouvel id.
    function editNote(note, text) {
        if (text === note.text)
            return;
        var step = { id: note.id };
        var before = note.text;
        var at = note.board.x + "," + note.board.y;
        var set = function (value) {
            if (step.id === "")
                board.act(["add", "--at", at, value], function (r) { step.id = r.note.id; });
            else
                board.act(["edit", step.id, value], function (r) {
                    if (r.note.id === "")
                        step.id = "";
                });
        };
        step.undo = function () { set(before); };
        step.redo = function () { set(text); };
        step.redo();
        board.record(step);
    }
}
