pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les conversations Claude vues depuis le shell : l'index de ce qui existe sur
// le disque, le transcript de celle qu'on regarde, et la reprise en direct de
// cette même session.
//
// Un seul indexeur pour deux consommateurs — la recherche du dock
// ([ClaudeSource]) et son mode IA, qui lit et poursuit.
//
// Sur le disque, une session Claude Code est un JSONL append-only :
//   ~/.claude/projects/<cwd-slugifié>/<sessionId>.jsonl
// une ligne JSON par événement. C'est le fichier même que `claude --resume`
// rouvre : ce qu'on envoie depuis le dock atterrit dans la conversation, pas
// dans une copie. Reprendre une session ici la modifie donc pour de bon.
//
// Le travail sale est dans deux scripts voisins, claude-index.sh et
// claude-transcript.sh : du shell qui reste lisible et testable en shell,
// plutôt que la même chose échappée au travers d'une chaîne JavaScript.
QtObject {
    id: root

    readonly property string home: Quickshell.env("HOME") || "/home"

    // Les scripts vivent à côté de ce fichier. `Qt.resolvedUrl` suit le QML où
    // qu'il soit installé — dépôt de travail ou store Nix —, ce qui garde le
    // layout relocalisable.
    readonly property string scriptDir:
        Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

    // ── Index ────────────────────────────────────────────────────
    // Balayé une fois puis gardé en mémoire : aucune relecture disque par
    // frappe. Un index vide reste un index, sinon une machine sans session
    // relancerait le balayage à chaque appel.
    property var sessions: []
    property bool indexing: false
    property double indexedAt: 0
    readonly property int staleMs: 60000

    signal indexed()

    // Le mode IA ne montre que les sessions Claude Code : ce sont les seules
    // dont on sache lire le transcript et reprendre le fil.
    readonly property var liveSessions: root.sessions.filter(function (s) {
        return s.kind === "cli" && s.path.length > 0;
    })

    function ensureIndex() {
        if (root.indexing)
            return;
        if (root.indexedAt > 0 && Date.now() - root.indexedAt < root.staleMs)
            return;
        root.indexing = true;
        indexProc.running = true;
    }

    function refresh() {
        root.indexedAt = 0;
        root.ensureIndex();
    }

    property Process indexProc: Process {
        command: ["sh", root.scriptDir + "claude-index.sh"]
        stdout: StdioCollector { id: indexOut }

        onRunningChanged: {
            if (running)
                return;
            root._buildIndex(indexOut.text);
            root.indexing = false;
            root.indexedAt = Date.now();
            root.indexed();
        }
    }

    function _buildIndex(text) {
        var lines = text.split("\n");
        var out = [];

        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length < 6 || f[1].length === 0)
                continue;

            var title = f[5].trim();
            if (title.length === 0)
                title = "Session sans titre";

            var ts = parseFloat(f[3]) || 0;
            if (ts > 1e11)      // millisecondes côté Claude Desktop
                ts = ts / 1000;

            var cwd = f[2];
            var slash = cwd.lastIndexOf("/");

            out.push({
                kind:    f[0],
                id:      f[1],
                cwd:     cwd,
                project: slash >= 0 ? cwd.substring(slash + 1) : cwd,
                at:      ts,
                path:    f[4],
                title:   title.length > 90 ? title.substring(0, 89) + "…" : title
            });
        }

        out.sort(function (a, b) { return b.at - a.at; });
        root.sessions = out;
    }

    function ago(ts) {
        if (!ts)
            return "";
        var s = Date.now() / 1000 - ts;
        if (s < 3600)   return Math.max(1, Math.round(s / 60)) + " min";
        if (s < 86400)  return Math.round(s / 3600) + " h";
        if (s < 604800) return Math.round(s / 86400) + " j";
        return Qt.formatDateTime(new Date(ts * 1000), "dd/MM");
    }

    // ── Transcript ───────────────────────────────────────────────
    // Une seule session est lue à la fois — le dock n'en montre qu'une.
    property var current: null
    property ListModel messages: ListModel {}
    property bool loading: false
    property int total: 0

    // Parcourir le carrousel ne doit pas lancer un processus par cran.
    property Timer loadDebounce: Timer {
        interval: 140
        onTriggered: root._startLoad()
    }

    property string _loadingId: ""
    property bool _loadAgain: false

    function focus(s) {
        var id = s ? s.id : "";
        if (root.current && root.current.id === id)
            return;

        root.stopAgent();
        root.current = s || null;
        root.messages.clear();
        root.total = 0;
        root.liveError = "";
        root._liveIdx = -1;

        if (!s || s.kind !== "cli" || s.path.length === 0) {
            root.loading = false;
            loadDebounce.stop();
            return;
        }

        root.loading = true;
        loadDebounce.restart();
    }

    // Les chargements sont sérialisés plutôt que concurrents : on ne tue pas
    // un processus en vol, on enchaîne. Le résultat n'est appliqué que s'il
    // concerne toujours la session regardée, donc un aller-retour rapide dans
    // le carrousel ne peut pas repeindre l'écran avec un transcript périmé.
    function _startLoad() {
        if (loadProc.running) {
            root._loadAgain = true;
            return;
        }
        var s = root.current;
        if (!s || s.kind !== "cli" || s.path.length === 0)
            return;

        root._loadingId = s.id;
        loadProc.command = ["sh", root.scriptDir + "claude-transcript.sh", s.path];
        loadProc.running = true;
    }

    property Process loadProc: Process {
        stdout: StdioCollector { id: loadOut }

        onRunningChanged: {
            if (running)
                return;
            if (root.current && root._loadingId === root.current.id) {
                root._applyTranscript(loadOut.text);
                root.loading = false;
            }
            root._loadingId = "";
            if (root._loadAgain) {
                root._loadAgain = false;
                root._startLoad();
            }
        }
    }

    function _applyTranscript(text) {
        root.messages.clear();

        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            if (lines[i].length === 0)
                continue;

            var o;
            try { o = JSON.parse(lines[i]); } catch (e) { continue; }

            if (o.kind === "count") {
                root.total = o.n || 0;
                continue;
            }
            if (o.kind !== "msg")
                continue;

            if (o.text && o.text.length > 0)
                root.messages.append({ role: o.role, text: o.text });

            if (o.tools && o.tools.length > 0)
                root._appendTools(o.tools.join("  ·  "));
        }
    }

    // Une rafale d'outils tient sur une seule ligne : dix tours « ⚙ Bash »
    // d'affilée ne disent rien de plus qu'un seul, et noient le texte.
    function _appendTools(label) {
        var n = root.messages.count;
        if (n > 0) {
            var last = root.messages.get(n - 1);
            if (last.role === "tool") {
                root.messages.setProperty(n - 1, "text", last.text + "  ·  " + label);
                return;
            }
        }
        root.messages.append({ role: "tool", text: label });
    }

    // ── Reprise en direct ────────────────────────────────────────
    // Le CLI en mode headless : une ligne JSON par événement dans les deux
    // sens. C'est le même protocole que ai/ClaudeChat.qml, à ceci près qu'on
    // reprend une session existante au lieu d'en ouvrir une.
    //
    // Permissions : `acceptEdits` laisse passer les modifications de fichiers,
    // `--permission-prompts none` refuse automatiquement tout ce qui demanderait
    // un accord — sans quoi le dock, qui n'a pas de terminal pour répondre,
    // resterait pendu au premier outil non autorisé. Passer à
    // `bypassPermissions` donne un agent pleinement autonome ; c'est aussi un
    // agent qui exécute n'importe quoi depuis une barre de bureau.
    property string permissionMode: "acceptEdits"

    property bool streaming: false
    property string liveError: ""
    property int _liveIdx: -1
    property string _pending: ""

    readonly property bool canResume:
        root.current !== null && root.current.kind === "cli"

    property Process agent: Process {
        stdinEnabled: true
        workingDirectory: root.current && root.current.cwd.length > 0
                          ? root.current.cwd : root.home

        command: root.current ? ["claude", "-p",
                                 "--resume", root.current.id,
                                 "--input-format", "stream-json",
                                 "--output-format", "stream-json",
                                 "--include-partial-messages",
                                 "--verbose",
                                 "--permission-mode", root.permissionMode,
                                 "--permission-prompts", "none"]
                              : ["true"]

        stdout: SplitParser { onRead: (line) => root._onEvent(line) }
        stderr: SplitParser { onRead: (data) => root.liveError = data }

        // Le CLI n'écrit rien — pas même l'événement init — avant d'avoir reçu
        // son premier message : on vide la file dès que le processus est là.
        onStarted: root._flush()

        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            root.streaming = false;
            root._liveIdx = -1;
            root._pending = "";
            if (code !== 0)
                root.messages.append({
                    role: "tool",
                    text: "session interrompue (code " + code + ") — le prochain message la relance"
                });
        }
    }

    function send(text) {
        var t = (text || "").trim();
        if (t.length === 0 || root.streaming || !root.canResume)
            return;

        root.messages.append({ role: "user", text: t });
        root.messages.append({ role: "assistant", text: "" });
        root._liveIdx = root.messages.count - 1;
        root.streaming = true;
        root._pending = t;

        if (agent.running)
            root._flush();
        else
            agent.running = true;
    }

    function stopAgent() {
        if (agent.running)
            agent.running = false;
        root.streaming = false;
        root._pending = "";
        root._liveIdx = -1;
    }

    function _flush() {
        if (root._pending.length === 0)
            return;
        agent.write(JSON.stringify({
            type: "user",
            message: { role: "user", content: root._pending }
        }) + "\n");
        root._pending = "";
    }

    function _onEvent(line) {
        var raw = line.trim();
        if (raw.length === 0)
            return;

        var o;
        try { o = JSON.parse(raw); } catch (e) { return; }

        switch (o.type) {
        case "stream_event":
            root._onStreamEvent(o.event);
            break;
        case "result":
            root.streaming = false;
            root.total += 2;
            // Un tour qui n'a produit que des outils laisse une bulle vide.
            if (root._liveIdx >= 0 && root._liveIdx < root.messages.count
                    && root.messages.get(root._liveIdx).text === "") {
                if (o.is_error)
                    root.messages.setProperty(root._liveIdx, "text",
                        "[erreur : " + (o.subtype || "échec") + "]");
                else if (typeof o.result === "string" && o.result.length > 0)
                    root.messages.setProperty(root._liveIdx, "text", o.result);
                else
                    root.messages.remove(root._liveIdx);
            }
            root._liveIdx = -1;
            break;
        }
    }

    function _onStreamEvent(event) {
        if (!event)
            return;

        if (event.type === "content_block_start") {
            var block = event.content_block || {};
            if (block.type === "tool_use") {
                // La bulle en cours est vide : elle devient la ligne d'outils,
                // et le texte qui suivra ouvrira une bulle neuve.
                if (root._liveIdx >= 0 && root._liveIdx < root.messages.count
                        && root.messages.get(root._liveIdx).text === "")
                    root.messages.remove(root._liveIdx);
                root._appendTools(block.name || "outil");
                root._liveIdx = -1;
            }
            return;
        }

        if (event.type === "content_block_delta") {
            var delta = event.delta || {};
            if (delta.type !== "text_delta" || typeof delta.text !== "string")
                return;
            if (root._liveIdx < 0) {
                root.messages.append({ role: "assistant", text: "" });
                root._liveIdx = root.messages.count - 1;
            }
            root.messages.setProperty(root._liveIdx, "text",
                root.messages.get(root._liveIdx).text + delta.text);
        }
    }
}
