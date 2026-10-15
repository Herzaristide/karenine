pragma Singleton
import QtQuick
import Quickshell

// Les widgets flottants : lesquels sont ouverts, et où. Plus de barre ni de
// panneaux pour les ouvrir — c'est anna qui le fait (outil MCP `widget` du
// pilote, cf. anna/src/claude/desk.rs), par la FIFO du shell :
//
//   echo "widget:stats"            > /tmp/qs-panel.fifo   → bascule
//   echo "widget:musique:ouvrir"   > /tmp/qs-panel.fifo
//   echo "widget:tout:fermer"      > /tmp/qs-panel.fifo
//
// Les noms sont ceux de `names`, en français comme les outils du pilote.
// « reglages » et « sessions » ne sont pas des cartes flottantes : ils
// ouvrent la fenêtre de réglages et le dock IA, qui gardent leur forme.
Singleton {
    id: widgets

    readonly property var names: ["stats", "musique", "metronome", "son", "camera", "reglages", "sessions"]

    // Le titre de chaque carte flottante.
    readonly property var titles: ({
        stats: "Système",
        musique: "Musique",
        metronome: "Métronome",
        son: "Son",
        camera: "Contrôle gestuel"
    })

    // { nom: true } pour chaque widget ouvert. Réaffecté en entier à chaque
    // changement pour que les liaisons suivent.
    property var opened: ({})
    // { nom: { x, y } } : la dernière place de chaque carte, gardée tant que
    // le shell tourne.
    property var positions: ({})

    function isOpen(name) {
        if (name === "reglages")
            return Theme.settingsOpen;
        return !!widgets.opened[name];
    }

    function _set(name, on) {
        if (name === "reglages") {
            Theme.settingsOpen = on;
            return;
        }
        var o = Object.assign({}, widgets.opened);
        if (on)
            o[name] = true;
        else
            delete o[name];
        widgets.opened = o;
    }

    // action : "ouvrir", "fermer" ou "basculer" (le défaut). « tout » ne
    // sait que se fermer. Renvoie false pour un nom inconnu.
    function apply(name, action) {
        if (name === "tout") {
            if (action === "fermer" || action === "basculer" || !action)
                widgets.closeAll();
            return true;
        }
        if (widgets.names.indexOf(name) < 0)
            return false;
        var on = action === "ouvrir" ? true
               : action === "fermer" ? false
               : !widgets.isOpen(name);
        widgets._set(name, on);
        return true;
    }

    function closeAll() {
        widgets.opened = ({});
        Theme.settingsOpen = false;
    }

    // Où poser une carte de cette taille sur un écran de cette taille : là où
    // on l'a laissée, sinon à sa place par défaut — les grandes en ligne
    // depuis la gauche, le son et les gestes dans le coin droit. Toujours
    // ramenée dans l'écran (il a pu changer depuis).
    readonly property var defaults: ({
        stats: { x: 24, y: 24 },
        musique: { x: 372, y: 24 },
        metronome: { x: 740, y: 24 },
        son: { x: -24, y: 24 },
        camera: { x: -24, y: 260 }
    })

    function position(name, w, h, screenW, screenH) {
        var p = widgets.positions[name] || widgets.defaults[name] || { x: 24, y: 24 };
        // Un x négatif se compte depuis le bord droit.
        var x = p.x < 0 ? screenW - w + p.x : p.x;
        return {
            x: Math.max(0, Math.min(x, screenW - w)),
            y: Math.max(0, Math.min(p.y, screenH - h))
        };
    }

    function move(name, x, y) {
        var p = Object.assign({}, widgets.positions);
        p[name] = { x: Math.round(x), y: Math.round(y) };
        widgets.positions = p;
    }
}
