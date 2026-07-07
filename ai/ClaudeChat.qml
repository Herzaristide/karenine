import QtQuick
import QtQml
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io
import "../services"

pragma ComponentBehavior: Bound

// ClaudeChat: chat panel backed by the Claude Code CLI running in headless
// stream-json mode. Unlike OllamaChat (which talks to Ollama over HTTP and
// implements its own tools in OllamaTools.qml), Claude Code is itself an
// agent — it owns and executes its tools (Bash, file edits, web, …). We just
// stream user turns in and render assistant text / tool actions out.
//
// Wire protocol (one JSON object per line, both directions):
//   stdin  <-  {"type":"user","message":{"role":"user","content":"…"}}
//   stdout ->  {"type":"system","subtype":"init", session_id, …}
//              {"type":"stream_event","event":{…}}   (token deltas)
//              {"type":"assistant","message":{…}}     (full turn)
//              {"type":"result","subtype":"success", is_error, …}
Item {
    id: root

    // ── Permissions ──────────────────────────────────────────────────────────
    // The panel has no terminal to answer interactive permission prompts, so
    // anything other than "bypassPermissions" will stall the first time Claude
    // wants to run a tool that isn't pre-approved. Dial this back to
    // "acceptEdits" or "plan" (read-only) if you want a safer, less autonomous
    // assistant — but expect it to hang on un-approved tools.
    property string permissionMode: "bypassPermissions"

    // Optional model override (e.g. "claude-opus-4-8"). Empty = CLI default.
    property string claudeModel: ""

    property bool started: false        // true once the process is spawned
    property bool ready: false          // true once the CLI has emitted init
    property bool isStreaming: false    // a turn is in flight
    property string sessionId: ""

    // Index of the assistant text bubble currently being filled, or -1 when the
    // next text chunk should open a fresh bubble (e.g. after a tool action).
    property int currentAssistantIdx: -1

    // The single message queued before the process has spawned. isStreaming
    // guarantees at most one turn is ever in flight, so a string is enough
    // (and avoids QML's flaky in-place mutation of `var` arrays).
    property string pendingText: ""

    ListModel { id: messages }

    Process {
        id: copyProcess
        command: ["wl-copy"]
        stdinEnabled: true
        onExited: running = false
    }

    // ── Claude Code CLI process ──────────────────────────────────────────────
    Process {
        id: claudeProcess
        running: false
        stdinEnabled: true

        command: ["bash", "-c", root.buildClaudeCommand()]

        stdout: SplitParser {
            onRead: (line) => root.handleEvent(line)
        }
        stderr: SplitParser {
            onRead: (data) => console.warn("claude:", data)
        }

        // claude does not print anything (not even the init event) until it has
        // received its first stdin message, so we flush queued input as soon as
        // the process is spawned rather than waiting for the init event.
        onStarted: {
            root.started = true;
            root.flushPending();
        }

        onExited: (code, status) => {
            root.started = false;
            root.ready = false;
            root.isStreaming = false;
            root.sessionId = "";
            root.currentAssistantIdx = -1;
            if (code !== 0)
                messages.append({ role: "assistant",
                    content: "[Claude Code s'est arrêté (code " + code + "). Le prochain message relancera une session.]",
                    msgType: "text" });
        }
    }

    function buildClaudeCommand() {
        var args = "claude -p"
            + " --input-format stream-json"
            + " --output-format stream-json"
            + " --include-partial-messages"
            + " --verbose"
            + " --permission-mode " + permissionMode;
        if (claudeModel !== "")
            args += " --model " + claudeModel;
        // Run from the user's home so file tools resolve sensibly.
        return "cd \"$HOME\" && exec " + args;
    }

    function ensureStarted() {
        if (!claudeProcess.running)
            claudeProcess.running = true;
    }

    function writeUserMessage(text) {
        var payload = JSON.stringify({
            type: "user",
            message: { role: "user", content: text }
        });
        claudeProcess.write(payload + "\n");
    }

    function flushPending() {
        if (pendingText === "") return;
        writeUserMessage(pendingText);
        pendingText = "";
    }

    // ── Outgoing ─────────────────────────────────────────────────────────────
    function sendMessage() {
        var text = inputField.text.trim();
        if (text === "" || root.isStreaming) return;

        inputField.text = "";
        messages.append({ role: "user", content: text, msgType: "text" });

        // Pre-create the assistant bubble so the typing cursor shows immediately.
        messages.append({ role: "assistant", content: "", msgType: "text" });
        root.currentAssistantIdx = messages.count - 1;
        root.isStreaming = true;

        pendingText = text;
        ensureStarted();
        if (root.started)
            flushPending();
    }

    // ── Incoming event parsing ───────────────────────────────────────────────
    function handleEvent(line) {
        line = line.trim();
        if (line === "") return;

        var obj;
        try { obj = JSON.parse(line); } catch (e) { return; }

        switch (obj.type) {
            case "system":
                if (obj.subtype === "init") {
                    root.sessionId = obj.session_id || "";
                    root.ready = true;
                }
                break;

            case "stream_event":
                handleStreamEvent(obj.event);
                break;

            case "result":
                root.isStreaming = false;
                // Drop a trailing empty assistant bubble if the turn produced
                // nothing renderable (e.g. tool-only turn).
                if (root.currentAssistantIdx >= 0
                    && root.currentAssistantIdx < messages.count
                    && messages.get(root.currentAssistantIdx).content === "") {
                    if (obj.is_error) {
                        messages.setProperty(root.currentAssistantIdx, "content",
                            "[Erreur : " + (obj.subtype || "échec") + "]");
                    } else if (typeof obj.result === "string" && obj.result !== "") {
                        messages.setProperty(root.currentAssistantIdx, "content", obj.result);
                    } else {
                        messages.remove(root.currentAssistantIdx);
                    }
                }
                root.currentAssistantIdx = -1;
                break;
        }
    }

    function handleStreamEvent(event) {
        if (!event) return;

        switch (event.type) {
            case "content_block_start": {
                var block = event.content_block || {};
                if (block.type === "tool_use") {
                    // Show the tool action as its own bubble, then force the
                    // next text chunk into a fresh assistant bubble.
                    var label = "⚙ " + (block.name || "outil");
                    if (root.currentAssistantIdx >= 0
                        && messages.get(root.currentAssistantIdx).content === "") {
                        messages.setProperty(root.currentAssistantIdx, "content", label);
                        messages.setProperty(root.currentAssistantIdx, "msgType", "action");
                    } else {
                        messages.append({ role: "assistant", content: label, msgType: "action" });
                    }
                    root.currentAssistantIdx = -1;
                }
                break;
            }

            case "content_block_delta": {
                var delta = event.delta || {};
                if (delta.type === "text_delta" && typeof delta.text === "string") {
                    if (root.currentAssistantIdx < 0) {
                        messages.append({ role: "assistant", content: "", msgType: "text" });
                        root.currentAssistantIdx = messages.count - 1;
                    }
                    var cur = messages.get(root.currentAssistantIdx).content;
                    messages.setProperty(root.currentAssistantIdx, "content", cur + delta.text);
                }
                break;
            }
        }
    }

    function clearChat() {
        // Restart the session so Claude's own context resets too.
        claudeProcess.running = false;
        messages.clear();
        root.ready = false;
        root.isStreaming = false;
        root.sessionId = "";
        root.currentAssistantIdx = -1;
        root.started = false;
        root.pendingText = "";
    }

    // ── UI ───────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // Message list
        ListView {
            id: msgList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: messages.count > 0
            clip: true
            spacing: 6
            model: messages

            property bool userScrolledUp: false

            function scrollToEndIfNeeded() {
                if (!userScrolledUp) positionViewAtEnd();
            }

            onCountChanged: { userScrolledUp = false; Qt.callLater(positionViewAtEnd); }
            onContentHeightChanged: Qt.callLater(scrollToEndIfNeeded)
            onDragStarted: userScrolledUp = true
            onFlickStarted: userScrolledUp = true
            onMovementStarted: userScrolledUp = true
            onAtYEndChanged: if (atYEnd) userScrolledUp = false

            delegate: Item {
                id: msgItem
                required property string role
                required property string content
                required property string msgType

                width: msgList.width
                height: msgRow.height + 4

                Row {
                    id: msgRow
                    width: parent.width

                    Text {
                        id: prefixText
                        text: msgItem.role === "user" ? "> " : (msgItem.msgType === "action" ? "$ " : "  ")
                        color: msgItem.role === "user" ? Theme.accentColor : (msgItem.msgType === "action" ? Theme.colorAmber : Theme.textInactive)
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                    }

                    TextEdit {
                        id: msgBodyText
                        width: msgRow.width - prefixText.implicitWidth - (copyBtn.visible ? copyBtn.implicitWidth + 6 : 0)
                        readOnly: true
                        selectByMouse: true
                        text: (msgItem.role === "assistant" && msgItem.content === "" && root.isStreaming)
                              ? "▋" : msgItem.content
                        color: {
                            if (msgItem.role === "user") return Theme.accentColor;
                            if (msgItem.msgType === "action") return Theme.colorAmber;
                            return Theme.textBody;
                        }
                        selectionColor: Theme.accentColor
                        selectedTextColor: Theme.selectedTextColor
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        wrapMode: TextEdit.Wrap
                    }

                    Text {
                        id: copyBtn
                        visible: msgItem.role === "assistant" && msgItem.msgType === "text" && msgItem.content !== "" && !root.isStreaming
                        text: copyTimer.running ? "[copied]" : "[copy]"
                        color: copyMa.containsMouse ? Theme.accentColor : Theme.textSubtle
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        leftPadding: 6

                        MouseArea {
                            id: copyMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                copyProcess.running = false;
                                copyProcess.stdinEnabled = true;
                                copyProcess.running = true;
                                copyProcess.write(msgItem.content);
                                copyProcess.stdinEnabled = false;
                                copyTimer.restart();
                            }
                        }
                        Timer { id: copyTimer; interval: 2000 }
                    }
                }
            }
        }

        // Spacer when empty
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: messages.count === 0
        }

        // Input bar
        RowLayout {
            Layout.fillWidth: true
            Layout.minimumHeight: 28
            spacing: 0
            clip: true

            Text {
                text: "> "
                color: root.isStreaming ? Theme.textInactive : Theme.accentColor
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                Layout.alignment: Qt.AlignTop
                topPadding: 4
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.minimumHeight: 28
                Layout.maximumHeight: 120
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: ScrollBar.AsNeeded
                clip: true

                TextArea {
                    id: inputField
                    wrapMode: TextArea.Wrap
                    placeholderText: root.isStreaming ? "…" : "message à Claude Code"
                    placeholderTextColor: Theme.placeholderColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.accentColor
                    background: Item {}
                    enabled: !root.isStreaming
                    topPadding: 4
                    bottomPadding: 4
                    leftPadding: 0
                    rightPadding: 0
                    Keys.onReturnPressed: (event) => {
                        if (event.modifiers & Qt.ShiftModifier)
                            insert(cursorPosition, "\n");
                        else
                            root.sendMessage();
                    }
                }
            }
        }

        // Bottom controls
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                text: "// claude:" + root.permissionMode
                color: Theme.accentColor
                opacity: 0.4
                font.family: "JetBrains Mono"
                font.pixelSize: 10
            }

            Item { Layout.fillWidth: true }

            Text {
                text: root.ready ? "[session]" : "[idle]"
                color: root.ready ? Theme.accentColor : Theme.textInactive
                opacity: 0.7
                font.family: "JetBrains Mono"
                font.pixelSize: 10
            }

            Text {
                text: "[clear]"
                color: clearMa.containsMouse ? Theme.colorDanger : Theme.textInactive
                font.family: "JetBrains Mono"
                font.pixelSize: 10

                MouseArea {
                    id: clearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearChat()
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: messages.count === 0
        }
    }
}
