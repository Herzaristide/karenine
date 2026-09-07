import QtQuick
import Quickshell

// Source « paramètres » : il n'y a rien à indexer sur NixOS, la configuration
// est déclarative. Ce qu'on rend cherchable, ce sont les réglages que le shell
// pilote déjà. Chaque entrée déclare son `control`, ce qui dit à la carte quels
// boutons afficher. Ajouter un réglage = une entrée dans `entries` (+ un cas
// dans `activate` s'il a des actions inédites).
QtObject {
    id: src

    readonly property string type:  "setting"
    readonly property string label: "Paramètres"
    readonly property int    limit: 4

    signal produced(int seq, var items)

    readonly property var entries: [
        {
            key: "volume", title: "Volume", control: "volume",
            keywords: "volume son audio muet mute sound haut-parleur"
        },
        {
            key: "theme", title: "Thème", control: "toggle",
            keywords: "theme thème sombre clair dark light mode apparence"
        },
        {
            key: "accent", title: "Couleur d'accent", control: "action",
            keywords: "accent couleur color palette thème"
        },
        {
            key: "screenshot", title: "Capture d'écran", control: "shot",
            keywords: "capture screenshot écran image grim"
        }
    ]

    function _subtitle(key) {
        switch (key) {
        case "volume":     return Audio.muted ? "coupé" : Audio.percent + " %";
        case "theme":      return Theme.darkMode ? "sombre" : "clair";
        case "accent":     return Theme.accentHex;
        case "screenshot": return "région ou écran entier";
        }
        return "";
    }

    function search(query, seq) {
        var out = [];

        for (var i = 0; i < src.entries.length; i++) {
            var e = src.entries[i];
            var score = Fuzzy.best(query, [e.title, e.keywords]);
            if (score <= 0)
                continue;

            out.push({
                type:     src.type,
                id:       "setting:" + e.key,
                title:    e.title,
                subtitle: src._subtitle(e.key),
                meta:     "",
                tone:     Theme.colorAmber,
                score:    score,
                payload:  { key: e.key, control: e.control }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    function activate(item, actionId) {
        switch (item.payload.key) {
        case "volume":
            if (actionId === "up")    Audio.up();
            if (actionId === "down")  Audio.down();
            if (actionId === "mute")  Audio.toggleMute();
            break;
        case "theme":
            if (actionId === "open" || actionId === "toggle")
                Theme.toggleTheme();
            break;
        case "accent":
            if (actionId === "open")
                Theme.settingsOpen = true;
            break;
        case "screenshot":
            var region = actionId === "full" ? "screen" : "area";
            var path = "/tmp/screenshot-"
                     + Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss") + ".png";
            // Détaché et sans shell : la sélection de région dure le temps que
            // l'utilisateur veut, et le chemin n'a rien à faire échapper.
            Quickshell.execDetached(["grimblast", "copysave", region, path]);
            break;
        }
    }
}
