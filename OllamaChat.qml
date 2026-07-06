import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io
import Quickshell.Hyprland

Item {
    id: root

    property string modelName: "qwen3:latest"
    property bool modelReady: false
    property var availableModels: []
    property bool isStreaming: false
    property bool voiceEnabled: false
    property string voiceStatus: "OFF"
    // Live microphone RMS (0..1) emitted by mic-level.sh while voice is on.
    property real micLevel: 0.0
    // Rolling history of the last N levels, used to render the meter as a
    // little waveform instead of a single jumpy bar.
    property var micLevelHistory: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    // True when the assistant is actively doing something for the user
    // (transcribing the captured utterance, generating, or speaking the
    // reply). The input field is locked in this state so the user cannot
    // type over an in-flight voice turn.
    readonly property bool voiceBusy: voiceEnabled && (
        voiceStatus === "RECORDING" ||
        voiceStatus === "PROCESSING" ||
        voiceStatus === "SPEAKING"  ||
        voiceStatus === "DOWNLOADING_MODEL" ||
        voiceStatus === "DOWNLOADING_VOICE"
    )
    readonly property bool voiceListening: voiceEnabled && voiceStatus === "LISTENING"
    // Last line whisper-stream heard while waiting for the wake word.
    // Surfaced in the header so the user can tune the wake word without
    // opening a terminal.
    property string voiceDebug: ""

    property string systemPrompt: "Tu es un assistant IA intégré au bureau Linux (Hyprland/NixOS) de l'utilisateur. Tu peux exécuter des actions sur son système via les outils disponibles. Tu as aussi accès à des outils NixOS pour reconstruire le système, mettre à jour le flake, gérer les générations et le garbage collection. La configuration NixOS se trouve dans /etc/nixos. Tu peux démarrer et arrêter des enregistrements audio du microphone vers /records/ (start_recording / stop_recording). Tu peux ouvrir des URLs et faire des recherches web dans le navigateur par défaut (Zen) avec l'outil open_url : utilise-le quand l'utilisateur demande d'ouvrir un site, chercher une recette, regarder YouTube, trouver des informations en ligne, etc. Quand l'utilisateur te demande d'effectuer une action, utilise l'outil approprié. Réponds toujours en français."

    // Tool definitions and execution are in OllamaTools.qml
    OllamaTools {
        id: llmTools
        onToolResult: (toolName, assistantIdx, result) => handleToolResult(toolName, assistantIdx, result)
    }

    Component.onCompleted: checkAndPullModel()


    ListModel { id: messages }

    // Internal context for Ollama (includes tool role messages not shown in UI)
    property var conversationContext: []

    Process {
        id: copyProcess
        command: ["wl-copy"]
        stdinEnabled: true
        onExited: running = false
    }

    // ── Ollama model pull process ────────────────────────────────────────────
    Process {
        id: pullProcess
        property int pullMsgIdx: -1

        stdout: SplitParser {
            onRead: (data) => {
                if (pullProcess.pullMsgIdx >= 0)
                    messages.setProperty(pullProcess.pullMsgIdx, "content",
                        "\u2B07 T\u00E9l\u00E9chargement de " + root.modelName + "...\n" + data);
            }
        }
        stderr: SplitParser { onRead: (data) => {} }

        onExited: (code, status) => {
            if (code === 0) {
                root.modelReady = true;
                if (pullProcess.pullMsgIdx >= 0)
                    messages.setProperty(pullProcess.pullMsgIdx, "content",
                        "\u2705 " + root.modelName + " t\u00E9l\u00E9charg\u00E9, pr\u00EAt !");
            } else {
                if (pullProcess.pullMsgIdx >= 0)
                    messages.setProperty(pullProcess.pullMsgIdx, "content",
                        "\u26A0 \u00C9chec du t\u00E9l\u00E9chargement de " + root.modelName +
                        ". V\u00E9rifie qu'Ollama est bien d\u00E9marr\u00E9.");
            }
        }
    }

    function checkAndPullModel() {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "http://localhost:11434/api/tags");
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return;
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    var models = data.models || [];
                    var names = [];
                    for (var i = 0; i < models.length; i++)
                        names.push(models[i].name);
                    if (names.length > 0)
                        root.availableModels = names;
                    var found = false;
                    for (var i = 0; i < models.length; i++) {
                        if (models[i].name === root.modelName ||
                            models[i].name.split(":")[0] === root.modelName.split(":")[0]) {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        root.modelReady = true;
                    } else {
                        messages.append({ role: "assistant",
                            content: "\u2B07 Mod\u00E8le " + root.modelName + " non trouv\u00E9, t\u00E9l\u00E9chargement en cours...",
                            msgType: "text" });
                        pullProcess.pullMsgIdx = messages.count - 1;
                        pullProcess.command = ["ollama", "pull", root.modelName];
                        pullProcess.running = true;
                    }
                } catch (e) {
                    root.modelReady = true; // impossible de v\u00E9rifier, on tente quand m\u00EAme
                }
            } else {
                // Ollama injoignable — on laisse passer, l'erreur sera affich\u00E9e \u00E0 l'envoi
                root.modelReady = true;
            }
        };
        xhr.send();
    }

    // ── Voice assistant process ────────────────────────────────
    Process {
        id: voiceProcess
        command: ["bash", "-c", "exec $HOME/.config/quickshell/voice-assistant.sh"]
        running: root.voiceEnabled
        stdinEnabled: true

        stdout: SplitParser {
            onRead: (data) => {
                if (data.startsWith("STATUS:")) {
                    root.voiceStatus = data.substring(7);
                } else if (data.startsWith("TRANSCRIPT:")) {
                    var text = data.substring(11).trim();
                    if (text !== "") {
                        root.voiceSubmit(text);
                    }
                } else if (data.startsWith("DEBUG:")) {
                    // Whisper heard this while waiting for the wake word.
                    // Logged so you can tune WAKE_WORD_REGEX to your voice.
                    var dbg = data.substring(6).trim();
                    root.voiceDebug = dbg;
                    console.log("[wake-stream]", dbg);
                } else if (data.startsWith("ERROR:")) {
                    var errMsg = data.substring(6);
                    console.warn("Voice assistant error:", errMsg);
                    // Show error in chat so the user knows what went wrong
                    messages.append({ role: "assistant", content: "⚠️ Voix : " + errMsg, msgType: "text" });
                }
            }
        }
        stderr: SplitParser {
            onRead: (data) => { console.warn("voice-assistant:", data) }
        }

        onExited: (code, status) => {
            if (root.voiceEnabled) {
                root.voiceStatus = "ERROR";
                root.voiceEnabled = false;
            }
        }
    }

    // ── Microphone level meter ───────────────────────────────────
    // Runs only while the voice assistant is on. Streams RMS levels we use
    // to animate the meter so the user can SEE the mic is being captured.
    Process {
        id: micLevelProcess
        command: ["bash", "-c", "exec $HOME/.config/quickshell/mic-level.sh"]
        running: root.voiceEnabled

        stdout: SplitParser {
            onRead: (data) => {
                if (!data.startsWith("LEVEL:")) return;
                var v = parseFloat(data.substring(6));
                if (isNaN(v)) return;
                root.micLevel = v;
                var h = root.micLevelHistory.slice(1);
                h.push(v);
                root.micLevelHistory = h;
            }
        }
        stderr: SplitParser { onRead: (_) => { /* swallow */ } }

        onRunningChanged: if (!running) {
            root.micLevel = 0.0;
            root.micLevelHistory = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
        }
    }

    function speakText(text) {
        if (!root.voiceEnabled) return;
        // Send TTS request to voice assistant via stdin
        voiceProcess.write("SPEAK:" + text + "\n");
    }

    function voiceSubmit(text) {
        if (root.isStreaming) return;
        // Write transcript into the input field so the user sees it,
        // then re-use the normal sendMessage() path.
        inputField.text = text;
        root.pendingVoiceResponse = true;
        sendMessage();
    }

    property bool pendingVoiceResponse: false

    property bool ttsEnabled: false
    property var ttsPendingQueue: []

    // ── TTS process: piper → aplay, indépendant du mode voix ───────
    // Le texte est passé via la commande shell (pas via stdin) pour éviter
    // que closeStdin() bloque les appels suivants au redémarrage du process.
    Process {
        id: ttsProcess
        running: false
        onExited: {
            running = false;
            if (root.ttsPendingQueue.length > 0) {
                var nextText = root.ttsPendingQueue.shift();
                Qt.callLater(function() { root._ttsRun(nextText); });
            }
        }
    }

    function _ttsRun(text) {
        // Single-quote escaping : remplace ' par '\'' (safe pour tout texte arbitraire)
        var q = "'" + text.replace(/'/g, "'\\''") + "'";
        ttsProcess.command = [
            "bash", "-c",
            "printf '%s' " + q + " | piper -m \"$HOME/.local/share/piper/fr_FR-siwis-medium.onnx\" --length-scale 0.75 --output-raw 2>/dev/null | " +
            "aplay -r 22050 -f S16_LE -t raw -q 2>/dev/null"
        ];
        ttsProcess.running = true;
    }

    // Lit le texte d'une réponse IA via piper (nettoyage markdown basique).
    function speakResponse(text) {
        if (!root.ttsEnabled) return;
        var clean = text
            .replace(/\*{1,2}([^*]*)\*{1,2}/g, "$1")
            .replace(/`[^`]*`/g, "")
            .replace(/#{1,6}\s*/g, "")
            .replace(/\n+/g, " ")
            .trim();
        if (clean === "") return;
        if (ttsProcess.running)
            root.ttsPendingQueue.push(clean);
        else
            root._ttsRun(clean);
    }

    function sendMessage() {
        var text = inputField.text.trim();
        if (text === "" || root.isStreaming) return;
        if (!root.modelReady) {
            messages.append({ role: "assistant",
                content: "\u23F3 Le mod\u00E8le est encore en cours de t\u00E9l\u00E9chargement, patiente un instant...",
                msgType: "text" });
            return;
        }

        inputField.text = "";
        // Prefix voice-initiated messages with a mic icon
        var displayText = root.pendingVoiceResponse ? "\uD83C\uDF99 " + text : text;
        messages.append({ role: "user", content: displayText, msgType: "text" });

        // Add to internal context
        root.conversationContext.push({ role: "user", content: text });

        continueConversation();
    }

    function continueConversation() {
        messages.append({ role: "assistant", content: "", msgType: "text" });
        var assistantIdx = messages.count - 1;

        // Build full context with system prompt
        var ctx = [{ role: "system", content: root.systemPrompt }];
        for (var i = 0; i < root.conversationContext.length; i++)
            ctx.push(root.conversationContext[i]);

        root.isStreaming = true;
        var lastPos = 0;
        var gotChunk = false;
        var fullResponse = "";
        var pendingToolCalls = [];

        var xhr = new XMLHttpRequest();
        xhr.open("POST", "http://localhost:11434/api/chat");
        xhr.setRequestHeader("Content-Type", "application/json");

        xhr.onreadystatechange = function() {
            if (xhr.readyState === 3 || xhr.readyState === 4) {
                var chunk = xhr.responseText.slice(lastPos);
                lastPos = xhr.responseText.length;
                var lines = chunk.split("\n");
                for (var j = 0; j < lines.length; j++) {
                    var line = lines[j].trim();
                    if (line === "") continue;
                    try {
                        var obj = JSON.parse(line);
                        // Accumulate text content
                        if (obj.message && typeof obj.message.content === "string" && obj.message.content !== "") {
                            var cur = messages.get(assistantIdx).content;
                            messages.setProperty(assistantIdx, "content", cur + obj.message.content);
                            fullResponse += obj.message.content;
                            gotChunk = true;
                        }
                        // Accumulate tool calls from ANY chunk (they arrive in done:false chunks)
                        if (obj.message && obj.message.tool_calls && obj.message.tool_calls.length > 0) {
                            for (var t = 0; t < obj.message.tool_calls.length; t++)
                                pendingToolCalls.push(obj.message.tool_calls[t]);
                            gotChunk = true;
                        }
                        if (obj.error) {
                            messages.setProperty(assistantIdx, "content",
                                "[Erreur Ollama : " + obj.error + "]");
                            gotChunk = true;
                        }
                        // When stream is done, process accumulated tool calls
                        if (obj.done === true) {
                            root.isStreaming = false;

                            if (pendingToolCalls.length > 0) {
                                // Add assistant message with tool_calls to context
                                root.conversationContext.push({
                                    role: "assistant",
                                    content: fullResponse,
                                    tool_calls: pendingToolCalls
                                });

                                // Process the first tool call
                                var tc = pendingToolCalls[0];
                                var fn = tc["function"];
                                var toolName = fn.name;
                                var toolArgs = fn.arguments || {};

                                // Show action bubble
                                var actionText = "\u2699 " + llmTools.formatToolAction(toolName, toolArgs);
                                messages.setProperty(assistantIdx, "content", actionText);
                                messages.setProperty(assistantIdx, "msgType", "action");

                                llmTools.executeToolCall(toolName, toolArgs, assistantIdx);
                                return;
                            }

                            // Normal text response
                            root.conversationContext.push({ role: "assistant", content: fullResponse });
                            // TTS : mode global lit toutes les réponses ; mode voix lit les réponses initiées par micro
                            if (root.ttsEnabled && fullResponse !== "") {
                                root.speakResponse(fullResponse);
                            } else if (root.pendingVoiceResponse && fullResponse !== "") {
                                root.speakText(fullResponse);
                            }
                            root.pendingVoiceResponse = false;
                            return;
                        }
                    } catch (e) {}
                }
            }
            if (xhr.readyState === 4 && !gotChunk) {
                var networkErr = xhr.status === 0
                    ? "impossible de joindre Ollama sur localhost:11434"
                    : "réponse inattendue (HTTP " + xhr.status + ")";
                messages.setProperty(assistantIdx, "content",
                    "[Erreur : " + networkErr + "]");
                root.isStreaming = false;
            }
        };

        xhr.send(JSON.stringify({
            model: root.modelName,
            messages: ctx,
            tools: llmTools.toolDefinitions,
            stream: true
        }));
    }

    function handleToolResult(toolName, assistantIdx, result) {
        // Truncate very long results
        if (result.length > 2000)
            result = result.substring(0, 2000) + "\n... (tronqué)";

        // For screenshots, insert an image bubble in the chat
        if (toolName === "screenshot") {
            var screenshotPath = result.trim();
            if (screenshotPath !== "")
                messages.append({ role: "assistant", content: screenshotPath, msgType: "screenshot" });
        }

        // Add tool result to context
        root.conversationContext.push({ role: "tool", content: result });

        // Continue conversation so the AI can respond with the result
        continueConversation();
    }

    function clearChat() {
        messages.clear();
        root.conversationContext = [];
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // -- Voice status banner --
        // Prominent indicator that makes it obvious whether the mic is
        // listening, transcribing, generating or speaking. Shows a live
        // audio meter driven by mic-level.sh while we are capturing.
        Rectangle {
            visible: root.voiceEnabled
            Layout.fillWidth: true
            Layout.preferredHeight: voiceBanner.implicitHeight + 12
            radius: 6
            color: {
                switch (root.voiceStatus) {
                    case "LISTENING":  return Qt.rgba(Theme.colorSuccess.r, Theme.colorSuccess.g, Theme.colorSuccess.b, 0.10);
                    case "RECORDING":  return Qt.rgba(Theme.colorDanger.r,  Theme.colorDanger.g,  Theme.colorDanger.b,  0.14);
                    case "PROCESSING": return Qt.rgba(Theme.colorWarning.r, Theme.colorWarning.g, Theme.colorWarning.b, 0.14);
                    case "SPEAKING":   return Qt.rgba(Theme.accentColor.r,  Theme.accentColor.g,  Theme.accentColor.b,  0.14);
                    case "ERROR":      return Qt.rgba(Theme.colorDanger.r,  Theme.colorDanger.g,  Theme.colorDanger.b,  0.18);
                    default:           return Qt.rgba(1, 1, 1, 0.05);
                }
            }
            border.width: 1
            border.color: {
                switch (root.voiceStatus) {
                    case "LISTENING":  return Qt.rgba(Theme.colorSuccess.r, Theme.colorSuccess.g, Theme.colorSuccess.b, 0.55);
                    case "RECORDING":  return Qt.rgba(Theme.colorDanger.r,  Theme.colorDanger.g,  Theme.colorDanger.b,  0.65);
                    case "PROCESSING": return Qt.rgba(Theme.colorWarning.r, Theme.colorWarning.g, Theme.colorWarning.b, 0.65);
                    case "SPEAKING":   return Qt.rgba(Theme.accentColor.r,  Theme.accentColor.g,  Theme.accentColor.b,  0.65);
                    case "ERROR":      return Qt.rgba(Theme.colorDanger.r,  Theme.colorDanger.g,  Theme.colorDanger.b,  0.75);
                    default:           return Theme.textInactive;
                }
            }

            ColumnLayout {
                id: voiceBanner
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    // State icon — pulses while listening, spins while processing
                    Text {
                        id: voiceIcon
                        text: {
                            switch (root.voiceStatus) {
                                case "LISTENING":  return "\uD83C\uDFA4"; // 🎤
                                case "RECORDING":  return "\uD83D\uDD34"; // 🔴
                                case "PROCESSING": return "\u2699";       // ⚙
                                case "SPEAKING":   return "\uD83D\uDD0A"; // 🔊
                                case "DOWNLOADING_MODEL":
                                case "DOWNLOADING_VOICE": return "\u2B07"; // ⬇
                                case "ERROR":      return "\u26A0";        // ⚠
                                default:           return "\u23F3";        // ⏳
                            }
                        }
                        font.pixelSize: 16
                        color: Theme.accentColor

                        SequentialAnimation on opacity {
                            running: root.voiceListening
                            loops: Animation.Infinite
                            NumberAnimation { to: 1.0; duration: 700 }
                            NumberAnimation { to: 0.35; duration: 700 }
                            onStopped: voiceIcon.opacity = 1.0
                        }
                        RotationAnimation on rotation {
                            running: root.voiceStatus === "PROCESSING"
                                  || root.voiceStatus === "DOWNLOADING_MODEL"
                                  || root.voiceStatus === "DOWNLOADING_VOICE"
                            loops: Animation.Infinite
                            from: 0; to: 360; duration: 1400
                            onStopped: voiceIcon.rotation = 0
                        }
                    }

                    // Plain-French status label so the state is unambiguous
                    Text {
                        Layout.fillWidth: true
                        text: {
                            switch (root.voiceStatus) {
                                case "LISTENING":  return "À l'écoute — parlez";
                                case "RECORDING":  return "Enregistrement de votre voix…";
                                case "PROCESSING": return "Transcription en cours…";
                                case "SPEAKING":   return "Lecture de la réponse…";
                                case "DOWNLOADING_MODEL": return "Téléchargement du modèle Whisper…";
                                case "DOWNLOADING_VOICE": return "Téléchargement de la voix Piper…";
                                case "READY":      return "Micro prêt";
                                case "ERROR":      return "Erreur du micro";
                                case "OFF":        return "Micro désactivé";
                                default:           return "Initialisation…";
                            }
                        }
                        color: Theme.accentColor
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        font.bold: root.voiceListening || root.voiceStatus === "RECORDING"
                        elide: Text.ElideRight
                    }

                    // Stop / mute button — instantly closes the voice loop
                    Text {
                        text: "[stop]"
                        color: stopMa.containsMouse ? Theme.colorDanger : Theme.textInactive
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        MouseArea {
                            id: stopMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.voiceEnabled = false;
                                root.voiceStatus  = "OFF";
                                root.voiceDebug   = "";
                            }
                        }
                    }
                }

                // Live audio meter — visible while the mic is actually being
                // captured. Goes flat (and fades) when we are processing or
                // speaking, which doubles as a visual "input is locked" cue.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 18
                    spacing: 2
                    opacity: (root.voiceListening || root.voiceStatus === "RECORDING") ? 1.0 : 0.35

                    Repeater {
                        model: 24
                        delegate: Rectangle {
                            required property int index
                            Layout.fillWidth: true
                            Layout.preferredHeight: 18
                            radius: 1
                            readonly property real level:
                                root.micLevelHistory[index] || 0
                            color: Qt.rgba(
                                Theme.accentColor.r,
                                Theme.accentColor.g,
                                Theme.accentColor.b,
                                0.18 + 0.82 * Math.min(1, level)
                            )
                            // Fill from the centre so it reads as a waveform.
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width
                                height: Math.max(2, parent.height * Math.min(1, level))
                                radius: 1
                                color: Theme.accentColor
                                Behavior on height { NumberAnimation { duration: 60; easing.type: Easing.OutQuad } }
                            }
                        }
                    }
                }

                // Live wake-word debug echo (whatever whisper just heard)
                Text {
                    Layout.fillWidth: true
                    visible: root.voiceListening && root.voiceDebug !== ""
                    text: "“" + root.voiceDebug + "”"
                    color: Theme.textInactive
                    font.family: "JetBrains Mono"
                    font.pixelSize: 9
                    font.italic: true
                    opacity: 0.6
                    elide: Text.ElideLeft
                }
            }
        }

        // -- Message list --
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
                if (!userScrolledUp)
                    positionViewAtEnd();
            }

            onCountChanged: {
                userScrolledUp = false;
                Qt.callLater(positionViewAtEnd);
            }
            onContentHeightChanged: Qt.callLater(scrollToEndIfNeeded)
            onDragStarted: userScrolledUp = true
            onFlickStarted: userScrolledUp = true
            onMovementStarted: userScrolledUp = true
            onAtYEndChanged: {
                if (atYEnd)
                    userScrolledUp = false;
            }

            delegate: Item {
                required property string role
                required property string content
                required property string msgType

                width: msgList.width
                height: msgType === "screenshot" ? screenshotCol.height + 4 : msgRow.height + 4

                // Screenshot bubble
                Column {
                    id: screenshotCol
                    visible: msgType === "screenshot"
                    width: parent.width
                    spacing: 4

                    Text {
                        text: "\uD83D\uDCF7 " + content
                        color: Theme.textDim
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        wrapMode: Text.WrapAnywhere
                        width: parent.width
                    }

                    Image {
                        id: screenshotImg
                        source: msgType === "screenshot" ? "file://" + content : ""
                        width: parent.width
                        height: status === Image.Ready
                                ? Math.min(width * sourceSize.height / sourceSize.width, 300)
                                : 50
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        cache: false
                    }
                }

                Row {
                    id: msgRow
                    visible: msgType !== "screenshot"
                    width: parent.width

                    Text {
                        id: prefixText
                        text: role === "user" ? "> " : (msgType === "action" ? "$ " : "  ")
                        color: role === "user" ? Theme.accentColor : (msgType === "action" ? Theme.colorAmber : Theme.textInactive)
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                    }

                    TextEdit {
                        id: msgBodyText
                        width: msgRow.width - prefixText.implicitWidth - (copyBtn.visible ? copyBtn.implicitWidth + 6 : 0)
                        readOnly: true
                        selectByMouse: true
                        text: (role === "assistant" && content === "" && root.isStreaming)
                              ? "\u258B" : content
                        color: {
                            if (role === "user") return Theme.accentColor;
                            if (msgType === "action") return Theme.colorAmber;
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
                        visible: role === "assistant" && content !== "" && !root.isStreaming
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
                                copyProcess.running = true;
                                copyProcess.write(content);
                                copyProcess.closeStdin();
                                copyTimer.restart();
                            }
                        }

                        Timer {
                            id: copyTimer
                            interval: 2000
                        }
                    }
                }
            }
        }

        // Spacer: centers input when conversation is empty
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: messages.count === 0
        }

        // -- Input bar --
        RowLayout {
            Layout.fillWidth: true
            Layout.minimumHeight: 28
            spacing: 0
            clip: true

            Text {
                text: "> "
                color: (root.isStreaming || root.voiceBusy) ? Theme.textInactive : Theme.accentColor
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
                    placeholderText: {
                        if (root.voiceBusy) {
                            switch (root.voiceStatus) {
                                case "RECORDING":  return "\uD83C\uDFA4 enregistrement…";
                                case "PROCESSING": return "\u2699 transcription…";
                                case "SPEAKING":   return "\uD83D\uDD0A lecture de la réponse…";
                                default:           return "\u23F3 patientez…";
                            }
                        }
                        if (root.voiceListening) return "\uD83C\uDFA4 parlez ou tapez…";
                        if (root.isStreaming)   return "\u2026";
                        return "message";
                    }
                    placeholderTextColor: Theme.placeholderColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.accentColor
                    background: Item {}
                    enabled: !root.isStreaming && !root.voiceBusy
                    topPadding: 4
                    bottomPadding: 4
                    leftPadding: 0
                    rightPadding: 0
                    Keys.onReturnPressed: (event) => {
                        if (event.modifiers & Qt.ShiftModifier) {
                            // Shift+Enter = line break
                            insert(cursorPosition, "\n");
                        } else {
                            root.sendMessage();
                        }
                    }
                }
            }
        }

        // -- Bottom controls --
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // Model selector: click on the text to open model list
            Item {
                id: modelSelector
                implicitHeight: 18
                implicitWidth: modelLabel.implicitWidth

                Text {
                    id: modelLabel
                    text: "// " + root.modelName
                    color: Theme.accentColor
                    opacity: modelMa.containsMouse ? 0.8 : 0.4
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    verticalAlignment: Text.AlignVCenter
                    height: parent.height
                }

                MouseArea {
                    id: modelMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: modelPopup.open()
                }

                Popup {
                    id: modelPopup
                    y: -implicitHeight - 2
                    x: 0
                    padding: 1
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                    background: Rectangle {
                        color: Theme.bgDeep
                        border.color: Theme.accentColor
                        border.width: 1
                    }

                    contentItem: ListView {
                        id: modelListView
                        clip: true
                        implicitWidth: 180
                        implicitHeight: Math.min(contentHeight, 200)
                        model: root.availableModels.length > 0
                            ? root.availableModels
                            : [root.modelName]
                        ScrollIndicator.vertical: ScrollIndicator {}

                        delegate: Item {
                            required property string modelData
                            required property int index
                            width: modelListView.width
                            height: 20

                            Text {
                                anchors.fill: parent
                                leftPadding: 6
                                text: modelData
                                font.family: "JetBrains Mono"
                                font.pixelSize: 10
                                color: delegateMa.containsMouse ? Theme.selectedTextColor : Theme.accentColor
                                opacity: delegateMa.containsMouse ? 1.0 : 0.6
                                verticalAlignment: Text.AlignVCenter
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: delegateMa.containsMouse ? Theme.accentColor : "transparent"
                                z: -1
                            }

                            MouseArea {
                                id: delegateMa
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    root.modelName = modelData;
                                    root.modelReady = false;
                                    root.checkAndPullModel();
                                    modelPopup.close();
                                }
                            }
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // Mic toggle
            Text {
                text: {
                    if (!root.voiceEnabled) return "[mic]";
                    switch (root.voiceStatus) {
                        case "RECORDING":  return "[mic:rec]";
                        case "PROCESSING": return "[mic:…]";
                        case "SPEAKING":   return "[mic:tts]";
                        case "LISTENING":  return "[mic:on]";
                        default:           return "[mic:on]";
                    }
                }
                color: {
                    if (!root.voiceEnabled) return Theme.textInactive;
                    if (root.voiceStatus === "RECORDING") return Theme.colorDanger;
                    if (root.voiceStatus === "PROCESSING") return Theme.colorWarning;
                    return Theme.accentColor;
                }
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                opacity: micMa.containsMouse ? 1.0 : 0.7

                MouseArea {
                    id: micMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.voiceEnabled = !root.voiceEnabled;
                        if (!root.voiceEnabled) {
                            root.voiceStatus = "OFF";
                            root.voiceDebug = "";
                        }
                    }
                }
            }

            // TTS toggle
            Text {
                text: root.ttsEnabled ? "[tts:on]" : "[tts]"
                color: root.ttsEnabled ? Theme.accentColor : Theme.textInactive
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                opacity: ttsMa.containsMouse ? 1.0 : 0.7

                MouseArea {
                    id: ttsMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.ttsEnabled = !root.ttsEnabled
                }
            }

            // Clear
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

        // Spacer: balances centering when conversation is empty
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: messages.count === 0
        }
    }
}
