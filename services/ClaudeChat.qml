pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// La conversation ouverte dans l'onglet Claude, telle qu'anna la suit
// (anna/src/claude/drive.rs `watch`, transcript.rs) : ses éléments — les
// demandes, le texte de Claude, sa réflexion, chaque outil avec son
// résultat —, le texte en train de s'écrire, et l'état de la session quand
// anna la pilote (modèle, mode, coût, outil qui attend une permission).
//
// Écrire à une session la reprend : anna lance son propre `claude` dessus.
// Une session tenue par un terminal (`elsewhere`) ne se reprend qu'après
// « Prendre la main », qui ferme ce terminal-là.
Singleton {
    id: chat

    // Ouverte ou non, et laquelle : { id, title, project, branch, cwd }.
    // Une nouvelle session n'a pas d'id avant son premier message.
    property bool open: false
    property var session: ({})
    readonly property string sessionId: chat.session.id || ""
    readonly property bool isNew: chat.open && chat.sessionId === ""

    // Les éléments, dans l'ordre : une ligne { key, json } chacun. Le JSON
    // tel qu'anna l'envoie (transcript.rs `Item`), relu par la vue : un
    // ListModel ne garde pas des objets de formes différentes.
    readonly property ListModel items: ListModel {}
    property var _rows: ({})
    // La ligne du transcript où commence ce qui est chargé (0 : le début).
    property int first: 0
    property bool loaded: false
    property bool loadingEarlier: false

    // Ce qui s'écrit : { kind: "text" | "thinking", text }.
    property var partial: ({ kind: "", text: "" })
    // drive.rs `State`.
    readonly property var idleState: ({ driven: false, busy: false, model: "", effort: "", mode: "", cost: 0,
                                        window: 0, context: null, asking: "", asks: [], error: "", mcp: [],
                                        env: "", remote: "", remote_url: "", remote_error: "" })
    property var state: chat.idleState
    // Le `claude` d'un terminal qui la tient (0 : aucun).
    property int elsewhere: 0
    // Toute la session (anna/src/claude/summary.rs) : le contexte, les
    // changements, les sorties, les sous-agents et tâches de fond, la liste
    // de tâches.
    readonly property var emptySummary: ({
        context: { tokens: 0, window: 0, model: "", compactions: 0, connectors: [], tools: [], read: [] },
        changes: [], outputs: [], jobs: [], todos: []
    })
    property var summary: chat.emptySummary
    // Un sous-agent de la session, ouvert à la place de sa conversation
    // ("" : la session elle-même) ; on ne lui écrit pas.
    property string agent: ""
    property string agentTitle: ""

    // Les modèles que `claude` propose ([{ value, resolvedModel,
    // displayName, description, supportedEffortLevels }]) et les réglages
    // par défaut de Claude Code ({ model, effort, mode }).
    property var models: []
    property var defaults: ({ model: "", effort: "", mode: "default" })

    // Ce qui est choisi sous le champ, par session : { model, effort, mode }
    // ("" : le réglage de Claude Code). Pilotée, la session dit le sien.
    property var _choices: ({})
    readonly property string _key: chat.sessionId !== "" ? chat.sessionId : "new:" + (chat.session.cwd || "")
    readonly property var choice: chat._choices[chat._key] || ({ model: "", effort: "", mode: "" })

    // Le modèle montré : celui de la session pilotée, sinon le choix, sinon
    // le dernier de la conversation, sinon le défaut.
    readonly property string modelShown: chat.state.driven && chat.state.model !== "" ? chat.state.model
        : chat.choice.model !== "" ? chat.choice.model
        : chat.summary.context.model !== "" ? chat.summary.context.model
        : chat.defaults.model
    readonly property string effortShown: chat.state.driven && chat.state.effort !== "" ? chat.state.effort
        : chat.choice.effort !== "" ? chat.choice.effort : chat.defaults.effort
    readonly property string modeShown: chat.state.driven && chat.state.mode !== "" ? chat.state.mode
        : chat.choice.mode !== "" ? chat.choice.mode : (chat.defaults.mode || "default")

    // L'entrée de `models` d'un nom (alias, ou nom complet résolu).
    function modelEntry(name) {
        if (!name)
            return null;
        var byValue = chat.models.find((m) => m.value === name);
        if (byValue)
            return byValue;
        return chat.models.find((m) => m.value !== "default" && m.resolvedModel === name.replace(/\[1m\]$/, "")) || null;
    }

    function modelLabel(name) {
        var m = chat.modelEntry(name);
        if (m)
            return m.value === "default" ? (m.description || "").split(" · ")[0] || m.displayName : m.displayName;
        // claude-opus-5-5 → Opus 5.5
        var parts = (name || "").replace(/^claude-/, "").split("-");
        if (parts.length < 2)
            return name || "";
        return parts[0].charAt(0).toUpperCase() + parts[0].slice(1) + " " + parts.slice(1).filter((p) => /^\d+$/.test(p)).join(".");
    }

    function _choose(key, value) {
        var all = Object.assign({}, chat._choices);
        var c = Object.assign({ model: "", effort: "", mode: "" }, all[chat._key] || {});
        c[key] = value;
        all[chat._key] = c;
        chat._choices = all;
    }

    function setModel(v) {
        chat._choose("model", v);
        if (chat.state.driven)
            chat._request({ cmd: "claude_set", id: chat.sessionId, model: v });
    }

    function setEffort(v) {
        chat._choose("effort", v);
        if (chat.state.driven)
            chat._request({ cmd: "claude_set", id: chat.sessionId, effort: v });
    }

    function setMode(v) {
        chat._choose("mode", v);
        if (chat.state.driven)
            chat._request({ cmd: "claude_set", id: chat.sessionId, mode: v });
    }

    // Remote Control : la session se suit aussi de claude.ai et du téléphone.
    readonly property bool remoteOn: chat.state.remote !== "" && chat.state.remote !== "failed"

    function toggleRemote() {
        if (chat.state.driven)
            chat._request({ cmd: "claude_set", id: chat.sessionId, remote: !chat.remoteOn },
                          (r) => { if (!r.ok && r.error) chat.error = r.error; });
    }

    // Ce qui est tapé et pas encore envoyé, par session : ni changer
    // d'onglet, ni de session, ni fermer le panneau ne le perd.
    property var _drafts: ({})
    readonly property string draft: chat._drafts[chat._key] || ""

    function setDraft(text) {
        if ((chat._drafts[chat._key] || "") === text)
            return;
        var all = Object.assign({}, chat._drafts);
        if (text === "")
            delete all[chat._key];
        else
            all[chat._key] = text;
        chat._drafts = all;
    }

    // Ajouter au brouillon d'une session, à la fin (ou devant).
    function _addText(key, text, before) {
        var old = chat._drafts[key] || "";
        var all = Object.assign({}, chat._drafts);
        var parts = before ? [text, old] : [old, text];
        var sep = before ? "\n" : /\s$/.test(old) ? "" : " ";
        all[key] = parts.filter((p) => p !== "").join(sep);
        chat._drafts = all;
    }

    // ── Les pièces jointes ───────────────────────────────────────────
    // Les fichiers à joindre au prochain message, par session, comme le
    // brouillon : des chemins. anna envoie les images telles quelles et
    // nomme les autres à Claude, qui les lit avec ses outils.
    property var _files: ({})
    readonly property var files: chat._files[chat._key] || []

    function _setFiles(key, list) {
        var all = Object.assign({}, chat._files);
        if (list.length === 0)
            delete all[key];
        else
            all[key] = list;
        chat._files = all;
    }

    function _addFiles(key, paths) {
        var list = (chat._files[key] || []).slice();
        paths.forEach((p) => {
            if (p && list.indexOf(p) < 0)
                list.push(p);
        });
        chat._setFiles(key, list);
    }

    function addFiles(paths) {
        chat._addFiles(chat._key, paths);
    }

    function removeFile(path) {
        chat._setFiles(chat._key, chat.files.filter((p) => p !== path));
    }

    // Choisir des fichiers dans l'Explorer, puis revenir ici (sauf si le
    // choix a été annulé en fermant le panneau ou en changeant d'onglet).
    function pickFiles() {
        var key = chat._key;
        Widgets.explorerPickStart({
            mode: "open", multiple: true, path: chat.session.cwd || "",
            done: (paths) => {
                chat._addFiles(key, paths);
                if (Widgets.panelOpen && Widgets.panelTab === "files")
                    Widgets.show("claude");
            }
        });
    }

    // Une capture ("area" : une région, "output" : l'écran) : le panneau se
    // ferme, pour ne pas y être, puis revient. Gardée dans le cache, lisible
    // de toi seul.
    property string _shotKey: ""
    property string _shotKind: "area"

    function capture(kind) {
        if (shotProc.running || shotTimer.running)
            return;
        chat._shotKey = chat._key;
        chat._shotKind = kind;
        Widgets.panelOpen = false;
        shotTimer.restart();
    }

    Timer {
        id: shotTimer
        interval: 450
        onTriggered: shotProc.running = true
    }

    Process {
        id: shotProc
        command: ["sh", "-c",
                  "umask 077; d=\"${XDG_CACHE_HOME:-$HOME/.cache}/karenine/claude\"; mkdir -p \"$d\" || exit 1; "
                  + "f=\"$d/capture-$(date +%Y%m%d-%H%M%S-%N).png\"; "
                  + "grimblast save \"$1\" \"$f\" >/dev/null 2>&1; [ -s \"$f\" ] && printf %s \"$f\"",
                  "--", chat._shotKind]
        stdout: StdioCollector {
            onStreamFinished: {
                // Vide : annulée.
                var path = this.text.trim();
                if (path !== "")
                    chat._addFiles(chat._shotKey, [path]);
                Widgets.show("claude");
            }
        }
    }

    // ── La dictée ────────────────────────────────────────────────────
    // La voix d'anna (Parakeet, en local), sans le pilote : la transcription
    // s'ajoute au brouillon de la session où elle a commencé.
    property bool dictating: false
    property string _dictKey: ""
    property bool _dictHeard: false

    function dictate() {
        if (chat.dictating) {
            // Finir tout de suite ; pendant la transcription, on attend.
            if (Pilot.voicePhase === "listening")
                Pilot.voiceToggle(false);
            return;
        }
        // La voix parle déjà au pilote : on la lui laisse.
        if (Pilot.voicePhase !== "idle")
            return;
        chat.error = "";
        chat._dictKey = chat._key;
        chat._dictHeard = false;
        chat.dictating = true;
        dictStart.restart();
        Pilot.voiceToggle(false);
    }

    // L'écoute n'a pas démarré (anna absent).
    Timer {
        id: dictStart
        interval: 5000
        onTriggered: if (!chat._dictHeard) chat.dictating = false
    }

    Connections {
        target: Pilot
        enabled: chat.dictating
        function onVoicePhaseChanged() {
            if (Pilot.voicePhase !== "idle") {
                chat._dictHeard = true;
            } else if (chat._dictHeard) {
                chat.dictating = false;
                if (Pilot.voiceError !== "")
                    chat.error = Pilot.voiceError;
                else if (Pilot.voiceText.trim() !== "")
                    chat._addText(chat._dictKey, Pilot.voiceText.trim(), false);
            }
        }
    }

    // Ce qui reste du forfait (anna `claude_usage`) : { subscription_type,
    // rate_limits: { five_hour: { utilization, resets_at }, seven_day, … } }.
    property var usage: null
    property bool usageLoading: false

    function fetchUsage() {
        if (chat.usageLoading)
            return;
        chat.usageLoading = true;
        chat._request({ cmd: "claude_usage" }, (r) => {
            chat.usageLoading = false;
            if (r.ok)
                chat.usage = r.usage;
        });
    }

    // ── Les commandes « / » ──────────────────────────────────────────
    // Celles de Claude Code dans le dossier de la session (anna
    // `claude_commands`), par dossier : [{ name, description, argumentHint,
    // aliases }]. Sur une connexion à elles : la première fois, un `claude`
    // est interrogé, et un envoi n'a pas à l'attendre.
    property var _commands: ({})
    readonly property var commands: chat._commands[chat.session.cwd || ""] || []
    property string _commandsCwd: ""

    function fetchCommands() {
        var cwd = chat.session.cwd || "";
        if (cwd === "" || cmdSock.connected)
            return;
        chat._commandsCwd = cwd;
        cmdSock.connected = true;
    }

    Socket {
        id: cmdSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var r = JSON.parse(line);
                    // Rien : on redemandera.
                    if (r.ok && r.commands.length > 0) {
                        var all = Object.assign({}, chat._commands);
                        all[chat._commandsCwd] = r.commands;
                        chat._commands = all;
                    }
                } catch (e) { /* ligne partielle */ }
                cmdSock.connected = false;
            }
        }
        onConnectedChanged: {
            if (connected)
                write(JSON.stringify({ cmd: "claude_commands", cwd: chat._commandsCwd }) + "\n");
        }
    }

    // « /clear » : une conversation vide dans le même dossier, avec le même
    // modèle, effort et mode. L'ancienne reste dans la liste ; son `claude`
    // s'arrête, sauf s'il travaille encore.
    function clear() {
        if (chat.agent !== "")
            return;
        var s = chat.session;
        var kept = { model: chat.choice.model, effort: chat.choice.effort, mode: chat.choice.mode };
        if (chat.state.driven) {
            kept = { model: chat.state.model, effort: chat.state.effort, mode: chat.state.mode };
            if (!chat.state.busy && (chat.state.asks || []).length === 0)
                chat._request({ cmd: "claude_stop", id: s.id });
        }
        chat.setDraft("");
        watchSock.connected = false;
        chat.newSession(s.cwd, s.project);
        Object.keys(kept).forEach((k) => chat._choose(k, kept[k] || ""));
    }

    // Répondre à une demande de la session pilotée (state.asks).
    function answer(ask, action, values) {
        chat.answerFor(chat.sessionId, ask, action, values,
                       (r) => { if (!r.ok && r.error) chat.error = r.error; });
    }
    // À celle de n'importe quelle session pilotée (la liste).
    function answerFor(id, ask, action, values, done) {
        chat._request({ cmd: "claude_answer", id: id, ask: ask, action: action, values: values || {} }, done);
    }
    property bool sending: false
    // La dernière erreur d'une commande, pour la vue.
    property string error: ""

    // Le nombre d'éléments a changé (ajout en bas, ou page du haut).
    signal appended()
    signal prepended(int count)

    function openSession(s) {
        chat.agent = "";
        chat._reset();
        chat.session = { id: s.id, title: s.title || "", project: s.project || "",
                         branch: s.branch || "", cwd: s.cwd || "" };
        chat.open = true;
        chat._watch();
    }

    function newSession(cwd, project) {
        chat.agent = "";
        chat._reset();
        chat.session = { id: "", title: "", project: project || "", branch: "", cwd: cwd };
        chat.open = true;
        chat.loaded = true;
    }

    // Ouvrir la conversation d'un sous-agent (son id, son titre).
    function openAgent(id, title) {
        if (!id || chat.sessionId === "")
            return;
        chat._reset();
        chat.agent = id;
        chat.agentTitle = title || "";
        chat._watch();
    }

    // Retour : d'un sous-agent à sa session, d'une session à la liste.
    function close() {
        if (chat.agent !== "") {
            chat.agent = "";
            chat._reset();
            chat._watch();
            return;
        }
        chat.open = false;
        watchSock.connected = false;
        chat._reset();
        chat.session = ({});
    }

    function send(text) {
        var files = chat.files;
        if ((text.trim() === "" && files.length === 0) || chat.sending)
            return;
        chat.sending = true;
        chat.error = "";
        var cmd = { cmd: "claude_send", text: text, files: files };
        chat.setDraft("");
        chat._setFiles(chat._key, []);
        if (chat.isNew)
            cmd.cwd = chat.session.cwd;
        else
            cmd.id = chat.sessionId;
        // Pas encore pilotée : le `claude` démarre avec ce qui est choisi.
        if (!chat.state.driven) {
            if (chat.choice.model !== "")
                cmd.model = chat.choice.model;
            if (chat.choice.effort !== "")
                cmd.effort = chat.choice.effort;
            if (chat.choice.mode !== "")
                cmd.mode = chat.choice.mode;
        }
        var oldKey = chat._key;
        chat._slowRequest(cmd, (r) => {
            // Une autre session a pu s'ouvrir pendant que celle-ci démarrait.
            var here = chat.open && chat._key === oldKey;
            if (here)
                chat.sending = false;
            if (!r.ok) {
                if (here)
                    chat.error = r.error === "open_elsewhere" ? I18n.tr("claude.chat.elsewhere") : (r.error || "");
                // Rien n'est parti : le texte et les fichiers reviennent,
                // devant ce qui a été tapé depuis.
                chat._addText(oldKey, text, true);
                chat._addFiles(oldKey, files);
                return;
            }
            if (oldKey.startsWith("new:")) {
                // Les choix de la nouvelle session la suivent sous son id.
                var all = Object.assign({}, chat._choices);
                if (all[oldKey]) {
                    all[r.id] = all[oldKey];
                    delete all[oldKey];
                    chat._choices = all;
                }
                if (!here)
                    return;
                var s = chat.session;
                chat.session = { id: r.id, title: text.split("\n")[0].slice(0, 80),
                                 project: s.project, branch: s.branch, cwd: s.cwd };
                chat._watch();
            }
        });
    }

    function interrupt() {
        if (chat.sessionId !== "")
            chat._request({ cmd: "claude_interrupt", id: chat.sessionId });
    }

    // Arrêter le `claude` d'anna ; la conversation reste.
    function stop() {
        if (chat.sessionId !== "")
            chat._request({ cmd: "claude_stop", id: chat.sessionId });
    }

    // Fermer le `claude` du terminal, pour piloter la session d'ici.
    function takeOver(force) {
        chat.error = "";
        chat._request({ cmd: "claude_take_over", id: chat.sessionId, force: !!force }, (r) => {
            if (!r.ok)
                chat.error = r.error === "busy" ? I18n.tr("claude.chat.busyElsewhere") : (r.error || "");
        });
    }

    function focusTerminal() {
        if (chat.elsewhere > 0)
            Quickshell.execDetached(["anna", "claude", "focus", String(chat.elsewhere)]);
    }

    function loadEarlier() {
        if (chat.first <= 0 || chat.loadingEarlier || chat.sessionId === "")
            return;
        chat.loadingEarlier = true;
        var id = chat.sessionId;
        var agent = chat.agent;
        var cmd = { cmd: "claude_chat_page", id: id, before: chat.first, limit: 100 };
        if (agent !== "")
            cmd.agent = agent;
        chat._request(cmd, (r) => {
            chat.loadingEarlier = false;
            if (!r.ok || id !== chat.sessionId || agent !== chat.agent)
                return;
            var fresh = (r.items || []).filter((it) => chat._rows[it.key] === undefined);
            for (var i = 0; i < fresh.length; i++)
                chat.items.insert(i, { key: fresh[i].key, json: JSON.stringify(fresh[i]) });
            chat.first = r.first;
            chat._reindex();
            chat.prepended(fresh.length);
        });
    }

    // Une longue sortie d'outil, gardée à part par Claude Code, ou la
    // sortie d'une commande de fond.
    function fetchOutput(path, done) {
        chat._request({ cmd: "claude_chat_output", id: chat.sessionId, path: path }, (r) => {
            done(r.ok ? r.text : (r.error || ""));
        });
    }

    // Tous les changements faits à un fichier : les morceaux du diff.
    function diff(path, done) {
        var cmd = { cmd: "claude_chat_diff", id: chat.sessionId, path: path };
        if (chat.agent !== "")
            cmd.agent = chat.agent;
        chat._request(cmd, (r) => done(r.ok ? (r.hunks || []) : []));
    }

    // Un chemin du résumé, absolu (les changements sont relatifs au
    // dossier de la session).
    function absolute(path) {
        if (!path || path.charAt(0) === "/")
            return path || "";
        return (chat.session.cwd || "") + "/" + path;
    }

    function openPath(path) {
        if (path)
            Quickshell.execDetached(["xdg-open", chat.absolute(path)]);
    }

    function openFolder(path) {
        var p = chat.absolute(path);
        if (p)
            Quickshell.execDetached(["xdg-open", p.substring(0, p.lastIndexOf("/")) || "/"]);
    }

    function _reset() {
        chat.items.clear();
        chat._rows = {};
        chat.first = 0;
        chat.loaded = false;
        chat.loadingEarlier = false;
        chat.partial = { kind: "", text: "" };
        chat.state = chat.idleState;
        chat.elsewhere = 0;
        chat.sending = false;
        chat.error = "";
        chat.summary = chat.emptySummary;
    }

    function _reindex() {
        var rows = {};
        for (var i = 0; i < chat.items.count; i++)
            rows[chat.items.get(i).key] = i;
        chat._rows = rows;
    }

    function _upsert(list) {
        var added = false;
        for (var i = 0; i < list.length; i++) {
            var it = list[i];
            var row = chat._rows[it.key];
            var json = JSON.stringify(it);
            if (row !== undefined) {
                chat.items.setProperty(row, "json", json);
            } else {
                chat._rows[it.key] = chat.items.count;
                chat.items.append({ key: it.key, json: json });
                added = true;
            }
            // Le bloc est arrivé entier : ce qui s'écrivait est dedans.
            if (it.kind === "text" || it.kind === "thinking" || it.kind === "tool")
                chat.partial = { kind: "", text: "" };
        }
        if (added)
            chat.appended();
    }

    function _watch() {
        watchSock.connected = false;
        if (chat.sessionId !== "")
            Qt.callLater(() => { watchSock.connected = true; });
    }

    // ── Le suivi de la session ouverte ───────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var msg;
                try {
                    msg = JSON.parse(line);
                } catch (e) {
                    return; // ligne partielle
                }
                if (msg.chat !== undefined) {
                    chat.items.clear();
                    chat._rows = {};
                    chat.first = msg.chat.first || 0;
                    chat._upsert(msg.chat.items || []);
                    chat.loaded = true;
                } else if (msg.chat_upsert !== undefined) {
                    chat._upsert(msg.chat_upsert);
                } else if (msg.chat_models !== undefined) {
                    chat.models = msg.chat_models.models || [];
                    chat.defaults = msg.chat_models.defaults || chat.defaults;
                } else if (msg.chat_summary !== undefined) {
                    chat.summary = msg.chat_summary;
                } else if (msg.chat_partial !== undefined) {
                    chat.partial = msg.chat_partial;
                } else if (msg.chat_state !== undefined) {
                    chat.state = msg.chat_state;
                } else if (msg.chat_elsewhere !== undefined) {
                    chat.elsewhere = msg.chat_elsewhere;
                }
            }
        }
        onConnectedChanged: {
            if (connected) {
                var cmd = { cmd: "claude_chat_watch", id: chat.sessionId };
                if (chat.agent !== "")
                    cmd.agent = chat.agent;
                write(JSON.stringify(cmd) + "\n");
            }
        }
    }

    // anna redémarré : on se reconnecte tant qu'une session est ouverte.
    Timer {
        interval: 3000
        running: chat.open && chat.sessionId !== "" && !watchSock.connected
        repeat: true
        onTriggered: watchSock.connected = true
    }

    // ── Les commandes : une connexion chacune, une réponse chacune ───
    property var _queue: []

    // Un envoi peut attendre l'environnement du dossier (direnv, plusieurs
    // minutes la première fois) : hors de la file, sur sa propre connexion.
    function _slowRequest(obj, done) {
        slowSock.createObject(chat, { line: JSON.stringify(obj), done: done });
    }

    Component {
        id: slowSock
        Socket {
            id: one
            property string line: ""
            property var done: null
            function finish(r) {
                var f = one.done;
                one.done = null;
                if (f) {
                    f(r);
                    one.destroy();
                }
            }
            path: Anna.socketPath
            connected: true
            parser: SplitParser {
                onRead: (data) => {
                    var r;
                    try {
                        r = JSON.parse(data);
                    } catch (e) {
                        r = { ok: false, error: "anna" };
                    }
                    one.finish(r);
                }
            }
            onConnectedChanged: {
                if (connected)
                    write(one.line + "\n");
                else
                    one.finish({ ok: false, error: "anna" });
            }
            onError: one.finish({ ok: false, error: "anna" })
        }
    }

    function _request(obj, done) {
        chat._queue = chat._queue.concat([{ line: JSON.stringify(obj), done: done || null }]);
        if (!reqSock.connected && chat._queue.length === 1)
            reqSock.connected = true;
    }

    function _next(reply) {
        var head = chat._queue[0];
        chat._queue = chat._queue.slice(1);
        reqSock.connected = false;
        if (head && head.done)
            head.done(reply);
        if (chat._queue.length > 0)
            Qt.callLater(() => { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                var r;
                try {
                    r = JSON.parse(line);
                } catch (e) {
                    r = { ok: false, error: "anna" };
                }
                chat._next(r);
            }
        }
        onConnectedChanged: {
            if (connected && chat._queue.length > 0)
                write(chat._queue[0].line + "\n");
        }
    }
}
