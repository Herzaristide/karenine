pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les sessions Claude Code vivantes de la machine, telles qu'anna les suit
// (anna/src/claude/) à partir des hooks de Claude Code : une session par
// processus `claude`, qu'il tourne dans un terminal ou sans tête.
//
// À ne pas confondre avec ClaudeSessions, l'index des transcripts sur disque :
// ici, seulement ce qui tourne en ce moment, et son état.
//
//   working — un tour est en cours ;
//   waiting — Claude attend l'utilisateur (une permission, une question) ;
//   idle    — le tour est fini, la session attend la prochaine demande.
//
// C'est aussi la porte du dock IA vers anna : lancer une session (dans une
// copie isolée du dépôt), lui écrire, l'arrêter, suivre sa conversation,
// revoir puis garder ou jeter son travail. anna fait tourner ces sessions
// lui-même : un rechargement du shell ne les tue pas.
//
// Même plomberie que Gesture : une socket longue suit `claude_watch`, une
// autre suit la conversation regardée (`claude_transcript`), et les requêtes
// ponctuelles passent par une troisième, une commande par connexion.
Singleton {
    id: live

    // Le daemon parle claude_* (un anna plus ancien répond par une erreur).
    property bool available: false

    // [{ id, project, cwd, state, since, turn_started, prompt, message,
    //    request: null | { req, tool, summary, always },
    //    managed, worktree: null | { repo, name, branch }, transcript }, …],
    // dans l'ordre d'apparition.
    property var sessions: []

    readonly property int waitingCount: live.sessions.filter(s => s.state === "waiting").length
    readonly property int workingCount: live.sessions.filter(s => s.state === "working").length

    // La demande de permission ouverte du pilote, avant une action sensible :
    // { req, tool, summary, always }, ou null. Les sessions Claude Code, elles,
    // demandent dans leur terminal.
    readonly property var pilotRequest: {
        var p = live.sessions.find(x => x.id === "pilote");
        return p && p.request ? p.request : null;
    }

    function find(id) {
        return live.sessions.find(x => x.id === id) || null;
    }

    // Amène au premier plan la fenêtre qui héberge la session.
    function focus(id) {
        live._send({ cmd: "claude_focus", id: id });
    }

    // Répond à la demande ouverte du pilote (pilotRequest.req) : "allow",
    // "always" ou "deny".
    function decide(req, decision) {
        live._send({ cmd: "claude_decide", request: req, decision: decision });
    }

    // ── Dock IA ──────────────────────────────────────────────────────
    // Où une nouvelle session peut démarrer : [{ name, path, kind }], la
    // recherche (le coffre) d'abord, puis les dépôts.
    property var projects: []

    function loadProjects() {
        live._send({ cmd: "claude_projects" }, function (r) {
            if (Array.isArray(r))
                live.projects = r;
        });
    }

    // Lance une session dans `cwd` ; `worktree` la met dans sa propre copie
    // du dépôt. `done(id)` reçoit son identifiant, ou "" en cas d'échec
    // (l'erreur est dans lastError).
    function start(cwd, prompt, worktree, done) {
        live._send({ cmd: "claude_start", cwd: cwd, prompt: prompt, worktree: worktree },
                   function (r) {
            if (done)
                done(r && r.ok ? r.id : "");
        });
    }

    // Écrit à une session : anna la lui transmet si elle tourne chez lui,
    // sinon la reprend dans `cwd` avec ce message.
    function send(id, text, cwd) {
        live._send({ cmd: "claude_send", id: id, text: text, cwd: cwd || "" });
    }

    function stop(id) {
        live._send({ cmd: "claude_stop", id: id });
    }

    // "zed", ou "terminal" (la session y est reprise : `claude --resume`).
    function open(cwd, app, id) {
        live._send({ cmd: "claude_open", cwd: cwd, app: app, id: id || "" });
    }

    // Ce qu'une session en copie isolée a changé : done(review | null).
    // review : { worktree, base, ahead, files: [{ status, path, added, removed }] }
    function review(cwd, done) {
        live._send({ cmd: "claude_review", cwd: cwd }, function (r) {
            done(r && r.ok ? r.review : null);
        });
    }

    // "commit" (avec `message`), "merge" ou "discard" sur la copie d'une
    // session. done(ok).
    function worktree(cwd, action, message, id, done) {
        live._send({ cmd: "claude_worktree", cwd: cwd, action: action,
                     message: message || "", id: id || "" },
                   function (r) {
            if (done)
                done(!!(r && r.ok));
        });
    }

    // La dernière erreur renvoyée par anna, pour l'afficher.
    property string lastError: ""

    // ── Voix ─────────────────────────────────────────────────────────
    // Parler au pilote (anna/src/claude/voice.rs) : anna écoute jusqu'à la
    // fin de la phrase, transcrit en local, et transmet au pilote.
    // voicePhase : "idle", "listening" ou "transcribing".
    property string voicePhase: "idle"
    property real voiceLevel: 0
    // Ce qui a été compris : en direct pendant l'écoute (voicePartial), puis
    // la phrase finale.
    property string voiceText: ""
    property bool voicePartial: false
    // La phrase ira au pilote (Super+V), ou reste à afficher (dictée du dock).
    property bool voiceSend: true
    property string voiceError: ""
    // Le mot d'activation « Karénine » écoute (micro ouvert en continu).
    property bool voiceWake: false

    // Lance l'écoute, ou la termine tout de suite si elle est en cours.
    function voiceToggle(send) {
        live._send({ cmd: "voice_toggle", send: send === undefined ? true : !!send });
    }

    // Parler tant qu'une touche est maintenue (Espace dans le dock) : les
    // silences ne coupent pas, seul voiceRelease() termine. Rien n'est envoyé.
    function voiceHold() {
        live._send({ cmd: "voice_hold" });
    }

    function voiceRelease() {
        live._send({ cmd: "voice_release" });
    }

    function voiceWakeToggle() {
        live._send({ cmd: "voice_wake" });
    }

    Socket {
        id: voiceSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var msg;
                try { msg = JSON.parse(line); } catch (e) { return; }
                if (!msg || !msg.voice)
                    return;
                // La phase en dernier : qui réagit à la fin de l'écoute
                // trouve déjà le texte final.
                live.voiceLevel = msg.voice.level || 0;
                live.voiceText = msg.voice.text || "";
                live.voicePartial = !!msg.voice.partial;
                live.voiceSend = msg.voice.send !== false;
                live.voiceError = msg.voice.error || "";
                live.voiceWake = !!msg.voice.wake;
                live.voicePhase = msg.voice.phase;
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"voice_watch"}\n');
            else
                live.voicePhase = "idle";
        }
    }

    // ── Savoir ───────────────────────────────────────────────────────
    // Les notes du coffre Obsidian (anna/src/claude/knowledge.rs), les plus
    // récentes d'abord : { path, title, kind, sujets, statut, date, revu,
    // projet, session, excerpt, mtime }. kind : recherche, projet, skill,
    // lab, journal ou note.
    property var notes: []

    // Relit le coffre (et relie ses skills pour Claude Code).
    function loadNotes() {
        live._send({ cmd: "knowledge_list" }, function (r) {
            if (Array.isArray(r))
                live.notes = r;
        });
    }

    // Le corps d'une note, sans son en-tête : done(texte | null).
    function readNote(path, done) {
        live._send({ cmd: "knowledge_read", path: path }, function (r) {
            done(r && r.ok ? r.text : null);
        });
    }

    // « Relu » : statut relu, revu aujourd'hui. done(ok).
    function markReviewed(path, done) {
        live._send({ cmd: "knowledge_reviewed", path: path }, function (r) {
            if (r && r.ok)
                live.loadNotes();
            if (done)
                done(!!(r && r.ok));
        });
    }

    function openNote(path) {
        live._send({ cmd: "desk", tool: "ouvrir_note", args: { chemin: path } });
    }

    // ── Pilote ───────────────────────────────────────────────────────
    // La session qu'anna garde prête pour les demandes du bureau (son,
    // fenêtres, apps, notes…) et qui confie le code à des sessions complètes
    // (anna/src/claude/pilot.rs). items : { kind: "user" | "action" | "reply"
    // | "error", text }, les derniers échanges.
    property bool pilotBusy: false
    property var pilotItems: []

    // Un tour du pilote vient de se terminer.
    signal pilotDone()

    // `clipboard` joint le texte du presse-papiers à la demande.
    function pilotAsk(text, clipboard) {
        live._send({ cmd: "pilot_ask", text: text, clipboard: !!clipboard });
    }

    function pilotReset() {
        live._send({ cmd: "pilot_reset" });
    }

    Socket {
        id: pilotSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var msg;
                try { msg = JSON.parse(line); } catch (e) { return; }
                if (!msg || !msg.pilot)
                    return;
                var wasBusy = live.pilotBusy;
                live.pilotItems = msg.pilot.items || [];
                live.pilotBusy = !!msg.pilot.busy;
                if (wasBusy && !live.pilotBusy)
                    live.pilotDone();
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"pilot_watch"}\n');
            else
                live.pilotBusy = false;
        }
    }

    // ── Conversation suivie ──────────────────────────────────────────
    // Une seule à la fois : celle que le dock montre. messages :
    // { role: "user" | "assistant" | "tool", text }.
    property string transcriptPath: ""
    property ListModel messages: ListModel {}

    function follow(path) {
        if (path === live.transcriptPath)
            return;
        live.transcriptPath = path;
        live.messages.clear();
        transcriptSock.connected = false;
        if (path.length > 0)
            Qt.callLater(function () { transcriptSock.connected = true; });
    }

    function _applyTranscript(msg) {
        if (msg.reset)
            live.messages.clear();
        var list = msg.reset || msg.append || [];
        for (var i = 0; i < list.length; i++)
            live.messages.append({ role: list[i].role, text: list[i].text });
    }

    Socket {
        id: transcriptSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    live._applyTranscript(JSON.parse(line));
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected && live.transcriptPath.length > 0)
                write(JSON.stringify({ cmd: "claude_transcript", path: live.transcriptPath }) + "\n");
        }
    }

    function _apply(msg) {
        live.available = true;
        live.sessions = msg.sessions;
    }

    // ── Flux d'état ──────────────────────────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (msg && Array.isArray(msg.sessions))
                        live._apply(msg);
                } catch (e) { /* ligne partielle */ }
            }
        }
        onConnectedChanged: {
            if (connected) {
                write('{"cmd":"claude_watch"}\n');
            } else {
                live.available = false;
                live.sessions = [];
            }
        }
    }

    // (Re)connexion tant que le daemon est absent — il redémarre avec la session.
    Timer {
        interval: 3000
        running: !watchSock.connected
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            watchSock.connected = true;
            if (!pilotSock.connected)
                pilotSock.connected = true;
            if (!voiceSock.connected)
                voiceSock.connected = true;
            if (live.transcriptPath.length > 0 && !transcriptSock.connected)
                transcriptSock.connected = true;
        }
    }

    // ── Requêtes ─────────────────────────────────────────────────────
    // File d'attente : { line, done } — `done` reçoit la réponse décodée.
    property var _queue: []

    function _send(obj, done) {
        live._queue = live._queue.concat([{ line: JSON.stringify(obj), done: done || null }]);
        if (!reqSock.connected)
            reqSock.connected = true;
    }

    function _next(reply) {
        var head = live._queue[0];
        live._queue = live._queue.slice(1);
        reqSock.connected = false;
        if (reply && reply.ok === false && reply.error)
            live.lastError = reply.error;
        if (head && head.done)
            head.done(reply);
        if (live._queue.length > 0)
            Qt.callLater(function () { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var r = null;
                try { r = JSON.parse(line); } catch (e) { /* ignore */ }
                live._next(r);
            }
        }
        onConnectedChanged: {
            if (connected && live._queue.length > 0)
                write(live._queue[0].line + "\n");
        }
    }
}
