import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "../services"

// Le géoïde du bureau vide : les pays seuls, chacun d'une nuance de
// l'accent et bordé de sa frontière, sur une sphère aux pôles élargis qui
// tourne autour de son axe (shaders/globe.frag). La hauteur suit Mercator :
// les hautes latitudes s'agrandissent. La face cachée se voit à travers les
// mers, dans l'ombre. Le pays sous la souris s'éclaire et se nomme, un clic le
// garde choisi.
//
// Ils n'apparaissent que quand le workspace actif de leur écran n'a aucune
// fenêtre, et s'effacent dès qu'une s'ouvre. Ils tournent seuls, lentement ;
// on les saisit pour les faire tourner (horizontalement seulement), ils
// gardent l'élan au lâcher puis reprennent leur dérive. Rien n'est calculé
// quand ils sont cachés.
//
// Les cartes viennent de Natural Earth (domaine public) :
// assets/globe/generate.py les refait.
Item {
    id: globe

    // L'écran de la surface, pour trouver son workspace actif.
    property var screen

    readonly property var monitor: globe.screen ? Hyprland.monitorFor(globe.screen) : null
    readonly property var workspace: globe.monitor ? globe.monitor.activeWorkspace : null
    readonly property bool empty: globe.workspace !== null
                                  && globe.workspace.toplevels.values.length === 0

    // ── La forme ─────────────────────────────────────────────────
    // La carte s'arrête à 58° S (l'Antarctique, démesuré en Mercator, reste
    // hors champ) et à 80° N.
    function merc(deg) {
        var phi = deg * Math.PI / 180;
        return Math.log(Math.tan(Math.PI / 4 + phi / 2));
    }
    readonly property real vMin: globe.merc(-58)
    readonly property real vMax: globe.merc(80)

    // La forme : à 1 une sphère ; moins, les calottes restent larges au
    // lieu de se refermer (0,55 : la ligne du pôle garde les deux tiers de
    // la largeur de l'équateur).
    readonly property real polar: 0.55
    // L'allongement, au centre : un radian de longitude prend `stretch` fois
    // plus de place qu'une unité de Mercator en hauteur.
    readonly property real stretch: 2.8

    // La place, celle des fenêtres (cf. GlobeLayer). Quand le panneau
    // s'ouvre, Hyprland la rétrécit d'un coup ; le géoïde, lui, suit en
    // douceur, comme les fenêtres qui glissent. Le bord gauche ne bouge pas
    // (le panneau est à droite, la barre en bas) : le centre est compté
    // depuis le coin haut-gauche, et il glisse avec la largeur.
    property real areaW: globe.width
    property real areaH: globe.height
    // Pas d'animation pour la première taille : la couche naît à zéro.
    property bool _sized: false
    onWidthChanged: if (!globe._sized && globe.width > 0) Qt.callLater(() => globe._sized = true)
    Behavior on areaW {
        enabled: globe._sized && globe.visible
        NumberAnimation { duration: 380; easing.type: Easing.OutCubic }
    }
    Behavior on areaH {
        enabled: globe._sized && globe.visible
        NumberAnimation { duration: 380; easing.type: Easing.OutCubic }
    }
    readonly property real centerX: globe.areaW / 2
    readonly property real centerY: globe.areaH / 2

    // La forme tient dans 80 % de la hauteur (le nom du pays dessous) et
    // 92 % de la largeur, à l'échelle : ses proportions ne changent pas.
    readonly property real halfH: Math.min(globe.areaH * 0.40,
                                           globe.areaW * 0.46 * ((globe.vMax - globe.vMin) / 2) / globe.stretch)
    // Pixels par unité de Mercator, et par radian de longitude au centre
    // (la demi-largeur de l'équateur couvre 90° : sin a ≈ a au centre).
    readonly property real unitY: globe.halfH / ((globe.vMax - globe.vMin) / 2)
    readonly property real halfW: globe.stretch * globe.unitY
    readonly property real unitX: globe.halfW

    // La rotation autour de l'axe vertical, seule libre.
    property real yaw: 0.3

    // La dérive au repos (rad/s) et l'élan laissé par la main.
    readonly property real drift: 0.05
    property real spin: 0

    // ── Les pays ─────────────────────────────────────────────────
    // Numéros de la carte (1…n), 0 : aucun.
    property int hoverId: 0
    property int selectId: 0
    readonly property int shownId: globe.hoverId || globe.selectId
    readonly property string shownName: globe.nameOf(globe.shownId)
    // Le code ISO du pays choisi, pour y accrocher des infos plus tard.
    readonly property string selectedCode: globe.selectId > 0 && globe._map
                                           ? globe._map.codes[globe.selectId - 1] : ""

    property var _map: null

    FileView {
        path: Qt.resolvedUrl("../assets/globe/countries.json").toString().replace(/^file:\/\//, "")
        printErrors: true
        onLoaded: {
            try {
                globe._map = JSON.parse(text());
            } catch (e) {
                console.warn("Globe : countries.json illisible", e);
            }
        }
    }

    function nameOf(id) {
        if (id <= 0 || !globe._map)
            return "";
        var names = I18n.lang === "fr" ? globe._map.fr : globe._map.en;
        return names[id - 1] || "";
    }

    // Le pays sous un point de l'élément, par le même chemin que le shader :
    // la largeur de la ligne, l'angle sur la sphère, la hauteur Mercator, la
    // latitude, puis la table en plages de countries.json.
    function countryAt(x, y) {
        var m = globe._map;
        if (!m)
            return 0;
        var ny = (globe.centerY - y) / globe.halfH;
        if (Math.abs(ny) > 1)
            return 0;
        var row = Math.sqrt(Math.max(1 - globe.polar * ny * ny, 1e-4));
        var nx = (x - globe.centerX) / (globe.halfW * row);
        if (Math.abs(nx) > 1)
            return 0;
        var lon = Math.asin(nx) - globe.yaw;
        var v = globe.vMin + (globe.vMax - globe.vMin) * (0.5 + 0.5 * ny);
        var lat = Math.atan(Math.sinh(v));
        var u = lon / (2 * Math.PI) + 0.5;
        u -= Math.floor(u);
        var tx = Math.min(m.w - 1, Math.floor(u * m.w));
        var ty = Math.min(m.h - 1, Math.max(0, Math.floor((0.5 - lat / Math.PI) * m.h)));
        var row = m.rows[ty];
        for (var i = 0, acc = 0; i < row.length; i += 2) {
            acc += row[i + 1];
            if (tx < acc)
                return row[i];
        }
        return 0;
    }

    opacity: globe.empty ? 1 : 0
    visible: opacity > 0
    // Pour la couche qui le porte : là dès qu'il doit paraître, jusqu'à la
    // fin de son fondu.
    readonly property bool shown: globe.empty || globe.opacity > 0
    Behavior on opacity {
        NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
    }
    onVisibleChanged: if (!visible) globe.hoverId = 0

    FrameAnimation {
        running: globe.visible && !hand.pressed
        onTriggered: {
            var dt = Math.min(frameTime, 0.1);
            // L'élan s'amortit, la dérive reprend la main.
            globe.spin *= Math.exp(-dt * 2.2);
            globe.yaw += (globe.drift + globe.spin) * dt;
            // La carte défile sous une souris immobile : le pays survolé suit.
            if (hand.containsMouse)
                globe.hoverId = globe.countryAt(hand.mouseX, hand.mouseY);
        }
    }

    ShaderEffect {
        id: map
        // Le rectangle de la carte, pas tout l'écran : le shader ne paie que
        // ces pixels-là. Centré comme l'élément, les calculs du survol
        // (countryAt) restent valables tels quels.
        width: Math.ceil(globe.halfW * 2) + 4
        height: Math.ceil(globe.halfH * 2) + 4
        x: globe.centerX - width / 2
        y: globe.centerY - height / 2

        property real itemW: map.width
        property real itemH: map.height
        property real halfW: globe.halfW
        property real halfH: globe.halfH
        property real polar: globe.polar
        property real vMin: globe.vMin
        property real vMax: globe.vMax
        property real yaw: globe.yaw
        // La face cachée, vue à travers les mers : dans l'ombre.
        property real shadow: 0.28
        property real hoverId: globe.hoverId
        property real selectId: globe.selectId
        property color accent: Theme.accentColor
        property var countries: Image {
            source: Qt.resolvedUrl("../assets/globe/countries.png")
            // Des numéros, pas des couleurs : jamais interpolés.
            smooth: false
            mipmap: false
            visible: false
        }

        fragmentShader: Qt.resolvedUrl("../shaders/globe.frag.qsb")
    }

    // Le nom du pays survolé, ou à défaut du pays choisi, sous la carte.
    Text {
        x: globe.centerX - width / 2
        y: globe.centerY + globe.halfH + 24
        text: globe.shownName
        color: Theme.accentColor
        opacity: globe.hoverId && globe.hoverId !== globe.selectId ? 0.75 : 1
        font.family: "Inter"
        font.pixelSize: 15
        font.weight: Font.Medium
        font.letterSpacing: 2
        font.capitalization: Font.AllUppercase
    }

    // La main : glisser fait tourner (un pixel vaut un pixel de carte, au
    // centre), relâcher laisse l'élan du dernier geste ; le mouvement
    // vertical est ignoré. Un clic sans glisser choisit le pays (ou le
    // relâche), un clic dans le vide efface le choix.
    MouseArea {
        id: hand
        anchors.fill: parent
        enabled: globe.visible
        hoverEnabled: true
        cursorShape: pressed && moved ? Qt.ClosedHandCursor
                     : globe.hoverId ? Qt.PointingHandCursor : Qt.ArrowCursor

        property real pressX: 0
        property real lastX: 0
        property double lastT: 0
        property real velocity: 0
        property bool moved: false

        onExited: globe.hoverId = 0
        onPressed: (mouse) => {
            pressX = mouse.x;
            lastX = mouse.x;
            lastT = Date.now();
            velocity = 0;
            moved = false;
            globe.spin = 0;
        }
        onPositionChanged: (mouse) => {
            if (!pressed) {
                globe.hoverId = globe.countryAt(mouse.x, mouse.y);
                return;
            }
            if (Math.abs(mouse.x - pressX) > 4)
                moved = true;
            var now = Date.now();
            var dt = Math.max((now - lastT) / 1000, 0.001);
            var d = (mouse.x - lastX) / globe.unitX;
            globe.yaw += d;
            // Vitesse lissée : le dernier geste compte, pas un sursaut isolé.
            velocity = 0.6 * velocity + 0.4 * (d / dt);
            lastX = mouse.x;
            lastT = now;
            globe.hoverId = globe.countryAt(mouse.x, mouse.y);
        }
        onReleased: (mouse) => {
            if (!moved) {
                var id = globe.countryAt(mouse.x, mouse.y);
                globe.selectId = id === globe.selectId ? 0 : id;
                return;
            }
            // Un geste arrêté avant de lâcher ne lance rien.
            var still = Date.now() - lastT > 80;
            globe.spin = still ? 0 : Math.max(-6, Math.min(6, velocity - globe.drift));
        }
    }
}
