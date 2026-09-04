import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../services"

pragma ComponentBehavior: Bound

// ConsoleWidget: a command console, not a terminal emulator.
//
// Quickshell.Io.Process is a QProcess — pipes only, no pty — so a command run
// through it sees a pipe on stdout: no colours, block buffering, and column
// layouts (`ls`, `git status`) computed for an unknown width. The fix is to let
// util-linux `script` allocate the pty for us: it forks a real /dev/pts pair
// even when its own stdin and stdout are pipes, which is exactly our situation.
//
// The command itself is never interpolated into the wrapper — it travels in
// QS_CMD, so there is no shell quoting to get wrong. The wrapper:
//
//   stty cols …   sizes the pty from the panel width, before the command runs,
//                 so `ls` and friends lay out for the space they actually have
//   cd "$QS_CWD"  restores the working directory of the previous command
//   eval "$QS_CMD"
//   printf …      emits \001<code>\001<cwd>\001, which is how `cd` persists
//                 across runs and how the exit status gets back here
//
// What this is NOT: a terminal. There is no stdin, and no cursor addressing —
// full-screen programs (vim, htop, less) will paint escape sequences we drop
// and then sit there until [stop]. PAGER=cat keeps the common ones (git log)
// from doing that by accident. A real terminal needs a VT state machine and a
// cell grid, which belongs in the anna daemon, not in QML.
Item {
    id: root

    // Set by the panel: true while this widget is the visible one. Only used to
    // grab the keyboard — the shell process is never tied to visibility.
    property bool active: false

    // ── Session state ────────────────────────────────────────────────────────
    property string cwd: ""
    property bool   busy: false
    property int    lastCode: 0
    property bool   interrupted: false

    // Command history, newest last. Plain JS array: nothing binds to it.
    property var    history: []
    property int    historyIdx: -1      // -1 = editing a fresh line
    property string draft: ""           // in-progress line, parked while browsing

    // Ring buffer. Long-running commands (`nix build`) print far more than
    // anyone scrolls back through, and every line is a live delegate.
    readonly property int maxLines: 800

    // Field separator of the completion marker. \001 never occurs in the
    // output of anything sane, which is the whole point of picking it.
    readonly property string markerSep: "\u0001"

    ListModel { id: lines }

    Component.onCompleted: {
        var home = Quickshell.env("HOME");
        root.cwd = home ? home : "/";
    }

    // ── ANSI palette ─────────────────────────────────────────────────────────
    // The 16 ANSI slots mapped onto the base16 palette the rest of the shell
    // already uses, so console output recolours with the theme like everything
    // else. Bright variants reuse the same hues — base16 has no second set.
    readonly property var ansiPalette: {
        var p = Theme.palette || {};
        var pick = function (key, fallback) {
            return p[key] ? p[key] : String(fallback);
        };
        var black   = pick("base00", Theme.bgDeep);
        var red     = pick("base08", Theme.colorDanger);
        var green   = pick("base0b", Theme.colorSuccess);
        var yellow  = pick("base0a", Theme.colorAmber);
        var blue    = pick("base0d", Theme.colorAltBlue);
        var magenta = pick("base0e", Theme.colorAltBlue);
        var cyan    = pick("base0c", Theme.colorCyan);
        var white   = pick("base05", Theme.textPrimary);
        return [
            black, red, green, yellow, blue, magenta, cyan, white,
            pick("base03", Theme.textDim), red, green, yellow, blue, magenta, cyan,
            pick("base07", Theme.iconColor)
        ];
    }

    readonly property string defaultFg: String(Theme.textBody)
    readonly property string defaultBg: String(Theme.bgDeep)

    // Current SGR state. Mutated in place — colours set on one line stay in
    // effect on the next, as they do on a real terminal.
    property var attrs: root.freshAttrs()

    function freshAttrs() {
        return { fg: null, bg: null, bold: false, dim: false,
                 italic: false, underline: false, inverse: false };
    }

    function resetAttrs() {
        var a = root.attrs;
        a.fg = null; a.bg = null;
        a.bold = false; a.dim = false;
        a.italic = false; a.underline = false; a.inverse = false;
    }

    function hex2(v) {
        return ("0" + Math.max(0, Math.min(255, v)).toString(16)).slice(-2);
    }

    // Resolve one colour slot: a literal "#rrggbb" (24-bit SGR), an index into
    // the 256-colour cube, or one of the 16 themed ANSI slots.
    function ansiColor(v) {
        if (typeof v === "string")
            return v;
        if (v < 16)
            return root.ansiPalette[v];
        if (v < 232) {
            var n = v - 16;
            var levels = [0, 95, 135, 175, 215, 255];
            return "#" + root.hex2(levels[Math.floor(n / 36) % 6])
                       + root.hex2(levels[Math.floor(n / 6) % 6])
                       + root.hex2(levels[n % 6]);
        }
        var g = 8 + (v - 232) * 10;
        return "#" + root.hex2(g) + root.hex2(g) + root.hex2(g);
    }

    // 38/48 introduce an extended colour: ";5;<idx>" or ";2;<r>;<g>;<b>".
    // Returns the index of the last parameter consumed.
    function readExtendedColor(parts, i, isFg) {
        var a = root.attrs;
        var mode = parseInt(parts[i + 1], 10);
        if (mode === 5) {
            var idx = parseInt(parts[i + 2], 10);
            if (!isNaN(idx)) {
                if (isFg) a.fg = idx; else a.bg = idx;
            }
            return i + 2;
        }
        if (mode === 2) {
            var r = parseInt(parts[i + 2], 10);
            var g = parseInt(parts[i + 3], 10);
            var b = parseInt(parts[i + 4], 10);
            if (!isNaN(r) && !isNaN(g) && !isNaN(b)) {
                var c = "#" + root.hex2(r) + root.hex2(g) + root.hex2(b);
                if (isFg) a.fg = c; else a.bg = c;
            }
            return i + 4;
        }
        return i + 1;
    }

    function applySgr(params) {
        var a = root.attrs;
        var parts = params === "" ? ["0"] : params.split(";");
        for (var i = 0; i < parts.length; i++) {
            var n = parseInt(parts[i], 10);
            if (isNaN(n)) continue;
            if (n === 0)                   root.resetAttrs();
            else if (n === 1)              a.bold = true;
            else if (n === 2)              a.dim = true;
            else if (n === 3)              a.italic = true;
            else if (n === 4)              a.underline = true;
            else if (n === 7)              a.inverse = true;
            else if (n === 22)           { a.bold = false; a.dim = false; }
            else if (n === 23)             a.italic = false;
            else if (n === 24)             a.underline = false;
            else if (n === 27)             a.inverse = false;
            else if (n >= 30 && n <= 37)   a.fg = n - 30;
            else if (n === 38)             i = root.readExtendedColor(parts, i, true);
            else if (n === 39)             a.fg = null;
            else if (n >= 40 && n <= 47)   a.bg = n - 40;
            else if (n === 48)             i = root.readExtendedColor(parts, i, false);
            else if (n === 49)             a.bg = null;
            else if (n >= 90 && n <= 97)   a.fg = n - 90 + 8;
            else if (n >= 100 && n <= 107) a.bg = n - 100 + 8;
        }
    }

    function escapeHtml(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // Wrap one run of text in the attributes that were live while it was read.
    function wrapSpan(text, a) {
        var fg = a.fg !== null ? root.ansiColor(a.fg)
                               : (a.dim ? String(Theme.textDim) : root.defaultFg);
        var bg = a.bg !== null ? root.ansiColor(a.bg) : "";
        if (a.inverse) {
            var swap = fg;
            fg = bg !== "" ? bg : root.defaultBg;
            bg = swap;
        }
        var style = "color:" + fg + ";";
        if (bg !== "")
            style += "background-color:" + bg + ";";
        var inner = text;
        if (a.bold)      inner = "<b>" + inner + "</b>";
        if (a.italic)    inner = "<i>" + inner + "</i>";
        if (a.underline) inner = "<u>" + inner + "</u>";
        return "<span style=\"" + style + "\">" + inner + "</span>";
    }

    // Turn one raw pty line into { markup, plain }. Only SGR is honoured;
    // every other escape sequence is still recognised, so it can be dropped
    // cleanly instead of printed as mojibake.
    function renderLine(raw) {
        // A carriage return rewinds to column 0 and the rest overwrites what
        // was there. Keeping only the tail is the approximation that makes
        // progress bars settle on their final state instead of stacking up.
        var cr = raw.lastIndexOf("\r");
        if (cr >= 0)
            raw = raw.substring(cr + 1);

        var out = "";
        var seg = "";
        var plain = "";
        var col = 0;

        for (var i = 0; i < raw.length; i++) {
            var c = raw.charAt(i);
            var code = raw.charCodeAt(i);

            if (code === 27) {                       // ESC
                var next = raw.charAt(i + 1);
                if (next === "[") {                  // CSI … <final>
                    var j = i + 2;
                    while (j < raw.length) {
                        var f = raw.charCodeAt(j);
                        if (f >= 0x40 && f <= 0x7e) break;
                        j++;
                    }
                    if (raw.charAt(j) === "m") {
                        if (seg !== "") {
                            out += root.wrapSpan(seg, root.attrs);
                            seg = "";
                        }
                        root.applySgr(raw.substring(i + 2, j));
                    }
                    i = j;
                } else if (next === "]") {           // OSC … BEL | ST
                    var k = i + 2;
                    while (k < raw.length && raw.charCodeAt(k) !== 7
                           && !(raw.charCodeAt(k) === 27 && raw.charAt(k + 1) === "\\"))
                        k++;
                    i = raw.charCodeAt(k) === 27 ? k + 1 : k;
                } else {
                    i++;                             // two-character escape
                }
                continue;
            }

            if (c === "\t") {
                var stop = 8 - (col % 8);
                for (var t = 0; t < stop; t++) {
                    seg += "&nbsp;";
                    plain += " ";
                }
                col += stop;
                continue;
            }

            if (code < 32)                           // remaining control chars
                continue;

            if (c === " ") {
                // Single spaces stay breakable so long lines can still wrap;
                // runs (column layouts, indentation) must not collapse.
                var solo = raw.charAt(i - 1) !== " " && raw.charAt(i + 1) !== " " && col > 0;
                seg += solo ? " " : "&nbsp;";
                plain += " ";
                col++;
                continue;
            }

            seg += root.escapeHtml(c);
            plain += c;
            col++;
        }

        if (seg !== "")
            out += root.wrapSpan(seg, root.attrs);
        return { markup: out, plain: plain };
    }

    // ── Output buffer ────────────────────────────────────────────────────────
    function pushLine(markup, plain) {
        lines.append({ markup: markup, plain: plain });
        if (lines.count > root.maxLines)
            lines.remove(0, lines.count - root.maxLines);
    }

    function pushMeta(text, color) {
        root.pushLine("<span style=\"color:" + String(color) + ";\">"
                      + root.escapeHtml(text) + "</span>", text);
    }

    function shortCwd() {
        var home = Quickshell.env("HOME");
        if (home && root.cwd.indexOf(home) === 0)
            return "~" + root.cwd.substring(home.length);
        return root.cwd;
    }

    // ── Wire protocol from the wrapper ───────────────────────────────────────
    // Output lines arrive as-is; the run ends with \001<code>\001<cwd>\001,
    // which may be glued to the tail of a command that printed no final
    // newline — so we split rather than assume it owns its own line.
    function handleLine(raw) {
        if (raw.length > 0 && raw.charAt(raw.length - 1) === "\r")
            raw = raw.substring(0, raw.length - 1);

        var marker = raw.indexOf(root.markerSep);
        if (marker < 0) {
            var r = root.renderLine(raw);
            root.pushLine(r.markup, r.plain);
            return;
        }

        if (marker > 0) {
            var head = root.renderLine(raw.substring(0, marker));
            root.pushLine(head.markup, head.plain);
        }

        var fields = raw.substring(marker).split(root.markerSep);
        var code = parseInt(fields[1], 10);
        if (!isNaN(code))
            root.lastCode = code;
        if (fields[2])
            root.cwd = fields[2];
    }

    // ── Execution ────────────────────────────────────────────────────────────
    readonly property string wrapper:
        "stty cols \"$QS_COLS\" rows \"$QS_ROWS\" 2>/dev/null; " +
        "cd \"$QS_CWD\" 2>/dev/null; " +
        "eval \"$QS_CMD\"; " +
        "printf '\\001%s\\001%s\\001\\n' \"$?\" \"$PWD\""

    Process {
        id: shellProc
        running: false
        command: ["script", "-qec", root.wrapper, "/dev/null"]

        // script merges the command's stderr into the pty, so stdout carries
        // both streams already interleaved in the order they were written —
        // which two separate pipes could never reproduce.
        stdout: SplitParser {
            onRead: (line) => root.handleLine(line)
        }

        onExited: (code, status) => root.finish(true) // qmllint disable signal-handler-parameters

        // Backstop: a process that never starts at all (no script(1) on PATH)
        // drops back to running=false without ever emitting exited, and the
        // prompt would stay stuck on "busy" forever.
        onRunningChanged: if (!shellProc.running) root.finish(false)
    }

    // Idempotent — whichever of the two signals above arrives first wins.
    function finish(exited) {
        if (!root.busy)
            return;
        root.busy = false;
        root.resetAttrs();
        if (!exited)
            root.pushMeta("[script(1) introuvable]", Theme.colorDanger);
        else if (root.interrupted)
            root.pushMeta("[interrompu]", Theme.colorWarning);
        else if (root.lastCode !== 0)
            root.pushMeta("[code " + root.lastCode + "]", Theme.colorDanger);
        root.interrupted = false;
    }

    function run(text) {
        var cmd = text.trim();
        if (cmd === "" || root.busy)
            return;

        if (root.history.length === 0 || root.history[root.history.length - 1] !== cmd)
            root.history.push(cmd);
        root.historyIdx = -1;
        root.draft = "";

        // `clear` never reaches a shell: there is no screen to erase, only
        // this buffer.
        if (cmd === "clear") {
            lines.clear();
            return;
        }

        root.pushLine("<span style=\"color:" + String(Theme.accentColor) + ";\">$&nbsp;</span>"
                      + "<span style=\"color:" + String(Theme.textSecondary) + ";\">"
                      + root.escapeHtml(cmd) + "</span>",
                      "$ " + cmd);

        root.lastCode = 0;
        root.resetAttrs();

        // Assigned, not bound: the wrapper reads these once at exec time, and a
        // live binding would rewrite the environment under a running command.
        shellProc.environment = {
            "QS_CMD": cmd,
            "QS_CWD": root.cwd,
            "QS_COLS": String(root.columns),
            "QS_ROWS": "2000",
            "SHELL": "bash",
            "TERM": "xterm-256color",
            "PAGER": "cat",
            "GIT_PAGER": "cat"
        };
        root.busy = true;
        shellProc.running = true;
    }

    function stop() {
        if (!root.busy)
            return;
        root.interrupted = true;
        shellProc.signal(15);
    }

    function recall(delta) {
        if (root.history.length === 0)
            return;
        if (root.historyIdx === -1) {
            if (delta > 0)
                return;                      // already at the newest entry
            root.draft = input.text;
            root.historyIdx = root.history.length - 1;
        } else {
            var next = root.historyIdx + delta;
            if (next >= root.history.length) {
                root.historyIdx = -1;
                input.text = root.draft;
                input.cursorPosition = input.text.length;
                return;
            }
            root.historyIdx = Math.max(0, next);
        }
        input.text = root.history[root.historyIdx];
        input.cursorPosition = input.text.length;
    }

    Process {
        id: copyProcess
        command: ["wl-copy"]
        stdinEnabled: true
        onExited: running = false // qmllint disable signal-handler-parameters
    }

    // The buffer as it would look in a terminal, escape sequences resolved
    // away. What [copy] puts on the clipboard.
    function plainBuffer() {
        var buf = "";
        for (var i = 0; i < lines.count; i++)
            buf += lines.get(i).plain + "\n";
        return buf;
    }

    function copyAll() {
        var buf = root.plainBuffer();
        copyProcess.running = false;
        copyProcess.stdinEnabled = true;
        copyProcess.running = true;
        copyProcess.write(buf);
        copyProcess.stdinEnabled = false;
    }

    onActiveChanged: if (root.active) Qt.callLater(input.forceActiveFocus)

    // ── UI ───────────────────────────────────────────────────────────────────
    FontMetrics {
        id: mono
        font.family: "JetBrains Mono"
        font.pixelSize: 12
    }

    // Width of the pty, in characters. The panel is resizable, so this is what
    // keeps `ls` from laying out for 80 columns inside a 40-column panel.
    readonly property int columns:
        Math.max(20, Math.floor((root.width - 16) / Math.max(1, mono.advanceWidth("M"))))

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        ListView {
            id: outputList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 0
            model: lines

            property bool userScrolledUp: false

            function scrollToEndIfNeeded() {
                if (!outputList.userScrolledUp)
                    outputList.positionViewAtEnd();
            }

            onCountChanged: Qt.callLater(outputList.scrollToEndIfNeeded)
            onContentHeightChanged: Qt.callLater(outputList.scrollToEndIfNeeded)
            onDragStarted: outputList.userScrolledUp = true
            onFlickStarted: outputList.userScrolledUp = true
            onMovementStarted: outputList.userScrolledUp = true
            onAtYEndChanged: if (outputList.atYEnd) outputList.userScrolledUp = false

            delegate: TextEdit {
                required property string markup

                width: outputList.width
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.RichText
                text: markup
                color: Theme.textBody
                selectionColor: Theme.accentColor
                selectedTextColor: Theme.selectedTextColor
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                wrapMode: TextEdit.Wrap
            }
        }

        // ── Prompt ───────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            clip: true

            Text {
                text: root.busy ? "… " : "$ "
                color: root.busy ? Theme.textInactive : Theme.accentColor
                font.family: "JetBrains Mono"
                font.pixelSize: 12
            }

            TextField {
                id: input
                Layout.fillWidth: true
                // Never disabled while a command runs: disabling would drop the
                // keyboard focus, and Ctrl+C has to stay reachable.
                placeholderText: root.busy ? "…" : "commande"
                placeholderTextColor: Theme.placeholderColor
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.accentColor
                selectionColor: Theme.accentColor
                selectedTextColor: Theme.selectedTextColor
                background: Item {}
                topPadding: 2
                bottomPadding: 2
                leftPadding: 0
                rightPadding: 0

                onAccepted: {
                    if (root.busy)
                        return;     // keep the line, it is not lost
                    var text = input.text;
                    input.text = "";
                    root.run(text);
                }

                Keys.onUpPressed: root.recall(-1)
                Keys.onDownPressed: root.recall(1)

                // Ctrl+C is the reflex for "stop this", not "copy" — the whole
                // buffer has its own [copy] below.
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
                        root.stop();
                        event.accepted = true;
                    }
                }
            }
        }

        // ── Footer ───────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: root.shortCwd()
                color: Theme.accentColor
                opacity: 0.4
                elide: Text.ElideLeft
                font.family: "JetBrains Mono"
                font.pixelSize: 10
            }

            Text {
                visible: root.busy
                text: "[stop]"
                color: stopMa.containsMouse ? Theme.colorDanger : Theme.textInactive
                font.family: "JetBrains Mono"
                font.pixelSize: 10

                MouseArea {
                    id: stopMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stop()
                }
            }

            Text {
                visible: lines.count > 0
                text: copyTimer.running ? "[copied]" : "[copy]"
                color: copyMa.containsMouse ? Theme.accentColor : Theme.textInactive
                font.family: "JetBrains Mono"
                font.pixelSize: 10

                MouseArea {
                    id: copyMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.copyAll();
                        copyTimer.restart();
                    }
                }
                Timer { id: copyTimer; interval: 2000 }
            }

            Text {
                visible: lines.count > 0
                text: "[clear]"
                color: clearMa.containsMouse ? Theme.colorDanger : Theme.textInactive
                font.family: "JetBrains Mono"
                font.pixelSize: 10

                MouseArea {
                    id: clearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: lines.clear()
                }
            }
        }
    }
}
