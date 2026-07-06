pragma Singleton
import QtQuick
import QtCore
import Quickshell.Io

QtObject {
    id: themeRoot

    // ── UI overlay state ──────────────────────────────────────────────────
    property bool settingsOpen: false

    // ── State from the anna daemon ────────────────────────────────────────
    // state.json is written by anna on every color/mode change.
    // FileView watches it for changes and triggers a full re-parse.
    //
    // Fallbacks (used before first file load or if the daemon is not running)
    // match the daemon's embedded NixOS blue accent so the UI is never blank.
    property var _state: ({
        "accent":       "#5277c3",
        "accent_dark":  "#2d4370",
        "accent_muted": "#6a87cc",
        "accent_rgb":   "82,119,195",
        "accent_ansi":  "38;2;82;119;195",
        "mode":         "dark",
        "palette": {
            "base00": "#0d0d0d", "base01": "#1a1a1a",
            "base02": "#2a2a2a", "base03": "#5a6080",
            "base04": "#8a90b0", "base05": "#e0e0ff",
            "base06": "#f0f0ff", "base07": "#ffffff",
            "base08": "#cc4444", "base09": "#cc8844",
            "base0a": "#ccaa44", "base0b": "#44aa88",
            "base0c": "#7ebae4", "base0d": "#5277c3",
            "base0e": "#4488cc", "base0f": "#cc5566"
        }
    })

    property FileView _stateFile: FileView {
        path: StandardPaths.writableLocation(StandardPaths.HomeLocation)
              + "/.config/accent/state.json"
        watchChanges: true
        printErrors: false
        onLoaded:      themeRoot._parseState()
        onFileChanged: reload()
    }

    function _parseState() {
        try {
            var parsed = JSON.parse(_stateFile.text())
            if (parsed && parsed.accent && parsed.palette) {
                themeRoot._state = parsed
            }
        } catch (e) { /* keep current _state if JSON is incomplete */ }
    }

    // ── Convenience accessors ──────────────────────────────────────────────
    readonly property bool   darkMode: _state.mode !== "light"
    readonly property string accentHex: _state.accent || "#5277c3"

    // ── Accent colors (read from daemon state, no local re-computation) ────
    readonly property color accentColor: accentHex
    readonly property color accentDark:  _state.accent_dark  || Qt.darker(accentColor, 1.8)
    readonly property color accentMuted: _state.accent_muted || accentColor

    // ── Background surfaces (base00 / base01 from active palette) ─────────
    readonly property color bgDeep:     _state.palette ? _state.palette.base00 : (darkMode ? "#0d0d0d" : "#f5f5ff")
    readonly property color bgElevated: _state.palette ? _state.palette.base01 : (darkMode ? "#1a1a1a" : "#eaeaff")
    readonly property color bgInput:    _state.palette ? _state.palette.base01 : (darkMode ? "#141414" : "#f8f8ff")

    // ── Dividers & overlays ────────────────────────────────────────────────
    readonly property color dividerColor: darkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.12)
    readonly property color hoverOverlay: darkMode ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(0, 0, 0, 0.05)

    // ── Text hierarchy (base05 / base04 / base03) ──────────────────────────
    readonly property color textPrimary:   _state.palette ? _state.palette.base05 : (darkMode ? "#e0e0ff" : "#1a1a3e")
    readonly property color textSecondary: _state.palette ? _state.palette.base04 : (darkMode ? "#8a90b0" : "#555577")
    readonly property color textDim:       _state.palette ? _state.palette.base03 : (darkMode ? "#5a6080" : "#888899")
    readonly property color textInactive:  darkMode ? "#3e4060" : "#888888"
    readonly property color textSubtle:    darkMode ? "#2e3050" : "#999999"
    readonly property color textBody:      darkMode ? "#c8ccf0" : "#2a2a3e"

    // ── Icons & interactive elements ───────────────────────────────────────
    readonly property color iconColor:         _state.palette ? _state.palette.base07 : (darkMode ? "#FFFFFF" : "#222244")
    readonly property color placeholderColor:  darkMode ? "#30FFFFFF" : "#50000000"
    readonly property color selectedTextColor: darkMode ? "#000000"   : "#FFFFFF"

    // Canvas notation staff (r,g,b string for use in rgba() calls)
    readonly property string canvasLineRGB: darkMode ? "255,255,255" : "0,0,0"

    // ── Semantic status colors (base16 roles) ─────────────────────────────
    // base08=danger/red, base09=warning/orange, base0a=amber/yellow
    // base0b=success/green, base0c=cyan, base0e=alt-blue, base0f=coral
    readonly property color colorDanger:  _state.palette ? _state.palette.base08 : "#cc4444"
    readonly property color colorWarning: _state.palette ? _state.palette.base09 : "#cc8844"
    readonly property color colorAmber:   _state.palette ? _state.palette.base0a : "#ccaa44"
    readonly property color colorSuccess: _state.palette ? _state.palette.base0b : "#44aa88"
    readonly property color colorCyan:    _state.palette ? _state.palette.base0c : "#7ebae4"
    readonly property color colorAltBlue: _state.palette ? _state.palette.base0e : "#4488cc"
    readonly property color colorCoral:   _state.palette ? _state.palette.base0f : "#cc5566"

    // ── Chart series colors ───────────────────────────────────────────────
    // CPU series → accentColor, RAM → colorSuccess, GPU → colorCoral
    readonly property color colorRam: colorSuccess
    readonly property color colorGpu: colorCoral
    // Disk series — 6 slots cycling through distinct palette roles
    readonly property var diskSeriesColors: [
        _state.palette ? _state.palette.base0e : "#4488cc",
        _state.palette ? _state.palette.base09 : "#cc8844",
        _state.palette ? _state.palette.base0b : "#44aa88",
        _state.palette ? _state.palette.base0f : "#cc5566",
        _state.palette ? _state.palette.base0a : "#ccaa44",
        _state.palette ? _state.palette.base0c : "#7ebae4"
    ]

    // ── Theme side-effects (GTK color-scheme + wallpaper) ──────────────────
    property Process gtkProcess: Process {
        property string pendingScheme: ""
        command: ["gsettings", "set", "org.gnome.desktop.interface",
                  "color-scheme", pendingScheme]
    }

    property Process wallpaperProcess: Process {
        property string pendingVariant: "dark"
        command: ["sh", "-c",
                  "awww img $HOME/.config/wallpaper-" + pendingVariant + " --transition-type=fade --transition-duration 0.1 --transition-fps 255"]
    }

    function toggleTheme() {
        var newMode = darkMode ? "light" : "dark"
        gtkProcess.pendingScheme = darkMode ? "prefer-light" : "prefer-dark"
        gtkProcess.running = true
        wallpaperProcess.pendingVariant = newMode
        wallpaperProcess.running = true
        // Delegate mode change to the daemon — it re-renders all templates,
        // fires live-reload signals, and writes the updated state.json which
        // this FileView will pick up automatically.
        accentModeProcess._pendingMode = newMode
        accentModeProcess.running = true
    }

    // ── Preset palette ─────────────────────────────────────────────────────
    readonly property var presets: [
        "#5277c3",  // NixOS blue (default)
        "#7ebae4",  // NixOS light blue
        "#44aa88",  // teal-green
        "#cc5544",  // coral
        "#ccaa44"   // amber
    ]

    // ── IPC with the anna daemon ───────────────────────────────────────────
    // Both processes send a JSON command to the Unix socket via the `anna`
    // CLI client.  state.json is updated by the daemon on completion and
    // picked up by _stateFile's watchChanges.

    property Process accentSetProcess: Process {
        property string pendingColor: ""
        command: ["anna", "set", pendingColor]
    }

    property Process accentModeProcess: Process {
        property string _pendingMode: "dark"
        command: ["anna", "mode", _pendingMode]
    }

    property Process paletteColorProcess: Process {
        property string pendingKey:   ""
        property string pendingColor: ""
        command: ["anna", "palette-color", pendingKey, pendingColor]
    }

    property Process resetProcess: Process {
        command: ["sh", "-c",
            "anna set '#5277c3' && " +
            "anna palette-color base00 '#0d0d0d' && " +
            "anna palette-color base01 '#1a1a1a' && " +
            "anna palette-color base02 '#2a2a2a' && " +
            "anna palette-color base03 '#5a6080' && " +
            "anna palette-color base04 '#8a90b0' && " +
            "anna palette-color base05 '#e0e0ff' && " +
            "anna palette-color base06 '#f0f0ff' && " +
            "anna palette-color base07 '#ffffff' && " +
            "anna palette-color base08 '#cc4444' && " +
            "anna palette-color base09 '#cc8844' && " +
            "anna palette-color base0a '#ccaa44' && " +
            "anna palette-color base0b '#44aa88' && " +
            "anna palette-color base0c '#7ebae4' && " +
            "anna palette-color base0d '#5277c3' && " +
            "anna palette-color base0e '#4488cc' && " +
            "anna palette-color base0f '#cc5566'"
        ]
    }

    // ── Palette accessor ───────────────────────────────────────────────────
    /// Raw base16 palette for the active mode (reactive: updates when _state changes).
    readonly property var palette: _state.palette || {}

    // ── Setters ────────────────────────────────────────────────────────────
    function setAccentColor(str) {
        // Optimistic update: apply instantly to accentHex for immediate
        // visual feedback; the daemon confirms by writing state.json.
        themeRoot._state = Object.assign({}, themeRoot._state, { accent: str })
        accentSetProcess.pendingColor = str
        accentSetProcess.running = true
    }

    function setPaletteColor(key, colorStr) {
        // Optimistic update: patch the in-memory palette immediately.
        var newPalette = Object.assign({}, themeRoot._state.palette)
        newPalette[key] = colorStr
        themeRoot._state = Object.assign({}, themeRoot._state, { palette: newPalette })
        paletteColorProcess.pendingKey   = key
        paletteColorProcess.pendingColor = colorStr
        paletteColorProcess.running = true
    }

    function resetToDefaults() {
        var defaults = {
            accent: "#5277c3", accent_dark: "#2d4370", accent_muted: "#6a87cc",
            accent_rgb: "82,119,195", accent_ansi: "38;2;82;119;195",
            mode: themeRoot._state.mode,
            palette: {
                base00: "#0d0d0d", base01: "#1a1a1a", base02: "#2a2a2a", base03: "#5a6080",
                base04: "#8a90b0", base05: "#e0e0ff", base06: "#f0f0ff", base07: "#ffffff",
                base08: "#cc4444", base09: "#cc8844", base0a: "#ccaa44", base0b: "#44aa88",
                base0c: "#7ebae4", base0d: "#5277c3", base0e: "#4488cc", base0f: "#cc5566"
            }
        }
        themeRoot._state = defaults
        resetProcess.running = true
    }
}
