import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "../services"

pragma ComponentBehavior: Bound

// OllamaTools: tool definitions, execution logic and processes for OllamaChat.
// Emits toolResult(toolName, assistantIdx, result) when any tool finishes.
Item {
    id: root

    signal toolResult(string toolName, int assistantIdx, string result)

    // ── Tool definitions sent to Ollama ──────────────────────────────────────
    property var toolDefinitions: [
        {
            type: "function",
            "function": {
                name: "switch_workspace",
                description: "Switch to a specific workspace by number (1-5)",
                parameters: {
                    type: "object",
                    properties: {
                        workspace_id: { type: "integer", description: "Workspace number from 1 to 5" }
                    },
                    required: ["workspace_id"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "open_application",
                description: "Open/launch an application by its command name (e.g. firefox, nautilus, alacritty). The default terminal emulator on this system is alacritty — always use 'alacritty' when the user asks to open a terminal (never kitty, wezterm, gnome-terminal, etc.)",
                parameters: {
                    type: "object",
                    properties: {
                        command: { type: "string", description: "Application command to launch" }
                    },
                    required: ["command"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "open_url",
                description: "Open a URL or perform a web search in the default browser (Zen). Use when the user asks to open a website, find information online, search for a recipe, watch YouTube, look something up, etc. Provide 'query' for searches (e.g. 'sausage pasta recipe') or 'url' for direct sites (e.g. https://youtube.com).",
                parameters: {
                    type: "object",
                    properties: {
                        url: { type: "string", description: "Full URL to open directly, e.g. https://youtube.com, https://github.com" },
                        query: { type: "string", description: "Search query for Google, e.g. 'sausage pasta recipe', 'weather Paris', 'how to fix NixOS'" }
                    }
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "close_active_window",
                description: "Close the currently focused/active window",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "move_window_to_workspace",
                description: "Move the currently active window to a specific workspace",
                parameters: {
                    type: "object",
                    properties: {
                        workspace_id: { type: "integer", description: "Target workspace number (1-5)" }
                    },
                    required: ["workspace_id"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "toggle_fullscreen",
                description: "Toggle fullscreen mode for the currently active window",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "focus_direction",
                description: "Move window focus in a direction (left, right, up, down)",
                parameters: {
                    type: "object",
                    properties: {
                        direction: { type: "string", description: "Direction: l (left), r (right), u (up), d (down)" }
                    },
                    required: ["direction"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "set_volume",
                description: "Set the system audio volume to a percentage",
                parameters: {
                    type: "object",
                    properties: {
                        percent: { type: "integer", description: "Volume percentage (0-100)" }
                    },
                    required: ["percent"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "set_brightness",
                description: "Set screen brightness to a percentage",
                parameters: {
                    type: "object",
                    properties: {
                        percent: { type: "integer", description: "Brightness percentage (0-100)" }
                    },
                    required: ["percent"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "screenshot",
                description: "Take a screenshot (full screen, active window, or selected area)",
                parameters: {
                    type: "object",
                    properties: {
                        region: { type: "string", description: "Region to capture: screen, active, or area" }
                    },
                    required: ["region"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "send_notification",
                description: "Send a desktop notification",
                parameters: {
                    type: "object",
                    properties: {
                        title: { type: "string", description: "Notification title" },
                        body: { type: "string", description: "Notification body text" }
                    },
                    required: ["title", "body"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "get_system_info",
                description: "Get system information (CPU usage, memory usage, uptime, disk usage)",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "list_windows",
                description: "List all open windows with their titles, classes and workspaces",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "run_command",
                description: "Run an arbitrary shell command and return its output",
                parameters: {
                    type: "object",
                    properties: {
                        command: { type: "string", description: "Shell command to execute" }
                    },
                    required: ["command"]
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "nixos_rebuild",
                description: "Rebuild the NixOS system configuration from /etc/nixos. Action can be: switch (apply immediately, default), boot (apply on next reboot), test (apply temporarily without making permanent). Requires sudo.",
                parameters: {
                    type: "object",
                    properties: {
                        action: { type: "string", description: "switch (default), boot, or test" }
                    }
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "nix_flake_update",
                description: "Update all flake inputs (nixpkgs, home-manager, DMS, etc.) in the NixOS configuration",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "nix_flake_check",
                description: "Check the NixOS flake configuration for errors without building anything",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "nix_gc",
                description: "Run Nix garbage collection to free disk space. If delete_old is true, deletes all old system generations first (more aggressive cleanup).",
                parameters: {
                    type: "object",
                    properties: {
                        delete_old: { type: "boolean", description: "Delete all old generations before GC (sudo nix-collect-garbage -d)" }
                    }
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "nix_list_generations",
                description: "List all NixOS system generations with their dates, to see available rollback points",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "nixos_rollback",
                description: "Rollback to the previous NixOS generation (undo last rebuild)",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "start_recording",
                description: "Start recording microphone input to a WAV file in /records/. Optionally specify a filename (without path or extension).",
                parameters: {
                    type: "object",
                    properties: {
                        filename: { type: "string", description: "Optional filename without extension. Defaults to a timestamp-based name like rec_2026-04-25T14-30-00." }
                    }
                }
            }
        },
        {
            type: "function",
            "function": {
                name: "stop_recording",
                description: "Stop the current microphone recording and save the WAV file to /records/",
                parameters: { type: "object", properties: {} }
            }
        },
        {
            type: "function",
            "function": {
                name: "set_accent_color",
                description: "Change the desktop accent color used by Hyprland window borders, the shell bar, and terminal colors. Accepts a hex color (#rrggbb) or a preset name. Presets: nixos (#5277c3), nixos-light (#7ebae4), teal (#44aa88), coral (#cc5544), amber (#ccaa44), red (#e53935), orange (#fb8c00), yellow (#fdd835), green (#43a047), cyan (#00acc1), blue (#1e88e5), purple (#8e24aa), pink (#ec407a), magenta (#d81b60), lime (#c0ca33), mint (#26a69a), rose (#f06292), violet (#7e57c2), indigo (#3949ab), white (#eceff1), black (#212121). Special modes: 'rainbow' cycles through all hues continuously, 'stop' / 'static' stops the rainbow cycling.",
                parameters: {
                    type: "object",
                    properties: {
                        color: { type: "string", description: "Hex color (#rrggbb), preset name, or special mode (rainbow, stop)" }
                    },
                    required: ["color"]
                }
            }
        }
    ]

    // ── Rainbow accent cycler ────────────────────────────────────────────────
    // When 'rainbow' mode is requested, this Timer cycles the accent hue
    // through the full HSV wheel. Stops on any explicit color or 'stop'.
    property real rainbowHue: 0.0
    Timer {
        id: rainbowTimer
        interval: 200          // ms between hue steps (~5 fps, smooth + cheap)
        repeat: true
        running: false
        onTriggered: {
            root.rainbowHue = (root.rainbowHue + 0.02) % 1.0;  // step ~7°/tick
            // Saturated, mid-bright color — readable on both dark/light themes.
            var c = Qt.hsva(root.rainbowHue, 0.75, 0.85, 1.0);
            var hex = "#"
                + Math.round(c.r * 255).toString(16).padStart(2, "0")
                + Math.round(c.g * 255).toString(16).padStart(2, "0")
                + Math.round(c.b * 255).toString(16).padStart(2, "0");
            Theme.setAccentColor(hex);
        }
    }

    // ── Process for shell-based tools ────────────────────────────────────────
    Process {
        id: toolProcess

        property string pendingToolName: ""
        property int pendingAssistantIdx: -1
        property string pendingMeta: ""  // extra context (e.g. URL for open_url)
        property string stdoutBuffer: ""
        property string stderrBuffer: ""

        stdout: SplitParser {
            onRead: (data) => { toolProcess.stdoutBuffer += data + "\n" }
        }
        stderr: SplitParser {
            onRead: (data) => { toolProcess.stderrBuffer += data + "\n" }
        }

        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            var result;
            if (pendingToolName === "open_url") {
                result = code === 0
                    ? "Navigateur ouvert : " + pendingMeta
                    : "Erreur lors de l'ouverture du navigateur (code " + code + ")";
            } else if (pendingToolName === "screenshot") {
                // Le chemin seul : OllamaChat l'affiche comme image.
                result = code === 0 ? pendingMeta : "\u00C9chec de la capture (code " + code + ")";
            } else {
                result = stdoutBuffer.trim() || stderrBuffer.trim() || "(commande terminée, code: " + code + ")";
            }
            stdoutBuffer = "";
            stderrBuffer = "";
            root.toolResult(pendingToolName, pendingAssistantIdx, result);
        }
    }

    // ── Audio recorder process ────────────────────────────────────────────────
    Process {
        id: recordProcess
        property string currentFile: ""
        property string pendingToolName: ""
        property int pendingAssistantIdx: -1

        stdout: SplitParser { onRead: (data) => {} }
        stderr: SplitParser { onRead: (data) => {} }

        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            if (pendingAssistantIdx >= 0) {
                root.toolResult(pendingToolName, pendingAssistantIdx,
                    "Enregistrement sauvegardé : " + currentFile);
                pendingAssistantIdx = -1;
            }
        }
    }

    // ── Garde-fous ────────────────────────────────────────────────────────────
    // Les arguments viennent du modèle, donc potentiellement d'une injection de
    // prompt (une page web lue, un fichier…) : on les valide, et on ne les
    // concatène jamais dans une commande shell.
    readonly property var screenshotRegions: ["screen", "active", "area", "output"]
    readonly property var rebuildActions: ["switch", "boot", "test"]

    // Outils qui modifient le système ou exécutent du code arbitraire :
    // OllamaChat demande une confirmation explicite avant de les lancer.
    readonly property var confirmedTools: [
        "run_command", "nixos_rebuild", "nixos_rollback", "nix_gc", "nix_flake_update"
    ]

    function needsConfirmation(name, args) {
        if (root.confirmedTools.indexOf(name) >= 0)
            return true;
        // `exec` Hyprland lance n'importe quelle ligne de commande : un simple
        // nom de programme passe directement, tout le reste se confirme.
        if (name === "open_application")
            return !/^[A-Za-z0-9._+-]+$/.test(String(args.command || ""));
        return false;
    }

    function validWorkspace(id) {
        var n = Number(id);
        return Number.isInteger(n) && n >= 1 && n <= 10;
    }

    // Lance `argv` dans toolProcess ; toolResult part à la fin du process.
    function runTool(name, assistantIdx, argv, meta) {
        toolProcess.pendingToolName = name;
        toolProcess.pendingAssistantIdx = assistantIdx;
        toolProcess.pendingMeta = meta || "";
        toolProcess.command = argv;
        toolProcess.running = true;
    }

    // ── Format action label shown in the chat bubble ─────────────────────────
    function formatToolAction(name, args) {
        switch (name) {
            case "switch_workspace": return "Workspace \u2192 " + (args.workspace_id || "?");
            case "open_application": return "Ouvrir : " + (args.command || "?");
            case "open_url":
                if (args.query && args.query.trim() !== "")
                    return "\uD83C\uDF10 Recherche : " + args.query;
                return "\uD83C\uDF10 Ouvrir : " + (args.url || "?");
            case "close_active_window": return "Fermer la fen\u00EAtre active";
            case "move_window_to_workspace": return "D\u00E9placer fen\u00EAtre \u2192 workspace " + (args.workspace_id || "?");
            case "toggle_fullscreen": return "Basculer plein \u00E9cran";
            case "focus_direction": return "Focus \u2192 " + (args.direction || "?");
            case "set_volume": return "Volume \u2192 " + (args.percent || "?") + "%";
            case "set_brightness": return "Luminosit\u00E9 \u2192 " + (args.percent || "?") + "%";
            case "screenshot": return "Capture d'\u00E9cran (" + (args.region || "screen") + ")";
            case "send_notification": return "Notification : " + (args.title || "");
            case "get_system_info": return "Infos syst\u00E8me...";
            case "list_windows": return "Liste des fen\u00EAtres...";
            case "run_command": return "$ " + (args.command || "?");
            case "nixos_rebuild": return "nixos-rebuild " + (args.action || "switch") + " --flake .#$(hostname)";
            case "nix_flake_update": return "nix flake update...";
            case "nix_flake_check": return "nix flake check...";
            case "nix_gc": return args.delete_old ? "nix-collect-garbage -d (toutes g\u00E9n\u00E9rations)" : "nix-collect-garbage";
            case "nix_list_generations": return "nixos-rebuild list-generations";
            case "nixos_rollback": return "nixos-rebuild switch --rollback";
            case "start_recording": return "\uD83C\uDF99 Enregistrement \u2192 /records/" + (args.filename || "rec_...") + ".wav";
            case "stop_recording": return "\u23F9 Arr\u00EAt enregistrement";
            case "set_accent_color": return "\uD83C\uDFA8 Couleur d'accent \u2192 " + (args.color || "?");
            default: return name;
        }
    }

    // ── Execute a tool call ───────────────────────────────────────────────────
    function executeToolCall(name, args, assistantIdx) {
        var result = "";

        switch (name) {
            case "switch_workspace":
                if (!root.validWorkspace(args.workspace_id)) {
                    root.toolResult(name, assistantIdx, "Workspace invalide : " + args.workspace_id);
                    break;
                }
                Hyprland.dispatch("workspace " + args.workspace_id);
                result = "Workspace chang\u00E9 vers " + args.workspace_id;
                root.toolResult(name, assistantIdx, result);
                break;

            case "open_application":
                Hyprland.dispatch("exec " + args.command);
                result = "Application lanc\u00E9e : " + args.command;
                root.toolResult(name, assistantIdx, result);
                break;

            case "open_url": {
                var finalUrl = "";
                if (args.query && args.query.trim() !== "") {
                    finalUrl = "https://www.google.com/search?q=" + encodeURIComponent(args.query.trim());
                } else if (args.url && args.url.trim() !== "") {
                    finalUrl = args.url.trim();
                }
                // Security: only allow http/https schemes
                if (!finalUrl.match(/^https?:\/\//)) {
                    root.toolResult(name, assistantIdx, "URL invalide : doit commencer par http:// ou https://");
                    break;
                }
                root.runTool(name, assistantIdx, ["xdg-open", finalUrl], finalUrl);
                break;
            }

            case "close_active_window":
                Hyprland.dispatch("killactive");
                result = "Fen\u00EAtre active ferm\u00E9e";
                root.toolResult(name, assistantIdx, result);
                break;

            case "move_window_to_workspace":
                if (!root.validWorkspace(args.workspace_id)) {
                    root.toolResult(name, assistantIdx, "Workspace invalide : " + args.workspace_id);
                    break;
                }
                Hyprland.dispatch("movetoworkspace " + args.workspace_id);
                result = "Fen\u00EAtre d\u00E9plac\u00E9e vers workspace " + args.workspace_id;
                root.toolResult(name, assistantIdx, result);
                break;

            case "toggle_fullscreen":
                Hyprland.dispatch("fullscreen 0");
                result = "Plein \u00E9cran bascul\u00E9";
                root.toolResult(name, assistantIdx, result);
                break;

            case "focus_direction":
                if (["l", "r", "u", "d"].indexOf(args.direction) < 0) {
                    root.toolResult(name, assistantIdx, "Direction invalide : " + args.direction + " (l, r, u, d)");
                    break;
                }
                Hyprland.dispatch("movefocus " + args.direction);
                result = "Focus d\u00E9plac\u00E9 vers " + args.direction;
                root.toolResult(name, assistantIdx, result);
                break;

            case "set_volume": {
                var vol = Math.max(0, Math.min(100, Number(args.percent) || 0)) / 100.0;
                root.runTool(name, assistantIdx, ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", vol.toString()]);
                break;
            }

            case "set_brightness": {
                var pct = Math.round(Math.max(0, Math.min(100, Number(args.percent) || 0)));
                root.runTool(name, assistantIdx, ["brightnessctl", "set", pct + "%"]);
                break;
            }

            case "screenshot": {
                var region = args.region || "screen";
                if (root.screenshotRegions.indexOf(region) < 0) {
                    root.toolResult(name, assistantIdx, "Région invalide : " + region
                        + " (attendu : " + root.screenshotRegions.join(", ") + ")");
                    break;
                }
                var ts = Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss");
                var savePath = "/tmp/screenshot-" + ts + ".png";
                root.runTool(name, assistantIdx, ["grimblast", "copysave", region, savePath], savePath);
                break;
            }

            case "send_notification":
                root.runTool(name, assistantIdx, ["notify-send", "--", String(args.title || ""), String(args.body || "")]);
                break;

            case "get_system_info":
                root.runTool(name, assistantIdx, ["sh", "-c",
                    "echo '=== CPU ===' && head -1 /proc/stat && echo '=== Memory ===' && free -h && echo '=== Uptime ===' && uptime && echo '=== Disk ===' && df -h /"]);
                break;

            case "list_windows":
                root.runTool(name, assistantIdx, ["hyprctl", "clients", "-j"]);
                break;

            // Les outils ci-dessous ne s'exécutent qu'après confirmation de
            // l'utilisateur (needsConfirmation, appelé par OllamaChat).
            case "run_command":
                root.runTool(name, assistantIdx, ["sh", "-c", String(args.command || "")]);
                break;

            case "nixos_rebuild": {
                var rebuildAction = args.action || "switch";
                if (root.rebuildActions.indexOf(rebuildAction) < 0) {
                    root.toolResult(name, assistantIdx, "Action invalide : " + rebuildAction
                        + " (attendu : " + root.rebuildActions.join(", ") + ")");
                    break;
                }
                // L'action passe en argument positionnel ($1) : jamais interpolée.
                root.runTool(name, assistantIdx, ["sh", "-c",
                    "cd /etc/nixos && sudo nixos-rebuild \"$1\" --flake \".#$(hostname)\" 2>&1",
                    "sh", rebuildAction]);
                break;
            }

            case "nix_flake_update":
                root.runTool(name, assistantIdx, ["sh", "-c", "cd /etc/nixos && nix flake update 2>&1"]);
                break;

            case "nix_flake_check":
                root.runTool(name, assistantIdx, ["sh", "-c", "cd /etc/nixos && nix flake check 2>&1"]);
                break;

            case "nix_gc":
                root.runTool(name, assistantIdx, args.delete_old
                    ? ["sudo", "nix-collect-garbage", "-d"]
                    : ["nix-collect-garbage"]);
                break;

            case "nix_list_generations":
                root.runTool(name, assistantIdx, ["nixos-rebuild", "list-generations"]);
                break;

            case "nixos_rollback":
                root.runTool(name, assistantIdx, ["sudo", "nixos-rebuild", "switch", "--rollback"]);
                break;

            case "start_recording": {
                if (recordProcess.running) {
                    root.toolResult(name, assistantIdx, "Un enregistrement est déjà en cours : " + recordProcess.currentFile);
                    break;
                }
                var now = new Date();
                var pad = function(n) { return String(n).padStart(2, "0"); };
                var recTs = now.getFullYear() + "-" + pad(now.getMonth()+1) + "-" + pad(now.getDate()) +
                         "T" + pad(now.getHours()) + "-" + pad(now.getMinutes()) + "-" + pad(now.getSeconds());
                var fname = (args.filename && String(args.filename).trim() !== "") ? String(args.filename).trim() : ("rec_" + recTs);
                // Un nom de fichier, pas un chemin : ni « / » ni « .. » pour
                // sortir de /records.
                if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(fname) || fname.indexOf("..") >= 0) {
                    root.toolResult(name, assistantIdx, "Nom de fichier invalide : " + fname
                        + " (lettres, chiffres, . _ - uniquement)");
                    break;
                }
                var outPath = "/records/" + fname + ".wav";
                recordProcess.currentFile = outPath;
                // `exec` : arecord remplace le shell, donc l'arrêt du Process
                // (stop_recording) le termine lui, au lieu de le laisser orphelin.
                recordProcess.command = ["sh", "-c", "mkdir -p /records && exec arecord -f cd -t wav \"$1\"", "sh", outPath];
                recordProcess.running = true;
                root.toolResult(name, assistantIdx, "Enregistrement démarré : " + outPath);
                break;
            }

            case "stop_recording":
                if (!recordProcess.running) {
                    root.toolResult(name, assistantIdx, "Aucun enregistrement en cours.");
                    break;
                }
                recordProcess.pendingToolName = name;
                recordProcess.pendingAssistantIdx = assistantIdx;
                recordProcess.running = false;
                break;

            case "set_accent_color": {
                var colorInput = (args.color || "").trim().toLowerCase();
                var presetMap = {
                    "nixos":       "#5277c3",
                    "nixos-light": "#7ebae4",
                    "teal":        "#44aa88",
                    "coral":       "#cc5544",
                    "amber":       "#ccaa44",
                    "red":         "#e53935",
                    "orange":      "#fb8c00",
                    "yellow":      "#fdd835",
                    "green":       "#43a047",
                    "cyan":        "#00acc1",
                    "blue":        "#1e88e5",
                    "purple":      "#8e24aa",
                    "pink":        "#ec407a",
                    "magenta":     "#d81b60",
                    "lime":        "#c0ca33",
                    "mint":        "#26a69a",
                    "rose":        "#f06292",
                    "violet":      "#7e57c2",
                    "indigo":      "#3949ab",
                    "white":       "#eceff1",
                    "black":       "#212121"
                };

                // Special: rainbow mode cycles hues continuously.
                if (colorInput === "rainbow" || colorInput === "arc-en-ciel" || colorInput === "arcenciel") {
                    rainbowTimer.start();
                    root.toolResult(name, assistantIdx, "Mode arc-en-ciel activ\u00E9 \uD83C\uDF08 (dis 'stop' pour arr\u00EAter)");
                    break;
                }
                if (colorInput === "stop" || colorInput === "static" || colorInput === "arr\u00EAt" || colorInput === "arret") {
                    if (rainbowTimer.running) {
                        rainbowTimer.stop();
                        root.toolResult(name, assistantIdx, "Mode arc-en-ciel arr\u00EAt\u00E9.");
                    } else {
                        root.toolResult(name, assistantIdx, "Aucun cycle de couleur en cours.");
                    }
                    break;
                }

                // Any explicit color request stops rainbow mode.
                if (rainbowTimer.running) rainbowTimer.stop();

                var hexColor = presetMap[colorInput] || colorInput;
                if (!/^#[0-9a-f]{6}$/.test(hexColor)) {
                    root.toolResult(name, assistantIdx, "Couleur invalide : '" + args.color + "'. Utilise #rrggbb, un nom (nixos, red, blue, green, purple, pink, cyan, orange, yellow, mint, ...) ou 'rainbow' / 'stop'.");
                    break;
                }
                Theme.setAccentColor(hexColor);
                root.toolResult(name, assistantIdx, "Couleur d'accent chang\u00E9e en " + hexColor);
                break;
            }

            default:
                result = "Outil inconnu : " + name;
                root.toolResult(name, assistantIdx, result);
                break;
        }
    }
}
