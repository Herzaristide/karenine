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
    readonly property string label: I18n.tr("settings.title")
    readonly property int    limit: 5

    signal produced(int seq, var items)

    // `adjust` marque les réglages qui portent une valeur réglable sur place :
    // sur ceux-là, les flèches haut/bas du dock modifient au lieu de naviguer.
    // C'est la source qui le déclare, le dock n'a pas à connaître les réglages
    // un par un.
    readonly property var entries: [
        {
            key: "volume", title: I18n.tr("setting.volume"), control: "volume", adjust: true,
            keywords: "volume son audio muet mute sound haut-parleur speaker"
        },
        {
            key: "theme", title: I18n.tr("setting.theme"), control: "toggle", adjust: false,
            keywords: "theme thème sombre clair dark light mode apparence"
        },
        {
            key: "accent", title: I18n.tr("setting.accent"), control: "action", adjust: true,
            keywords: "accent couleur color colour palette thème theme"
        },
        {
            key: "screenshot", title: I18n.tr("setting.screenshot"), control: "shot", adjust: false,
            keywords: "capture screenshot écran image grim"
        },
        {
            key: "screen", title: I18n.tr("setting.screen"), control: "screens", adjust: false,
            keywords: "écran ecran moniteur affichage display screen monitor interface barre bar"
        },
        {
            key: "language", title: I18n.tr("settings.language"), control: "screens", adjust: false,
            keywords: "langue language langage idioma sprache english anglais français french traduction translation"
        }
    ]

    function _subtitle(key) {
        switch (key) {
        case "volume":     return Audio.muted ? I18n.tr("volume.muted") : I18n.tr("common.percent", { n: Audio.percent });
        case "theme":      return Theme.darkMode ? I18n.tr("theme.dark") : I18n.tr("theme.light");
        case "accent":     return Theme.accentHex;
        case "screenshot": return I18n.tr("setting.screenshot.subtitle");
        case "screen":     return Display.screenKey(Display.primary);
        case "language":   return (I18n.available.find(l => l.code === I18n.lang) || { name: I18n.lang }).name;
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
                payload:  { key: e.key, control: e.control, adjust: e.adjust }
            });
        }

        out.sort(function (a, b) { return b.score - a.score; });
        src.produced(seq, out.slice(0, src.limit));
    }

    // L'accent est une couleur libre, pas une liste de choix : ce que les
    // flèches peuvent parcourir, c'est sa teinte. Saturation et luminosité ne
    // bougent pas, donc on tourne autour de la roue sans changer de registre.
    readonly property real accentStep: 1 / 24   // 15° par pression

    function _stepAccent(dir) {
        var c = Qt.color(Theme.accentHex);
        // Un gris n'a pas de teinte — Qt renvoie -1. On repart du rouge, et on
        // lui donne de quoi se voir, sinon la rotation ne produirait rien.
        var h = c.hsvHue < 0 ? 0 : c.hsvHue;
        var s = Math.max(0.35, c.hsvSaturation);
        var v = Math.max(0.35, c.hsvValue);

        h = (h + dir * src.accentStep + 1) % 1;
        // `toString()` d'une couleur opaque donne « #rrggbb », ce qu'attend anna.
        Theme.setAccentColor(Qt.hsva(h, s, v, 1).toString());
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
                Widgets.apply("reglages", "ouvrir");
            else if (actionId === "up")
                src._stepAccent(1);
            else if (actionId === "down")
                src._stepAccent(-1);
            break;
        case "screen":
            // Ouvrir, c'est passer à l'écran suivant ; « Auto » fait partie du tour.
            if (actionId === "open") {
                var keys = [""].concat(Quickshell.screens.map(s => Display.screenKey(s)));
                var at = keys.indexOf(Display.preferred);
                Display.setPreferred(keys[(at + 1) % keys.length]);
            }
            break;

        case "language":
            // Comme l'écran : ouvrir, c'est passer à la langue suivante.
            if (actionId === "open") {
                var langs = I18n.available.map(l => l.code);
                I18n.setLang(langs[(langs.indexOf(I18n.lang) + 1) % langs.length]);
            }
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
