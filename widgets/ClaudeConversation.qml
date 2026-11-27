pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"

// Une conversation Claude Code, dans l'onglet Claude (services/ClaudeChat) :
// on la lit et on y écrit, comme dans Claude Desktop.
//
//   ← Titre de la session                              ●
//     karenine  main            Demander · Éditions · Plan   0,26 $
//   ┌──────────────────────────────────────────────────────┐
//   │                              ╭ Ajoute un bouton… ╮   │  la demande
//   │ Je regarde l'explorateur.                            │  le texte
//   │ ▸ Read  widgets/FileExplorer.qml                     │  un outil, replié
//   │ ▾ Edit  widgets/FileExplorer.qml                     │  déplié : le diff
//   │   - var x = 1                                        │
//   │   + var x = 2                                        │
//   │ C'est fait.▍                                          │  ce qui s'écrit
//   └──────────────────────────────────────────────────────┘
//   ╭ Écris à Claude…                                 (➤) ╮
//
// Une session tenue par un terminal se lit en direct ; on n'y écrit qu'après
// « Prendre la main », qui ferme ce terminal. Les permissions que Claude
// demande s'ouvrent en carte (PromptHost), où que l'on soit.
Item {
    id: root

    readonly property var st: ClaudeChat.state
    readonly property bool held: ClaudeChat.elsewhere > 0 && !root.st.driven
    readonly property string mono: "JetBrains Mono"
    // Un sous-agent : on le lit, on ne lui écrit pas.
    readonly property bool isAgent: ClaudeChat.agent !== ""

    // Le volet montré : la conversation, ou l'un de ceux du résumé
    // (ClaudeSessionPanes).
    property string pane: "chat"
    readonly property var sum: ClaudeChat.summary
    readonly property int running: root.sum.jobs.filter(j => j.status === "running").length
    readonly property var panes: [
        { id: "chat", label: I18n.tr("claude.pane.chat"), badge: "" },
        { id: "changes", label: I18n.tr("claude.pane.changes"),
          badge: root.sum.changes.length > 0 ? String(root.sum.changes.length) : "" },
        { id: "outputs", label: I18n.tr("claude.pane.outputs"),
          badge: root.sum.outputs.length > 0 ? String(root.sum.outputs.length) : "" },
        { id: "jobs", label: I18n.tr("claude.pane.jobsTab"),
          badge: root.running > 0 ? "● " + root.running
               : root.sum.jobs.length + root.sum.todos.length > 0 ? String(root.sum.jobs.length + root.sum.todos.length) : "" }
    ]
    readonly property real ctxWindow: root.st.window > 0 ? root.st.window : root.sum.context.window

    Connections {
        target: ClaudeChat
        function onAgentChanged() {
            root.pane = "chat";
        }
        function onOpenChanged() {
            root.pane = "chat";
        }
    }

    // Les modes de permission proposés (ceux de `claude --permission-mode`).
    readonly property var modes: [
        { id: "default", label: I18n.tr("claude.chat.modeAsk"), sub: I18n.tr("claude.chat.modeAskSub") },
        { id: "acceptEdits", label: I18n.tr("claude.chat.modeEdits"), sub: I18n.tr("claude.chat.modeEditsSub") },
        { id: "plan", label: I18n.tr("claude.chat.modePlan"), sub: I18n.tr("claude.chat.modePlanSub") },
        { id: "auto", label: I18n.tr("claude.chat.modeAuto"), sub: I18n.tr("claude.chat.modeAutoSub") }
    ]

    function modeLabel(id) {
        var m = root.modes.find((x) => x.id === id);
        return m ? m.label : id;
    }

    // Les niveaux d'effort, ceux du modèle montré quand il les dit.
    readonly property var effortNames: ({
        low: I18n.tr("claude.chat.effortLow"), medium: I18n.tr("claude.chat.effortMedium"),
        high: I18n.tr("claude.chat.effortHigh"), xhigh: I18n.tr("claude.chat.effortXhigh"),
        max: I18n.tr("claude.chat.effortMax")
    })
    readonly property var efforts: {
        var m = ClaudeChat.modelEntry(ClaudeChat.modelShown);
        return m && m.supportedEffortLevels ? m.supportedEffortLevels : ["low", "medium", "high", "xhigh", "max"];
    }

    // Les modèles du menu ; avant que `claude` les ait dits, les alias.
    readonly property var modelChoices: ClaudeChat.models.length > 0 ? ClaudeChat.models : [
        { value: "default", displayName: I18n.tr("claude.chat.modelDefault"), description: "" },
        { value: "opus", displayName: "Opus", description: "" },
        { value: "sonnet", displayName: "Sonnet", description: "" },
        { value: "haiku", displayName: "Haiku", description: "" }
    ]

    // Le contexte rempli, pour l'anneau sous le champ.
    readonly property real ctxFill: root.ctxWindow > 0 ? Math.min(1, root.sum.context.tokens / root.ctxWindow) : 0

    // De quoi envoyer : du texte, ou une pièce jointe.
    readonly property bool canSend: ClaudeChat.draft.trim() !== "" || ClaudeChat.files.length > 0

    // ── Les commandes « / » ──────────────────────────────────────────
    // Celles que l'interface fait elle-même : Claude Code ne les a que dans
    // son terminal, ou elles ont ici leur bouton.
    readonly property var ownCommands: [
        { name: "usage", aliases: ["cost", "stats"], description: I18n.tr("claude.slash.usage"), argumentHint: "" },
        { name: "clear", aliases: ["new", "reset"], description: I18n.tr("claude.slash.clear"), argumentHint: "" },
        { name: "context", aliases: [], description: I18n.tr("claude.slash.context"), argumentHint: "" },
        { name: "model", aliases: [], description: I18n.tr("claude.slash.model"), argumentHint: "" },
        { name: "effort", aliases: [], description: I18n.tr("claude.slash.effort"), argumentHint: "" },
        { name: "permissions", aliases: ["mode"], description: I18n.tr("claude.slash.permissions"), argumentHint: "" },
        { name: "plan", aliases: [], description: I18n.tr("claude.slash.plan"), argumentHint: "" },
        { name: "remote-control", aliases: ["rc"], description: I18n.tr("claude.slash.remote"), argumentHint: "" },
        { name: "resume", aliases: ["continue", "sessions"], description: I18n.tr("claude.slash.resume"), argumentHint: "" },
        { name: "exit", aliases: ["quit"], description: I18n.tr("claude.slash.exit"), argumentHint: "" },
        { name: "help", aliases: [], description: I18n.tr("claude.slash.help"), argumentHint: "" }
    ]
    // Celles de Claude Code, avant qu'il ait dit les siennes.
    readonly property var someCommands: [
        { name: "compact", aliases: [], description: I18n.tr("claude.slash.compact"), argumentHint: "" }
    ]

    // Ce qui est tapé après « / », tant que c'est un nom de commande.
    readonly property string slashWord: {
        var m = /^\/([\w:.-]*)$/.exec(ClaudeChat.draft);
        return m ? m[1].toLowerCase() : "";
    }
    readonly property bool slashTyped: /^\/[\w:.-]*$/.test(ClaudeChat.draft)
    // Fermé par Échap : jusqu'à ce que le texte change.
    property string slashClosed: ""
    readonly property bool slashOpen: root.slashTyped && !root.held && root.menu === ""
        && ClaudeChat.draft !== root.slashClosed && root.slashList.length > 0
    onSlashTypedChanged: {
        root.slashClosed = "";
        if (root.slashTyped && ClaudeChat.commands.length === 0)
            ClaudeChat.fetchCommands();
    }

    // Les commandes qui correspondent : le nom exact, puis le début du nom,
    // d'un autre nom, puis le milieu.
    readonly property var slashList: {
        if (!root.slashTyped)
            return [];
        var taken = {};
        var all = root.ownCommands.concat(ClaudeChat.commands.length > 0 ? ClaudeChat.commands : root.someCommands)
            .filter((c) => {
                if (taken[c.name])
                    return false;
                taken[c.name] = true;
                return true;
            });
        var q = root.slashWord;
        var rank = (c) => {
            var names = [c.name].concat(c.aliases || []).map((n) => n.toLowerCase());
            return names.indexOf(q) >= 0 ? 0
                 : names[0].startsWith(q) ? 1
                 : names.some((n) => n.startsWith(q)) ? 2
                 : names.some((n) => n.indexOf(q) >= 0) ? 3 : 4;
        };
        return all.map((c, i) => ({ c: c, r: q === "" ? 0 : rank(c), i: i }))
            .filter((x) => x.r < 4)
            .sort((a, b) => a.r - b.r || a.i - b.i)
            .map((x) => x.c);
    }

    function setInput(text) {
        ClaudeChat.setDraft(text);
        input.cursorPosition = input.length;
        input.forceActiveFocus();
    }

    function openMenu(name) {
        ClaudeChat.setDraft("");
        root.menu = name;
        if (name === "context")
            ClaudeChat.fetchUsage();
    }

    // Faire soi-même la commande de `text` ; faux : c'est à Claude Code.
    function runOwn(text) {
        var m = /^\/([\w:.-]+)(?:\s+([\s\S]*))?$/.exec(text.trim());
        if (!m || ClaudeChat.files.length > 0)
            return false;
        var name = m[1].toLowerCase();
        var arg = (m[2] || "").trim();
        var own = root.ownCommands.find((c) => c.name === name || c.aliases.indexOf(name) >= 0);
        if (!own)
            return false;
        switch (own.name) {
        case "clear":
            ClaudeChat.clear();
            return true;
        case "usage":
        case "context":
            root.openMenu("context");
            return true;
        case "model":
            if (arg !== "") {
                // Un modèle que le menu n'a pas : Claude Code dira.
                if (!root.modelChoices.some((x) => x.value === arg))
                    return false;
                ClaudeChat.setModel(arg);
                ClaudeChat.setDraft("");
            } else {
                root.openMenu("model");
            }
            return true;
        case "effort":
            if (arg !== "") {
                if (root.efforts.indexOf(arg) < 0)
                    return false;
                ClaudeChat.setEffort(arg);
                ClaudeChat.setDraft("");
            } else {
                root.openMenu("effort");
            }
            return true;
        case "permissions":
            root.openMenu("mode");
            return true;
        case "plan":
            ClaudeChat.setMode("plan");
            if (arg !== "") {
                ClaudeChat.send(arg);
                list.stick = true;
            } else {
                ClaudeChat.setDraft("");
            }
            return true;
        case "remote-control":
            if (!root.st.driven)
                return false;
            ClaudeChat.toggleRemote();
            ClaudeChat.setDraft("");
            return true;
        case "resume":
            ClaudeChat.setDraft("");
            ClaudeChat.close();
            return true;
        case "exit":
            ClaudeChat.setDraft("");
            if (root.st.driven && !root.st.busy && (root.st.asks || []).length === 0)
                ClaudeChat.stop();
            ClaudeChat.close();
            return true;
        case "help":
            root.setInput("/");
            return true;
        }
        return false;
    }

    // La commande choisie dans la liste : lancée, ou écrite pour qu'on la
    // complète quand elle attend quelque chose.
    function pickSlash(c) {
        if (!c)
            return;
        if ((c.argumentHint || "") !== "") {
            root.setInput("/" + c.name + " ");
            return;
        }
        ClaudeChat.setDraft("/" + c.name);
        root.submit();
    }

    // Le menu ouvert sous le champ : "attach", "model", "effort", "mode",
    // "context" ou "".
    property string menu: ""

    function toolColor(it) {
        return !it.done ? Theme.colorCyan : it.error ? Theme.colorDanger : Theme.textDim;
    }

    // Les lignes d'un diff : celles du patch de Claude Code, sinon le texte
    // remplacé et le nouveau ; [{ sign, text }].
    function diffLines(it) {
        var out = [];
        if (it.patch && it.patch.length) {
            it.patch.forEach((h, i) => {
                if (i > 0)
                    out.push({ sign: "@", text: "…" });
                (h.lines || []).forEach((l) => out.push({ sign: l.charAt(0), text: l.slice(1) }));
            });
        } else if (it.input) {
            var inp = it.input;
            (inp.old_string || "").split("\n").forEach((l) => { if (inp.old_string) out.push({ sign: "-", text: l }); });
            (inp.new_string || inp.content || "").split("\n").forEach((l) => out.push({ sign: "+", text: l }));
        }
        return out;
    }

    function isEdit(it) {
        return ["Edit", "MultiEdit", "Write", "NotebookEdit"].indexOf(it.tool) >= 0;
    }

    function noteText(t) {
        if (t === "compacted")
            return I18n.tr("claude.chat.compacted");
        if (t === "interrupted")
            return I18n.tr("claude.chat.interrupted");
        return t;
    }

    // ── L'en-tête ────────────────────────────────────────────────────
    ColumnLayout {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Rectangle {
                implicitWidth: 28
                implicitHeight: 28
                radius: Theme.radiusSmall
                color: backMa.containsMouse ? Theme.hoverOverlay : "transparent"
                NixIcon {
                    anchors.centerIn: parent
                    iconSize: 16
                    source: "../assets/icons/arrow-left.svg"
                    color: Theme.textPrimary
                }
                MouseArea {
                    id: backMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ClaudeChat.close()
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.isAgent
                      ? I18n.tr("claude.chat.agent", { title: ClaudeChat.agentTitle || ClaudeChat.agent })
                      : ClaudeChat.session.title || (ClaudeChat.isNew ? I18n.tr("claude.chat.new") : ClaudeChat.session.project || "")
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 14
                font.weight: Font.DemiBold
                color: Theme.textPrimary
            }
            Rectangle {
                implicitWidth: 8
                implicitHeight: 8
                radius: 4
                color: root.st.asking !== "" ? Theme.accentColor
                     : root.st.busy ? Theme.colorCyan
                     : root.st.driven || root.held ? Theme.textSecondary : Theme.textDim
                SequentialAnimation on opacity {
                    running: (root.st.busy || root.st.asking !== "") && root.visible
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 36
            spacing: 6

            Text {
                visible: text !== ""
                text: ClaudeChat.session.project || ""
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textSecondary
            }
            Rectangle {
                visible: (ClaudeChat.session.branch || "") !== ""
                Layout.maximumWidth: 140
                implicitWidth: branchText.implicitWidth + 12
                implicitHeight: 18
                radius: 5
                color: Theme.hoverOverlay
                Text {
                    id: branchText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 12)
                    elide: Text.ElideMiddle
                    text: ClaudeChat.session.branch || ""
                    font.family: root.mono
                    font.pixelSize: 10
                    color: Theme.textSecondary
                }
            }
            Item { Layout.fillWidth: true }
            // Remote Control : un clic le coupe ou le remet ; le lien ouvre
            // la session sur claude.ai.
            Text {
                visible: root.st.driven && !root.isAgent
                text: (ClaudeChat.remoteOn ? "● " : "○ ")
                      + I18n.tr(ClaudeChat.remoteOn && root.st.remote !== "connected" && root.st.remote !== "ready"
                                ? "claude.chat.remoteConnecting" : "claude.chat.remote")
                font.family: "Inter"
                font.pixelSize: 11
                color: root.st.remote === "failed" ? Theme.colorDanger
                     : ClaudeChat.remoteOn ? Theme.accentColor : Theme.textDim
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ClaudeChat.toggleRemote()
                }
            }
            Text {
                visible: root.st.driven && !root.isAgent && ClaudeChat.remoteOn && root.st.remote_url !== ""
                text: "↗"
                font.family: "Inter"
                font.pixelSize: 13
                color: Theme.accentColor
                Accessible.name: I18n.tr("claude.chat.remoteOpen")
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(["xdg-open", root.st.remote_url])
                }
            }
            Text {
                visible: root.st.driven && root.st.cost > 0
                text: root.st.cost.toFixed(2) + " $"
                font.family: "Inter"
                font.pixelSize: 11
                font.features: { "tnum": 1 }
                color: Theme.textDim
            }
        }

        // L'environnement du dossier ou Remote Control a échoué.
        Text {
            Layout.fillWidth: true
            Layout.leftMargin: 36
            visible: text !== "" && root.st.driven && !root.isAgent
            text: [root.st.env === "blocked" ? I18n.tr("claude.chat.envBlocked")
                   : root.st.env === "failed" ? I18n.tr("claude.chat.envFailed") : "",
                   root.st.remote === "failed" ? I18n.tr("claude.chat.remoteError", { error: root.st.remote_error }) : ""]
                  .filter((t) => t !== "").join("\n")
            wrapMode: Text.Wrap
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.colorWarning
        }

        // Les volets : la conversation, le contexte, les changements, les
        // sorties, les tâches ; chacun avec son compte.
        Flickable {
            Layout.fillWidth: true
            implicitHeight: 28
            contentWidth: paneRow.implicitWidth
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            Row {
                id: paneRow
                spacing: 2
                Repeater {
                    model: root.panes
                    Rectangle {
                        id: paneTab
                        required property var modelData
                        readonly property bool active: root.pane === paneTab.modelData.id
                        width: paneTabRow.implicitWidth + 16
                        height: 28
                        radius: Theme.radiusSmall
                        color: paneTab.active ? Theme.selectedFill : paneMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        Row {
                            id: paneTabRow
                            anchors.centerIn: parent
                            spacing: 5
                            Text {
                                text: paneTab.modelData.label
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: paneTab.active ? Font.DemiBold : Font.Medium
                                color: paneTab.active ? Theme.textPrimary : Theme.textSecondary
                            }
                            Text {
                                visible: text !== ""
                                text: paneTab.modelData.badge
                                font.family: "Inter"
                                font.pixelSize: 10
                                font.features: { "tnum": 1 }
                                anchors.verticalCenter: parent.verticalCenter
                                color: paneTab.modelData.badge.charAt(0) === "●" ? Theme.colorCyan : Theme.textDim
                            }
                        }
                        MouseArea {
                            id: paneMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.pane = paneTab.modelData.id
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Theme.dividerColor
        }
    }

    // ── Les volets du résumé ─────────────────────────────────────────
    ClaudeSessionPanes {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: 8
        visible: root.pane !== "chat"
        pane: root.pane
    }

    // ── La conversation ──────────────────────────────────────────────
    ListView {
        id: list
        visible: root.pane === "chat"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: composer.visible ? composer.top : parent.bottom
        anchors.topMargin: 4
        anchors.bottomMargin: 8
        clip: true
        spacing: 10
        boundsBehavior: Flickable.StopAtBounds
        model: ClaudeChat.items
        cacheBuffer: 1200

        // Collée en bas tant qu'on n'est pas remonté lire plus haut.
        property bool stick: true
        onMovementEnded: list.stick = list.atYEnd
        onAtYBeginningChanged: if (list.atYBeginning && list.moving) ClaudeChat.loadEarlier()
        onContentHeightChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)

        Connections {
            target: ClaudeChat
            function onAppended() {
                if (list.stick)
                    Qt.callLater(list.positionViewAtEnd);
            }
            function onPrepended(count) {
                list.positionViewAtIndex(count, ListView.Beginning);
            }
            function onOpenChanged() {
                list.stick = true;
            }
        }

        header: Item {
            width: list.width
            height: ClaudeChat.first > 0 ? 34 : (ClaudeChat.loaded && ClaudeChat.items.count === 0 ? 120 : 0)
            Text {
                anchors.centerIn: parent
                visible: ClaudeChat.first > 0
                text: ClaudeChat.loadingEarlier ? "…" : I18n.tr("claude.chat.earlier")
                font.family: "Inter"
                font.pixelSize: 12
                color: earlierMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                MouseArea {
                    id: earlierMa
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ClaudeChat.loadEarlier()
                }
            }
            Text {
                anchors.centerIn: parent
                width: parent.width - 32
                visible: ClaudeChat.first === 0 && ClaudeChat.loaded && ClaudeChat.items.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: ClaudeChat.isNew ? I18n.tr("claude.chat.newHint", { project: ClaudeChat.session.project || "" })
                                       : I18n.tr("claude.chat.empty")
                font.family: "Inter"
                font.pixelSize: 13
                color: Theme.textSecondary
            }
        }

        delegate: Item {
            id: row
            required property string json
            required property int index
            readonly property var it: JSON.parse(row.json)
            readonly property bool sub: (row.it.parent || "") !== ""
            width: list.width
            implicitHeight: body.implicitHeight

            // Un sous-agent : décalé, un trait à gauche.
            Rectangle {
                visible: row.sub
                x: 4
                width: 2
                height: parent.height
                radius: 1
                color: Theme.dividerColor
            }

            Loader {
                id: body
                x: row.sub ? 14 : 0
                width: parent.width - x
                sourceComponent: row.it.kind === "user" ? userItem
                               : row.it.kind === "text" ? textItem
                               : row.it.kind === "thinking" ? thinkingItem
                               : row.it.kind === "tool" ? toolItem
                               : noteItem
            }
            // L'élément chargé reçoit son JSON relu, et le suit.
            Binding {
                target: body.item
                property: "it"
                value: row.it
                when: body.status === Loader.Ready
            }
        }

        footer: Item {
            width: list.width
            height: footCol.implicitHeight + 8
            Column {
                id: footCol
                width: parent.width
                spacing: 6
                topPadding: 4

                // Ce qui s'écrit. Un Text neuf à chaque fragment (le Repeater
                // recrée tout quand son tableau change) : réécrit en place, un
                // Markdown de plus de 64 nœuds (un tableau) fait planter
                // Qt 6.12.0 (QTBUG-151670, corrigé en 6.12.1).
                Repeater {
                    model: ClaudeChat.partial.text !== "" ? [ClaudeChat.partial] : []
                    MarkdownText {
                        id: writing
                        required property var modelData
                        readonly property bool thinking: writing.modelData.kind === "thinking"
                        width: footCol.width
                        links: !writing.thinking
                        markdown: writing.modelData.text + " ▍"
                        font.family: "Inter"
                        font.pixelSize: 13
                        font.italic: writing.thinking
                        lineHeight: 1.15
                        color: writing.thinking ? Theme.textDim : Theme.textPrimary
                    }
                }
                // Il travaille, ou attend une permission.
                Text {
                    id: workingText
                    visible: (root.st.busy || ClaudeChat.sending) && ClaudeChat.partial.text === ""
                    text: root.st.asking !== "" ? I18n.tr("claude.chat.asking", { tool: root.st.asking })
                        : ClaudeChat.sending && !root.st.driven ? I18n.tr("claude.chat.envLoading")
                        : I18n.tr("claude.chat.working")
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: root.st.asking !== "" ? Theme.accentColor : Theme.colorCyan
                    SequentialAnimation on opacity {
                        running: workingText.visible
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.4; duration: 700 }
                        NumberAnimation { to: 1; duration: 700 }
                    }
                }
                Text {
                    width: parent.width
                    visible: root.st.error !== ""
                    text: root.st.error
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: Theme.colorDanger
                }
            }
        }
    }

    // ── Les éléments ─────────────────────────────────────────────────
    Component {
        id: userItem
        Item {
            id: u
            property var it: ({})
            implicitHeight: bubble.height
            Rectangle {
                id: bubble
                anchors.right: parent.right
                width: Math.min(parent.width * 0.85, Math.max(userText.implicitWidth, 80) + 24)
                height: userCol.implicitHeight + 16
                radius: Theme.radius
                color: Qt.alpha(Theme.accentColor, 0.14)
                Column {
                    id: userCol
                    x: 12
                    y: 8
                    width: parent.width - 24
                    spacing: 4
                    Text {
                        id: userText
                        width: parent.width
                        visible: (u.it.text || "") !== ""
                        text: u.it.text || ""
                        wrapMode: Text.Wrap
                        font.family: "Inter"
                        font.pixelSize: 13
                        color: Theme.textPrimary
                    }
                    Text {
                        visible: (u.it.images || 0) > 0
                        text: I18n.tr("claude.chat.images", { n: u.it.images || 0 })
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textSecondary
                    }
                }
            }
        }
    }

    Component {
        id: textItem
        MarkdownText {
            property var it: ({})
            markdown: it.text || ""
            font.family: "Inter"
            font.pixelSize: 13
            lineHeight: 1.15
            color: Theme.textPrimary
        }
    }

    Component {
        id: thinkingItem
        Column {
            id: th
            property var it: ({})
            property bool expanded: false
            spacing: 4
            Text {
                text: (th.expanded ? "▾ " : "▸ ") + I18n.tr("claude.chat.thinking")
                font.family: "Inter"
                font.pixelSize: 12
                font.italic: true
                color: thMa.containsMouse ? Theme.textSecondary : Theme.textDim
                MouseArea {
                    id: thMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: th.expanded = !th.expanded
                }
            }
            Text {
                visible: th.expanded
                width: th.width
                text: th.it.text || ""
                wrapMode: Text.Wrap
                font.family: "Inter"
                font.pixelSize: 12
                font.italic: true
                color: Theme.textDim
            }
        }
    }

    Component {
        id: noteItem
        Text {
            property var it: ({})
            horizontalAlignment: Text.AlignHCenter
            text: it.kind === "other" ? "[" + (it.text || "") + "]" : root.noteText(it.text || "")
            elide: Text.ElideRight
            font.family: it.kind === "note" && (it.text || "").charAt(0) === "/" ? root.mono : "Inter"
            font.pixelSize: 11
            color: Theme.textDim
        }
    }

    Component {
        id: toolItem
        Column {
            id: tool
            property var it: ({})
            property bool expanded: false
            property string full: ""
            spacing: 6

            // La ligne : l'état, l'outil, ce sur quoi il travaille.
            Rectangle {
                width: tool.width
                height: 28
                radius: Theme.radiusSmall
                color: toolMa.containsMouse ? Theme.hoverOverlay : "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 7
                    Text {
                        text: tool.expanded ? "▾" : "▸"
                        font.pixelSize: 10
                        color: Theme.textDim
                    }
                    Rectangle {
                        implicitWidth: 6
                        implicitHeight: 6
                        radius: 3
                        color: root.toolColor(tool.it)
                    }
                    Text {
                        text: (tool.it.tool || "").replace(/^mcp__/, "").replace(/__/, " › ")
                        font.family: root.mono
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: tool.it.error ? Theme.colorDanger : Theme.textPrimary
                    }
                    Text {
                        Layout.fillWidth: true
                        text: tool.it.summary || ""
                        elide: Text.ElideMiddle
                        font.family: root.mono
                        font.pixelSize: 11
                        color: Theme.textSecondary
                    }
                }
                MouseArea {
                    id: toolMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tool.expanded = !tool.expanded
                }
            }

            // Déplié : le diff d'une édition, sinon l'entrée et la sortie.
            Rectangle {
                visible: tool.expanded
                width: tool.width
                height: detail.implicitHeight + 16
                radius: Theme.radiusSmall
                color: Theme.bgDeep
                Column {
                    id: detail
                    x: 10
                    y: 8
                    width: parent.width - 20
                    spacing: 6

                    // Une édition.
                    Column {
                        visible: tool.expanded && root.isEdit(tool.it)
                        width: parent.width
                        Repeater {
                            model: tool.expanded && root.isEdit(tool.it) ? root.diffLines(tool.it).slice(0, 400) : []
                            Text {
                                required property var modelData
                                width: detail.width
                                text: (modelData.sign === "@" ? "" : modelData.sign + " ") + modelData.text
                                wrapMode: Text.WrapAnywhere
                                font.family: root.mono
                                font.pixelSize: 11
                                color: modelData.sign === "+" ? Theme.colorSuccess
                                     : modelData.sign === "-" ? Theme.colorDanger : Theme.textDim
                            }
                        }
                    }

                    // L'entrée : la commande, sinon les arguments.
                    Text {
                        visible: tool.expanded && !root.isEdit(tool.it)
                        width: parent.width
                        text: !tool.expanded || root.isEdit(tool.it) ? ""
                            : tool.it.tool === "Bash" ? "$ " + ((tool.it.input || {}).command || "")
                            : JSON.stringify(tool.it.input || {}, null, 2).slice(0, 4000)
                        wrapMode: Text.WrapAnywhere
                        font.family: root.mono
                        font.pixelSize: 11
                        color: Theme.colorCyan
                    }

                    // La sortie.
                    Text {
                        visible: tool.expanded && (tool.full !== "" || ((tool.it.output || "") !== "" && !root.isEdit(tool.it)))
                        width: parent.width
                        text: {
                            if (!tool.expanded)
                                return "";
                            var t = tool.full !== "" ? tool.full : (tool.it.output || "");
                            var lines = t.split("\n");
                            return tool.full === "" && lines.length > 60 ? lines.slice(0, 60).join("\n") + "\n…" : t;
                        }
                        wrapMode: Text.WrapAnywhere
                        font.family: root.mono
                        font.pixelSize: 11
                        color: tool.it.error ? Theme.colorDanger : Theme.textSecondary
                    }

                    // La sortie entière, quand elle a été coupée.
                    Text {
                        visible: tool.expanded && tool.full === ""
                                 && ((tool.it.persisted || "") !== "" || (tool.it.output || "").split("\n").length > 60)
                        text: I18n.tr("claude.chat.fullOutput")
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: fullMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                        MouseArea {
                            id: fullMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if ((tool.it.persisted || "") !== "")
                                    ClaudeChat.fetchOutput(tool.it.persisted, (t) => tool.full = t);
                                else
                                    tool.full = tool.it.output;
                            }
                        }
                    }

                    // Un sous-agent : sa propre conversation.
                    Text {
                        visible: tool.expanded && (tool.it.agent || "") !== ""
                        text: I18n.tr("claude.pane.openAgent")
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: subMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                        MouseArea {
                            id: subMa
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ClaudeChat.openAgent(tool.it.agent, (tool.it.input || {}).description || "")
                        }
                    }

                    Text {
                        visible: tool.expanded && !tool.it.done
                        text: I18n.tr("claude.chat.running")
                        font.family: "Inter"
                        font.pixelSize: 11
                        font.italic: true
                        color: Theme.textDim
                    }
                }
            }
        }
    }

    // ── L'écriture ───────────────────────────────────────────────────
    ColumnLayout {
        id: composer
        visible: root.pane === "chat" && !root.isAgent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 6

        Text {
            Layout.fillWidth: true
            visible: ClaudeChat.error !== ""
            text: ClaudeChat.error
            wrapMode: Text.Wrap
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.colorDanger
        }

        // Ce que Claude demande : une permission, ou ses questions. On y
        // répond ici, comme dans Claude Desktop ; la plus ancienne d'abord.
        Repeater {
            model: ScriptModel {
                objectProp: "id"
                values: root.st.asks || []
            }
            ClaudeAsk {
                required property var modelData
                required property int index
                visible: index === 0
                Layout.fillWidth: true
                request: modelData
                count: root.st.asks.length
                onAnswered: (action, values) => ClaudeChat.answer(modelData.id, action, values)
            }
        }

        // Tenue par un terminal : on y va, ou on la prend.
        Rectangle {
            visible: root.held
            Layout.fillWidth: true
            implicitHeight: heldCol.implicitHeight + 20
            radius: Theme.radius
            color: Theme.bgElevated
            ColumnLayout {
                id: heldCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 12
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: I18n.tr("claude.chat.held")
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: Theme.textSecondary
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.fillWidth: true }
                    Repeater {
                        model: [
                            { label: I18n.tr("claude.goTerminal"), primary: false },
                            { label: I18n.tr("claude.chat.takeOver"), primary: true }
                        ]
                        Rectangle {
                            id: heldBtn
                            required property var modelData
                            implicitWidth: heldText.implicitWidth + 20
                            implicitHeight: 28
                            radius: Theme.radiusSmall
                            color: heldBtn.modelData.primary ? Theme.selectedFill
                                 : heldMa.containsMouse ? Theme.hoverOverlay : "transparent"
                            border.width: heldBtn.modelData.primary ? 0 : 1
                            border.color: Theme.dividerColor
                            Text {
                                id: heldText
                                anchors.centerIn: parent
                                text: heldBtn.modelData.label
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: Theme.textPrimary
                            }
                            MouseArea {
                                id: heldMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: heldBtn.modelData.primary ? ClaudeChat.takeOver(false) : ClaudeChat.focusTerminal()
                            }
                        }
                    }
                }
            }
        }

        // ── Le compositeur : une seule carte ─────────────────────────
        //   ╭───────────────────────────────────────────────╮
        //   │ [▣ capture.png ×] [▤ notes.md ×]              │  les pièces jointes
        //   │ Écrire à Claude…                              │  le texte
        //   │ (+)  Opus 5.5 ⌄  Élevé ⌄  Éditions ⌄   ◔ 🎤 (➤) │  les outils
        //   ╰───────────────────────────────────────────────╯
        // Le modèle, l'effort et le mode ouvrent leur menu ; l'anneau, le
        // volet Contexte. Des fichiers s'y déposent.
        Rectangle {
            id: promptCard
            visible: !root.held
            Layout.fillWidth: true
            implicitHeight: composerCol.implicitHeight + 16
            radius: Theme.radius + 4
            color: Theme.bgElevated
            border.width: 1
            border.color: input.activeFocus || fileDrop.containsDrag ? Qt.alpha(Theme.accentColor, 0.55)
                        : Qt.alpha(Theme.textPrimary, 0.08)
            Behavior on border.color { ColorAnimation { duration: 140 } }

            // Un clic sur la carte, hors des boutons : on écrit.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: input.forceActiveFocus()
            }

            // Des fichiers déposés (l'Explorer, un gestionnaire de fichiers).
            DropArea {
                id: fileDrop
                anchors.fill: parent
                keys: ["text/uri-list"]
                onDropped: (drop) => {
                    var paths = [];
                    for (var i = 0; i < drop.urls.length; i++) {
                        var u = drop.urls[i].toString();
                        if (u.startsWith("file:///"))
                            paths.push(decodeURIComponent(u.substring(7)));
                    }
                    ClaudeChat.addFiles(paths);
                    drop.accept(Qt.CopyAction);
                }
            }

            ColumnLayout {
                id: composerCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 8
                spacing: 6

                // Les pièces jointes du prochain message ; × en retire une.
                Flow {
                    visible: ClaudeChat.files.length > 0
                    Layout.fillWidth: true
                    Layout.leftMargin: 2
                    Layout.rightMargin: 2
                    spacing: 6
                    Repeater {
                        model: ClaudeChat.files
                        Rectangle {
                            id: joined
                            required property string modelData
                            readonly property bool image: /\.(png|jpe?g|webp|gif)$/i.test(joined.modelData)
                            width: joinedRow.implicitWidth + 10
                            height: 30
                            radius: Theme.radiusSmall
                            color: Theme.bgDeep
                            Row {
                                id: joinedRow
                                anchors.verticalCenter: parent.verticalCenter
                                x: 4
                                spacing: 6
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22
                                    height: 22
                                    radius: 5
                                    color: Qt.alpha(Theme.textPrimary, 0.06)
                                    clip: true
                                    Image {
                                        visible: joined.image
                                        anchors.fill: parent
                                        source: joined.image ? "file://" + encodeURI(joined.modelData).replace(/#/g, "%23").replace(/\?/g, "%3F") : ""
                                        sourceSize.width: 44
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                    }
                                    NixIcon {
                                        visible: !joined.image
                                        anchors.centerIn: parent
                                        iconSize: 13
                                        source: "../assets/icons/file.svg"
                                        color: Theme.textSecondary
                                    }
                                }
                                Text {
                                    width: Math.min(implicitWidth, 140)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: joined.modelData.substring(joined.modelData.lastIndexOf("/") + 1)
                                    textFormat: Text.PlainText
                                    elide: Text.ElideMiddle
                                    font.family: "Inter"
                                    font.pixelSize: 11
                                    color: Theme.textPrimary
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18
                                    height: 18
                                    radius: 9
                                    color: joinedMa.containsMouse ? Theme.hoverOverlay : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        font.pixelSize: 13
                                        color: joinedMa.containsMouse ? Theme.textPrimary : Theme.textDim
                                    }
                                    MouseArea {
                                        id: joinedMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: ClaudeChat.removeFile(joined.modelData)
                                    }
                                }
                            }
                        }
                    }
                }

                // La dictée en cours : ce qui est compris, à mesure.
                Text {
                    visible: ClaudeChat.dictating
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    text: Pilot.voicePhase === "transcribing" ? I18n.tr("claude.chat.transcribing")
                        : Pilot.voiceText !== "" ? Pilot.voiceText
                        : I18n.tr(ClaudeChat.dictateHeld ? "claude.chat.dictatingHold" : "claude.chat.dictating")
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.italic: true
                    color: Theme.accentColor
                }

                // Le texte : de une à sept lignes, puis il défile.
                Flickable {
                    id: inputFlick
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    Layout.topMargin: 2
                    Layout.preferredHeight: Math.min(140, Math.max(input.font.pixelSize * 1.5, input.contentHeight))
                    contentHeight: input.contentHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    TextEdit {
                        id: input
                        width: inputFlick.width
                        wrapMode: TextEdit.Wrap
                        font.family: "Inter"
                        font.pixelSize: 13
                        color: Theme.textPrimary
                        selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                        // Gardé dans ClaudeChat à chaque frappe : rien ne se perd
                        // en changeant d'onglet ou de session.
                        text: ClaudeChat.draft
                        onTextChanged: ClaudeChat.setDraft(input.text)
                        onCursorRectangleChanged: {
                            if (cursorRectangle.y + cursorRectangle.height > inputFlick.contentY + inputFlick.height)
                                inputFlick.contentY = cursorRectangle.y + cursorRectangle.height - inputFlick.height;
                            else if (cursorRectangle.y < inputFlick.contentY)
                                inputFlick.contentY = cursorRectangle.y;
                        }
                        // Espace tenu : on dicte tant qu'il l'est. L'espace de
                        // la frappe s'écrit tout de suite, et s'en va quand la
                        // dictée commence ; une autre touche l'annule.
                        property bool spaceHeld: false
                        Timer {
                            id: spaceHold
                            interval: 350
                            onTriggered: {
                                ClaudeChat.dictateHold();
                                input.spaceHeld = ClaudeChat.dictateHeld;
                                var at = input.cursorPosition;
                                if (input.spaceHeld && at > 0 && input.getText(at - 1, at) === " ")
                                    input.remove(at - 1, at);
                            }
                        }
                        function spaceUp() {
                            spaceHold.stop();
                            if (input.spaceHeld)
                                ClaudeChat.dictateRelease();
                            input.spaceHeld = false;
                        }
                        onActiveFocusChanged: if (!activeFocus) input.spaceUp()
                        Component.onDestruction: if (input.spaceHeld) ClaudeChat.dictateRelease()
                        Keys.onReleased: (event) => {
                            if (event.key === Qt.Key_Space && !event.isAutoRepeat)
                                input.spaceUp();
                        }
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Space && (event.isAutoRepeat || input.spaceHeld)) {
                                // Tenu, il se répète : une seule frappe compte.
                                event.accepted = true;
                                return;
                            }
                            if (event.key === Qt.Key_Space && event.modifiers === Qt.NoModifier
                                    && input.selectedText === "")
                                spaceHold.restart();
                            else
                                spaceHold.stop();
                            // Entrée tenue n'envoie qu'une fois.
                            if (event.isAutoRepeat && !(event.modifiers & Qt.ShiftModifier)
                                    && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                                event.accepted = true;
                                return;
                            }
                            if (root.slashOpen) {
                                var n = slashView.count;
                                if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                                    var d = event.key === Qt.Key_Down ? 1 : n - 1;
                                    slashView.currentIndex = (slashView.currentIndex + d) % n;
                                    event.accepted = true;
                                    return;
                                }
                                var chosen = root.slashList[slashView.currentIndex];
                                if (event.key === Qt.Key_Tab && chosen) {
                                    root.setInput("/" + chosen.name + " ");
                                    event.accepted = true;
                                    return;
                                }
                                if (event.key === Qt.Key_Escape) {
                                    root.slashClosed = ClaudeChat.draft;
                                    event.accepted = true;
                                    return;
                                }
                                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                        && !(event.modifiers & Qt.ShiftModifier) && chosen) {
                                    event.accepted = true;
                                    // Tapée en entier : on la lance telle quelle.
                                    if ([chosen.name].concat(chosen.aliases || []).indexOf(root.slashWord) >= 0)
                                        root.submit();
                                    else
                                        root.pickSlash(chosen);
                                    return;
                                }
                            }
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                    && !(event.modifiers & Qt.ShiftModifier)) {
                                event.accepted = true;
                                root.submit();
                            } else if (event.key === Qt.Key_Escape && root.st.busy) {
                                event.accepted = true;
                                ClaudeChat.interrupt();
                            }
                        }

                        Text {
                            visible: input.text.length === 0
                            text: ClaudeChat.isNew ? I18n.tr("claude.chat.placeholderNew")
                                : root.st.driven ? I18n.tr("claude.chat.placeholder")
                                : I18n.tr("claude.chat.placeholderResume")
                            font: input.font
                            color: Theme.textDim
                        }
                    }
                }

                // Les outils.
                RowLayout {
                    id: toolsRow
                    Layout.fillWidth: true
                    spacing: 2

                    // Joindre un fichier ou une capture.
                    Rectangle {
                        implicitWidth: 30
                        implicitHeight: 30
                        radius: 15
                        color: root.menu === "attach" ? Theme.selectedFill : attachMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        Text {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -1
                            text: "+"
                            font.family: "Inter"
                            font.pixelSize: 19
                            font.weight: Font.Light
                            color: root.menu === "attach" ? Theme.accentColor : Theme.textSecondary
                        }
                        MouseArea {
                            id: attachMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.menu = root.menu === "attach" ? "" : "attach"
                        }
                    }

                    // Le modèle, l'effort, le mode : chacun ouvre son menu.
                    Repeater {
                        model: [
                            { menu: "model", text: ClaudeChat.modelLabel(ClaudeChat.modelShown) || I18n.tr("claude.chat.modelDefault"), strong: true },
                            { menu: "effort", text: root.effortNames[ClaudeChat.effortShown] || I18n.tr("claude.chat.effortDefault"), strong: false },
                            { menu: "mode", text: root.modeLabel(ClaudeChat.modeShown), strong: false }
                        ]
                        Rectangle {
                            id: setting
                            required property var modelData
                            readonly property bool open: root.menu === setting.modelData.menu
                            Layout.maximumWidth: 120
                            implicitWidth: settingRow.implicitWidth + 16
                            implicitHeight: 28
                            radius: 14
                            color: setting.open ? Theme.selectedFill : settingMa.containsMouse ? Theme.hoverOverlay : "transparent"
                            Row {
                                id: settingRow
                                anchors.centerIn: parent
                                width: Math.min(implicitWidth, setting.width - 16)
                                spacing: 3
                                Text {
                                    width: Math.min(implicitWidth, 120 - 16 - 12)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: setting.modelData.text
                                    elide: Text.ElideRight
                                    font.family: "Inter"
                                    font.pixelSize: 12
                                    font.weight: setting.modelData.strong ? Font.DemiBold : Font.Medium
                                    color: setting.open ? Theme.accentColor
                                         : setting.modelData.strong ? Theme.textPrimary : Theme.textSecondary
                                }
                                NixIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconSize: 9
                                    source: "../assets/icons/chevron-down.svg"
                                    color: Theme.textDim
                                }
                            }
                            MouseArea {
                                id: settingMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.menu = setting.open ? "" : setting.modelData.menu
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // L'anneau du contexte : la part de la fenêtre déjà prise.
                    Item {
                        implicitWidth: 30
                        implicitHeight: 30
                        Rectangle {
                            anchors.fill: parent
                            radius: 15
                            color: root.menu === "context" ? Theme.selectedFill : ringMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        }
                        Canvas {
                            id: ring
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            property real fill: root.ctxFill
                            property color track: Qt.alpha(Theme.textPrimary, 0.15)
                            property color arc: root.ctxFill > 0.8 ? Theme.colorWarning : Theme.accentColor
                            onFillChanged: requestPaint()
                            onArcChanged: requestPaint()
                            onTrackChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                ctx.lineWidth = 2.2;
                                ctx.strokeStyle = ring.track;
                                ctx.beginPath();
                                ctx.arc(8, 8, 6, 0, 2 * Math.PI);
                                ctx.stroke();
                                if (ring.fill > 0) {
                                    ctx.strokeStyle = ring.arc;
                                    ctx.lineCap = "round";
                                    ctx.beginPath();
                                    ctx.arc(8, 8, 6, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.max(0.03, ring.fill));
                                    ctx.stroke();
                                }
                            }
                        }
                        MouseArea {
                            id: ringMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.menu = root.menu === "context" ? "" : "context";
                                if (root.menu === "context")
                                    ClaudeChat.fetchUsage();
                            }
                        }
                        // Au survol : le pourcentage.
                        Rectangle {
                            visible: ringMa.containsMouse && root.menu !== "context"
                            anchors.bottom: parent.top
                            anchors.right: parent.right
                            anchors.bottomMargin: 4
                            width: ringTip.implicitWidth + 14
                            height: 22
                            radius: 6
                            color: Theme.bgDeep
                            border.width: 1
                            border.color: Theme.dividerColor
                            Text {
                                id: ringTip
                                anchors.centerIn: parent
                                text: I18n.tr("claude.chat.contextTip", { pct: Math.round(root.ctxFill * 100) })
                                font.family: "Inter"
                                font.pixelSize: 11
                                color: Theme.textPrimary
                            }
                        }
                    }

                    // Dicter ; un second clic finit. Espace tenu fait de même.
                    Rectangle {
                        id: micBtn
                        implicitWidth: 30
                        implicitHeight: 30
                        radius: 15
                        color: ClaudeChat.dictating ? Qt.alpha(Theme.accentColor, 0.2 + 0.5 * Math.min(1, Pilot.voiceLevel * 1.5))
                             : micMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        NixIcon {
                            anchors.centerIn: parent
                            iconSize: 15
                            source: "../assets/icons/mic.svg"
                            color: ClaudeChat.dictating ? Theme.accentColor
                                 : Pilot.voicePhase !== "idle" ? Theme.textDim : Theme.textSecondary
                        }
                        MouseArea {
                            id: micMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ClaudeChat.dictate()
                        }
                    }

                    // Envoyer, ou arrêter le tour en cours.
                    Rectangle {
                        id: sendBtn
                        Layout.leftMargin: 2
                        implicitWidth: 30
                        implicitHeight: 30
                        radius: 15
                        readonly property bool stop: root.st.busy
                        color: sendBtn.stop ? Qt.alpha(Theme.colorDanger, sendMa.containsMouse ? 0.3 : 0.18)
                             : root.canSend ? (sendMa.containsMouse ? Qt.lighter(Theme.accentColor, 1.1) : Theme.accentColor)
                             : Qt.alpha(Theme.textPrimary, 0.08)
                        Behavior on color { ColorAnimation { duration: 140 } }
                        NixIcon {
                            anchors.centerIn: parent
                            iconSize: 14
                            source: sendBtn.stop ? "../assets/icons/stop.svg" : "../assets/icons/send.svg"
                            color: sendBtn.stop ? Theme.colorDanger
                                 : root.canSend ? Theme.selectedTextColor : Theme.textDim
                        }
                        MouseArea {
                            id: sendMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: root.canSend || sendBtn.stop ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: sendBtn.stop ? ClaudeChat.interrupt() : root.submit()
                        }
                    }
                }
            }
        }
    }

    // ── Les commandes « / », au-dessus du champ ─────────────────────
    Rectangle {
        visible: root.slashOpen
        z: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: promptCard.height + 8
        height: Math.min(slashView.contentHeight + 12, 264, root.height * 0.5)
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: Theme.dividerColor

        ListView {
            id: slashView
            anchors.fill: parent
            anchors.margins: 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.slashOpen ? root.slashList : []
            // Le texte change : la première est la meilleure.
            onModelChanged: currentIndex = 0
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: Rectangle {
                id: slashRow
                required property var modelData
                required property int index
                width: slashView.width
                height: 42
                radius: Theme.radiusSmall
                color: slashRow.ListView.isCurrentItem ? Theme.selectedFill
                     : slashMa.containsMouse ? Theme.hoverOverlay : "transparent"
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 2
                    Row {
                        width: parent.width
                        spacing: 8
                        Text {
                            id: slashName
                            text: "/" + slashRow.modelData.name
                            font.family: root.mono
                            font.pixelSize: 12
                            color: Theme.textPrimary
                        }
                        Text {
                            width: Math.max(0, parent.width - slashName.width - 8)
                            text: slashRow.modelData.argumentHint || ""
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.family: root.mono
                            font.pixelSize: 11
                            color: Theme.textDim
                        }
                    }
                    Text {
                        width: parent.width
                        text: (slashRow.modelData.description || "").replace(/\s+/g, " ")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textDim
                    }
                }
                MouseArea {
                    id: slashMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.pickSlash(slashRow.modelData)
                }
            }
        }
    }

    // ── Les menus de la ligne sous le champ ──────────────────────────
    // Un clic à côté les ferme.
    MouseArea {
        anchors.fill: parent
        visible: root.menu !== ""
        z: 9
        onClicked: root.menu = ""
    }

    // ── Le contexte, le forfait et le coût (l'anneau) ────────────────
    //   CONTEXTE                          33 %
    //   ━━━━━━━━━━──────────────  330 k / 1 M · Opus 5.5
    //   Messages 290 k · Outils système 5 k · …
    //   FORFAIT PRO
    //   Session (5 h)  ━━━━━━━━━━━━━━━━──  84 %   dans 1 h 20
    //   Semaine        ━━━━━━━──────────  41 %   ven. 28, 20:00
    //   COÛT DE LA SESSION                6,72 $
    //   Opus 5.5 6,70 $ · Haiku 5.5 0,02 $        +1 356 −679
    Rectangle {
        id: contextBox
        visible: root.menu === "context"
        z: 10
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: promptCard.height + 8
        width: Math.min(parent.width, 340)
        height: Math.min(ctxBoxCol.implicitHeight + 24, root.height * 0.8)
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: Theme.dividerColor

        readonly property var ctx: root.sum.context
        readonly property var categories: ((root.st.context || {}).categories || [])
            .filter((c) => c.tokens > 0 && c.kind !== "free" && c.id !== "free_space" && c.id !== "autocompact_buffer")
            .sort((a, b) => b.tokens - a.tokens)
        readonly property var limits: {
            var rl = ClaudeChat.usage ? (ClaudeChat.usage.rate_limits || {}) : {};
            var names = {
                five_hour: I18n.tr("claude.usage.fiveHour"), seven_day: I18n.tr("claude.usage.sevenDay"),
                seven_day_opus: I18n.tr("claude.usage.sevenDayOpus"), seven_day_sonnet: I18n.tr("claude.usage.sevenDaySonnet")
            };
            return Object.keys(names).filter((k) => rl[k] && rl[k].utilization !== null && rl[k].utilization !== undefined)
                .map((k) => ({ name: names[k], pct: rl[k].utilization, resets: rl[k].resets_at || "" }));
        }
        // Le coût : celui que Claude Code a gardé, ou celui du lancement en
        // cours s'il est plus récent.
        readonly property real cost: Math.max(contextBox.ctx.cost || 0, root.st.cost || 0)

        function tokens(n) {
            if (n >= 1000000)
                return (n / 1000000).toLocaleString(I18n.locale, "f", 2) + " M";
            if (n >= 1000)
                return Math.round(n / 1000) + " k";
            return String(n);
        }

        function dollars(x) {
            return x.toLocaleString(I18n.locale, "f", 2) + " $";
        }

        // « dans 1 h 20 », ou le jour et l'heure au-delà d'un jour.
        function resets(iso) {
            if (!iso)
                return "";
            var d = new Date(iso);
            var s = (d.getTime() - Date.now()) / 1000;
            if (s <= 0)
                return "";
            if (s < 86400) {
                var h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60);
                return I18n.tr("claude.usage.resetsIn", { time: h > 0 ? h + " h " + (m < 10 ? "0" : "") + m : m + " min" });
            }
            return I18n.tr("claude.usage.resetsOn", { time: I18n.locale.toString(d, "ddd d, HH:mm") });
        }

        component Bar: Rectangle {
            id: bar
            property real fill: 0
            implicitHeight: 6
            radius: 3
            color: Qt.alpha(Theme.textPrimary, 0.08)
            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, bar.fill))
                height: parent.height
                radius: 3
                color: bar.fill > 0.9 ? Theme.colorDanger : bar.fill > 0.75 ? Theme.colorWarning : Theme.accentColor
            }
        }

        component Title: RowLayout {
            id: title
            property string text
            property string value: ""
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: title.text
                font.family: "Inter"
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
                color: Theme.textDim
            }
            Text {
                text: title.value
                font.family: "Inter"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: Theme.textPrimary
            }
        }

        Flickable {
            anchors.fill: parent
            anchors.margins: 12
            contentHeight: ctxBoxCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: ctxBoxCol
                width: parent.width
                spacing: 7

                // Le contexte.
                Title {
                    text: I18n.tr("claude.usage.context")
                    value: Math.round(root.ctxFill * 100) + " %"
                }
                Bar {
                    Layout.fillWidth: true
                    fill: root.ctxFill
                }
                Text {
                    Layout.fillWidth: true
                    text: contextBox.tokens(contextBox.ctx.tokens) + " / " + contextBox.tokens(root.ctxWindow)
                          + (ClaudeChat.modelShown !== "" ? " · " + ClaudeChat.modelLabel(ClaudeChat.modelShown) : "")
                          + (contextBox.ctx.compactions > 0 ? " · " + I18n.tr("claude.pane.compactions", { n: contextBox.ctx.compactions }) : "")
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textSecondary
                }
                // Ce qui le remplit, quand la session est pilotée.
                Repeater {
                    model: contextBox.categories.slice(0, 7)
                    RowLayout {
                        id: cat
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: cat.modelData.name
                            elide: Text.ElideRight
                            font.family: "Inter"
                            font.pixelSize: 11
                            color: Theme.textSecondary
                        }
                        Text {
                            text: contextBox.tokens(cat.modelData.tokens)
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                            color: Theme.textDim
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    implicitHeight: 1
                    color: Theme.dividerColor
                }

                // Le forfait.
                Title {
                    text: ClaudeChat.usage && ClaudeChat.usage.subscription_type
                          ? I18n.tr("claude.usage.planOf", { plan: String(ClaudeChat.usage.subscription_type).toUpperCase() })
                          : I18n.tr("claude.usage.plan")
                }
                Text {
                    visible: contextBox.limits.length === 0
                    text: ClaudeChat.usageLoading ? I18n.tr("claude.usage.loading") : I18n.tr("claude.usage.none")
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textDim
                }
                Repeater {
                    model: contextBox.limits
                    ColumnLayout {
                        id: limit
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 3
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: limit.modelData.name
                                font.family: "Inter"
                                font.pixelSize: 12
                                color: Theme.textPrimary
                            }
                            Text {
                                text: Math.round(limit.modelData.pct) + " %"
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                font.features: { "tnum": 1 }
                                color: limit.modelData.pct > 90 ? Theme.colorDanger
                                     : limit.modelData.pct > 75 ? Theme.colorWarning : Theme.textPrimary
                            }
                        }
                        Bar {
                            Layout.fillWidth: true
                            fill: limit.modelData.pct / 100
                        }
                        Text {
                            visible: text !== ""
                            text: contextBox.resets(limit.modelData.resets)
                            font.family: "Inter"
                            font.pixelSize: 10
                            color: Theme.textDim
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    implicitHeight: 1
                    color: Theme.dividerColor
                }

                // Le coût de la session.
                Title {
                    text: I18n.tr("claude.usage.cost")
                    value: contextBox.dollars(contextBox.cost)
                }
                Repeater {
                    model: (contextBox.ctx.cost_models || []).filter((m) => m.cost >= 0.005)
                    RowLayout {
                        id: costRow
                        required property var modelData
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: ClaudeChat.modelLabel(costRow.modelData.model)
                            font.family: "Inter"
                            font.pixelSize: 11
                            color: Theme.textSecondary
                        }
                        Text {
                            text: contextBox.dollars(costRow.modelData.cost)
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                            color: Theme.textDim
                        }
                    }
                }
                RowLayout {
                    visible: (contextBox.ctx.lines_added || 0) + (contextBox.ctx.lines_removed || 0) > 0
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: I18n.tr("claude.usage.lines")
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textSecondary
                    }
                    Text {
                        text: "+" + (contextBox.ctx.lines_added || 0)
                        font.family: root.mono
                        font.pixelSize: 11
                        color: Theme.colorSuccess
                    }
                    Text {
                        text: "−" + (contextBox.ctx.lines_removed || 0)
                        font.family: root.mono
                        font.pixelSize: 11
                        color: Theme.colorDanger
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: I18n.tr("claude.usage.costNote")
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
            }
        }
    }

    Rectangle {
        id: menuBox
        visible: root.menu !== "" && root.menu !== "context"
        z: 10
        x: root.menu === "attach" ? 0 : parent.width - width
        anchors.bottom: parent.bottom
        anchors.bottomMargin: promptCard.height + 8
        width: Math.min(parent.width, 300)
        height: Math.min(menuList.implicitHeight + 12, root.height * 0.7)
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: Theme.dividerColor

        // Ce que le menu ouvert propose : [{ id, label, sub, current }].
        readonly property var options: {
            if (root.menu === "model") {
                var cur = ClaudeChat.modelEntry(ClaudeChat.modelShown);
                return root.modelChoices.map((m) => ({
                    id: m.value, label: m.displayName, sub: m.description || "",
                    current: cur ? cur.value === m.value : ClaudeChat.modelShown === m.value
                }));
            }
            if (root.menu === "effort")
                return root.efforts.map((e) => ({ id: e, label: root.effortNames[e] || e, sub: "", current: ClaudeChat.effortShown === e }));
            if (root.menu === "attach")
                return [
                    { id: "file", label: I18n.tr("claude.chat.attachFile"), sub: "", current: false },
                    { id: "area", label: I18n.tr("claude.chat.attachRegion"), sub: "", current: false },
                    { id: "output", label: I18n.tr("claude.chat.attachScreen"), sub: "", current: false }
                ];
            if (root.menu === "mode")
                return root.modes.map((m) => ({ id: m.id, label: m.label, sub: m.sub, current: ClaudeChat.modeShown === m.id }));
            return [];
        }

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            contentHeight: menuList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: menuList
                width: parent.width
                spacing: 1
                Text {
                    width: parent.width
                    leftPadding: 8
                    topPadding: 4
                    bottomPadding: 4
                    text: root.menu === "attach" ? I18n.tr("claude.chat.menuAttach")
                        : root.menu === "model" ? I18n.tr("claude.chat.menuModel")
                        : root.menu === "effort" ? I18n.tr("claude.chat.menuEffort") : I18n.tr("claude.chat.menuMode")
                    font.family: "Inter"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.8
                    font.capitalization: Font.AllUppercase
                    color: Theme.textDim
                }
                Repeater {
                    model: menuBox.options
                    Rectangle {
                        id: opt
                        required property var modelData
                        width: menuList.width
                        height: optCol.implicitHeight + 12
                        radius: Theme.radiusSmall
                        color: optMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        Column {
                            id: optCol
                            x: 8
                            y: 6
                            width: parent.width - 36
                            Text {
                                width: parent.width
                                text: opt.modelData.label
                                elide: Text.ElideRight
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: opt.modelData.current ? Font.DemiBold : Font.Normal
                                color: Theme.textPrimary
                            }
                            Text {
                                width: parent.width
                                visible: opt.modelData.sub !== ""
                                text: opt.modelData.sub
                                wrapMode: Text.Wrap
                                font.family: "Inter"
                                font.pixelSize: 10
                                color: Theme.textDim
                            }
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            visible: opt.modelData.current
                            text: "✓"
                            font.pixelSize: 12
                            color: Theme.accentColor
                        }
                        MouseArea {
                            id: optMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.menu === "attach") {
                                    var kind = opt.modelData.id;
                                    root.menu = "";
                                    if (kind === "file")
                                        ClaudeChat.pickFiles();
                                    else
                                        ClaudeChat.capture(kind);
                                    return;
                                }
                                if (root.menu === "model")
                                    ClaudeChat.setModel(opt.modelData.id);
                                else if (root.menu === "effort")
                                    ClaudeChat.setEffort(opt.modelData.id);
                                else
                                    ClaudeChat.setMode(opt.modelData.id);
                                root.menu = "";
                            }
                        }
                    }
                }
            }
        }
    }

    function submit() {
        if (!root.canSend || ClaudeChat.sending)
            return;
        if (root.runOwn(ClaudeChat.draft))
            return;
        ClaudeChat.send(ClaudeChat.draft);
        list.stick = true;
    }

    // À l'ouverture, on peut écrire tout de suite.
    onVisibleChanged: if (visible && !root.held) Qt.callLater(() => input.forceActiveFocus())
}
