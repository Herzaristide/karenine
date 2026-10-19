pragma Singleton
import QtQuick
import QtCore
import Quickshell
import Quickshell.Io

QtObject {
    id: themeRoot

    // ── State from the anna daemon ────────────────────────────────────────
    // state.json is written by anna on every color/mode change.
    // FileView watches it for changes and triggers a full re-parse.
    //
    // Fallbacks (used before first file load or if the daemon is not running)
    // match the daemon's embedded palette (Ajar's ink and copper) so the UI is never blank.
    property var _state: ({
        "accent":       "#d4a35f",
        "accent_dark":  "#765b35",
        "accent_muted": "#e1bd8a",
        "accent_rgb":   "212,163,95",
        "accent_ansi":  "38;2;212;163;95",
        "mode":         "dark",
        "palette": {
            "base00": "#1b1a18", "base01": "#262421",
            "base02": "#34312d", "base03": "#6b645a",
            "base04": "#9a9286", "base05": "#d9d2c5",
            "base06": "#e6e0d4", "base07": "#f2ede4",
            "base08": "#c46a5a", "base09": "#c98a4b",
            "base0a": "#c9a95c", "base0b": "#8fa876",
            "base0c": "#7fa6a0", "base0d": "#d4a35f",
            "base0e": "#8c9bb5", "base0f": "#b57a8a"
        }
    })

    // KARENINE_THEME_STATE remplace ce chemin : le greeter tourne sous un
    // autre utilisateur, sans ~/.config/accent, et reçoit de Nix un état figé.
    property FileView _stateFile: FileView {
        path: Quickshell.env("KARENINE_THEME_STATE")
              || (StandardPaths.writableLocation(StandardPaths.HomeLocation)
                  + "/.config/accent/state.json")
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
    readonly property string accentHex: _state.accent || "#d4a35f"

    // ── Accent colors (read from daemon state, no local re-computation) ────
    readonly property color accentColor: accentHex
    readonly property color accentDark:  _state.accent_dark  || Qt.darker(accentColor, 1.8)
    readonly property color accentMuted: _state.accent_muted || accentColor

    // L'accent tel quel, partout : le design est plat, sans halo irisé ni
    // teinte dérivée. `shift` est ignoré (les anciens appels le passent encore).
    function glow(shift) {
        return accentColor;
    }

    // ── La géométrie, commune à tout le shell ──────────────────────────────
    // Celle d'Ajar : des cartes à 14 px, des lignes et boutons à 8 px.
    readonly property int radius: 14
    readonly property int radiusSmall: 8

    // ── Les neutres : fond et texte ────────────────────────────────────────
    // Lus dans la palette d'anna (réglables), ceux d'Ajar par défaut :
    // l'encre en sombre, le papier en clair.
    readonly property var _ink: ({
        "base00": "#1b1a18", "base01": "#262421",
        "base05": "#d9d2c5", "base04": "#9a9286", "base03": "#6b645a"
    })
    readonly property var _paper: ({
        "base00": "#f5f0e6", "base01": "#ebe4d6",
        "base05": "#2a2521", "base04": "#6e6457", "base03": "#a39887"
    })
    function _neutral(key) {
        return (_state.palette && _state.palette[key]) || (darkMode ? _ink : _paper)[key];
    }

    // ── Background surfaces (base00 / base01) ──────────────────────────────
    // Opaques : pas de verre ni de flou, le fond (l'encre ou le papier) et
    // le panneau, un ton au-dessus.
    readonly property color bgDeep:     _neutral("base00")
    readonly property color bgElevated: _neutral("base01")
    readonly property color bgInput:    _neutral("base01")

    // ── Dividers & overlays ────────────────────────────────────────────────
    // Le filet d'Ajar : le texte à 8 %.
    readonly property color dividerColor: Qt.alpha(textPrimary, 0.08)
    readonly property color hoverOverlay: Qt.alpha(textPrimary, 0.05)
    // Ce qui est retenu (onglet, ligne, lieu) : l'accent à 16 %, sans bordure.
    readonly property color selectedFill: Qt.alpha(accentColor, 0.16)

    // ── Text hierarchy (base05 / base04 / base03) ──────────────────────────
    readonly property color textPrimary:   _neutral("base05")
    readonly property color textSecondary: _neutral("base04")
    readonly property color textDim:       _neutral("base03")
    readonly property color textInactive:  Qt.alpha(textPrimary, 0.32)
    readonly property color textSubtle:    Qt.alpha(textPrimary, 0.2)
    readonly property color textBody:      textPrimary

    // ── Icons & interactive elements ───────────────────────────────────────
    readonly property color iconColor:         textPrimary
    readonly property color placeholderColor:  Qt.alpha(textPrimary, 0.32)
    // Sur un aplat d'accent (bouton d'envoi, interrupteur) : la couleur du fond.
    readonly property color selectedTextColor: bgDeep

    // Canvas notation staff (r,g,b string for use in rgba() calls)
    readonly property string canvasLineRGB: darkMode ? "217,210,197" : "42,37,33"

    // ── Semantic status colors (base16 roles) ─────────────────────────────
    // base08=danger/red, base09=warning/orange, base0a=amber/yellow
    // base0b=success/green, base0c=cyan, base0e=alt-blue, base0f=coral
    readonly property color colorDanger:  _state.palette ? _state.palette.base08 : "#c46a5a"
    readonly property color colorWarning: _state.palette ? _state.palette.base09 : "#c98a4b"
    readonly property color colorAmber:   _state.palette ? _state.palette.base0a : "#c9a95c"
    readonly property color colorSuccess: _state.palette ? _state.palette.base0b : "#8fa876"
    readonly property color colorCyan:    _state.palette ? _state.palette.base0c : "#7fa6a0"
    readonly property color colorAltBlue: _state.palette ? _state.palette.base0e : "#8c9bb5"
    readonly property color colorCoral:   _state.palette ? _state.palette.base0f : "#b57a8a"

    // ── Chart series colors ───────────────────────────────────────────────
    // CPU series → accentColor, RAM → colorSuccess, GPU → colorCoral
    readonly property color colorRam: colorSuccess
    readonly property color colorGpu: colorCoral
    // Disk series — 6 slots cycling through distinct palette roles
    readonly property var diskSeriesColors: [
        _state.palette ? _state.palette.base0e : "#8c9bb5",
        _state.palette ? _state.palette.base09 : "#c98a4b",
        _state.palette ? _state.palette.base0b : "#8fa876",
        _state.palette ? _state.palette.base0f : "#b57a8a",
        _state.palette ? _state.palette.base0a : "#c9a95c",
        _state.palette ? _state.palette.base0c : "#7fa6a0"
    ]

    // ── Theme side-effects (GTK color-scheme) ──────────────────────────────
    // Le fond d'écran ne suit plus le thème : c'est une vidéo choisie à part
    // (WallpaperSource, commande `wallpaper`).
    property Process gtkProcess: Process {
        property string pendingScheme: ""
        command: ["gsettings", "set", "org.gnome.desktop.interface",
                  "color-scheme", pendingScheme]
    }

    function toggleTheme() {
        var newMode = darkMode ? "light" : "dark"
        gtkProcess.pendingScheme = darkMode ? "prefer-light" : "prefer-dark"
        gtkProcess.running = true
        // Delegate mode change to the daemon — it re-renders all templates,
        // fires live-reload signals, and writes the updated state.json which
        // this FileView will pick up automatically.
        themeRoot._anna("mode", ["mode", newMode])
    }

    // ── Preset palette ─────────────────────────────────────────────────────
    readonly property var presets: [
        "#d4a35f",  // cuivre d'Ajar (default)
        "#8fa876",  // sauge
        "#7fa6a0",  // vert-de-gris
        "#c46a5a",  // terre cuite
        "#8c9bb5"   // ardoise
    ]

    // ── IPC with the anna daemon ───────────────────────────────────────────
    // Commands go through the `anna` CLI client. state.json is updated by the
    // daemon on completion and picked up by _stateFile's watchChanges.

    // Une commande `anna` à la fois, dans l'ordre. Lancer un Process déjà en
    // cours ne fait rien : sans file, la dernière couleur d'un glisser (ou d'un
    // pas d'arc-en-ciel) était perdue dès que la précédente n'avait pas fini.
    // Chaque commande occupe un « slot » ("accent", "mode", "palette:base08"…) :
    // une nouvelle valeur remplace celle qui attendait encore dans le même slot,
    // le daemon n'applique donc que la plus récente.
    property var _annaQueue: []

    property Process annaProcess: Process {
        onExited: Qt.callLater(themeRoot._runNextAnna) // qmllint disable signal-handler-parameters
    }

    function _anna(slot, args) {
        var q = themeRoot._annaQueue.filter(function (e) { return e.slot !== slot })
        q.push({ slot: slot, args: args })
        themeRoot._annaQueue = q
        if (!annaProcess.running)
            themeRoot._runNextAnna()
    }

    function _runNextAnna() {
        if (annaProcess.running || themeRoot._annaQueue.length === 0)
            return
        var next = themeRoot._annaQueue[0]
        themeRoot._annaQueue = themeRoot._annaQueue.slice(1)
        annaProcess.command = ["anna"].concat(next.args)
        annaProcess.running = true
    }

    // ── Palette accessor ───────────────────────────────────────────────────
    /// Raw base16 palette for the active mode (reactive: updates when _state changes).
    readonly property var palette: _state.palette || {}

    // ── Setters ────────────────────────────────────────────────────────────
    function setAccentColor(str) {
        // Optimistic update: apply instantly to accentHex for immediate
        // visual feedback; the daemon confirms by writing state.json.
        themeRoot._state = Object.assign({}, themeRoot._state, { accent: str })
        themeRoot._anna("accent", ["set", str])
    }

    function setPaletteColor(key, colorStr) {
        // Optimistic update: patch the in-memory palette immediately.
        var newPalette = Object.assign({}, themeRoot._state.palette)
        newPalette[key] = colorStr
        themeRoot._state = Object.assign({}, themeRoot._state, { palette: newPalette })
        // Mode explicite : un changement de mode encore en file ne doit pas
        // rediriger la couleur vers l'autre palette.
        themeRoot._anna("palette:" + key,
                        ["palette-color", key, colorStr, themeRoot._state.mode])
    }

    // Pas de mise à jour optimiste : les valeurs par défaut dépendent du mode
    // (palette claire ou sombre), le daemon les connaît, et state.json revient
    // par _stateFile dès qu'il a fini.
    function resetToDefaults() {
        // Le reset écrase accent et palette : les valeurs en attente n'ont plus lieu d'être.
        themeRoot._annaQueue = themeRoot._annaQueue.filter(function (e) {
            return e.slot === "mode"
        })
        themeRoot._anna("reset", ["reset"])
    }
}
