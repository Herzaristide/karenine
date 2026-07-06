import QtQuick
import Quickshell.Io
import Quickshell.Hyprland

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

        onExited: (code, status) => {
            var result;
            if (pendingToolName === "open_url") {
                result = code === 0
                    ? "Navigateur ouvert : " + pendingMeta
                    : "Erreur lors de l'ouverture du navigateur (code " + code + ")";
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

        onExited: (code, status) => {
            if (pendingAssistantIdx >= 0) {
                root.toolResult(pendingToolName, pendingAssistantIdx,
                    "Enregistrement sauvegardé : " + currentFile);
                pendingAssistantIdx = -1;
            }
        }
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
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = finalUrl;
                toolProcess.command = ["xdg-open", finalUrl];
                toolProcess.running = true;
                break;
            }

            case "close_active_window":
                Hyprland.dispatch("killactive");
                result = "Fen\u00EAtre active ferm\u00E9e";
                root.toolResult(name, assistantIdx, result);
                break;

            case "move_window_to_workspace":
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
                Hyprland.dispatch("movefocus " + args.direction);
                result = "Focus d\u00E9plac\u00E9 vers " + args.direction;
                root.toolResult(name, assistantIdx, result);
                break;

            case "set_volume":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                var vol = Math.max(0, Math.min(100, args.percent)) / 100.0;
                toolProcess.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", vol.toString()];
                toolProcess.running = true;
                break;

            case "set_brightness":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["brightnessctl", "set", args.percent + "%"];
                toolProcess.running = true;
                break;

            case "screenshot":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                var region = args.region || "screen";
                var ts = Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss");
                var savePath = "/tmp/screenshot-" + ts + ".png";
                toolProcess.command = ["sh", "-c",
                    "grimblast copysave " + region + " '" + savePath + "' >/dev/null 2>&1 && echo '" + savePath + "'"];
                toolProcess.running = true;
                break;

            case "send_notification":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["notify-send", args.title || "", args.body || ""];
                toolProcess.running = true;
                break;

            case "get_system_info":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["sh", "-c",
                    "echo '=== CPU ===' && head -1 /proc/stat && echo '=== Memory ===' && free -h && echo '=== Uptime ===' && uptime && echo '=== Disk ===' && df -h /"];
                toolProcess.running = true;
                break;

            case "list_windows":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["hyprctl", "clients", "-j"];
                toolProcess.running = true;
                break;

            case "run_command":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["sh", "-c", args.command];
                toolProcess.running = true;
                break;

            case "nixos_rebuild":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                var rebuildAction = args.action || "switch";
                toolProcess.command = ["sh", "-c",
                    "cd /etc/nixos && sudo nixos-rebuild " + rebuildAction + " --flake .#$(hostname) 2>&1"];
                toolProcess.running = true;
                break;

            case "nix_flake_update":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["sh", "-c", "cd /etc/nixos && nix flake update 2>&1"];
                toolProcess.running = true;
                break;

            case "nix_flake_check":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["sh", "-c", "cd /etc/nixos && nix flake check 2>&1"];
                toolProcess.running = true;
                break;

            case "nix_gc":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                if (args.delete_old)
                    toolProcess.command = ["sh", "-c", "sudo nix-collect-garbage -d 2>&1"];
                else
                    toolProcess.command = ["sh", "-c", "nix-collect-garbage 2>&1"];
                toolProcess.running = true;
                break;

            case "nix_list_generations":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["nixos-rebuild", "list-generations"];
                toolProcess.running = true;
                break;

            case "nixos_rollback":
                toolProcess.pendingToolName = name;
                toolProcess.pendingAssistantIdx = assistantIdx;
                toolProcess.pendingMeta = "";
                toolProcess.command = ["sh", "-c", "sudo nixos-rebuild switch --rollback 2>&1"];
                toolProcess.running = true;
                break;

            case "start_recording": {
                if (recordProcess.running) {
                    root.toolResult(name, assistantIdx, "Un enregistrement est d\u00E9j\u00E0 en cours : " + recordProcess.currentFile);
                    break;
                }
                var now = new Date();
                var pad = function(n) { return String(n).padStart(2, "0"); };
                var recTs = now.getFullYear() + "-" + pad(now.getMonth()+1) + "-" + pad(now.getDate()) +
                         "T" + pad(now.getHours()) + "-" + pad(now.getMinutes()) + "-" + pad(now.getSeconds());
                var fname = (args.filename && args.filename.trim() !== "") ? args.filename.trim() : ("rec_" + recTs);
                var outPath = "/records/" + fname + ".wav";
                recordProcess.currentFile = outPath;
                recordProcess.command = ["sh", "-c", "mkdir -p /records && arecord -f cd -t wav " + outPath];
                recordProcess.running = true;
                root.toolResult(name, assistantIdx, "Enregistrement d\u00E9marr\u00E9 : " + outPath);
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
