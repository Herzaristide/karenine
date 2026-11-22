pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "../services"

// Le géoïde du bureau vide : les pays en trames de points, dans l'accent,
// sur une sphère aux pôles élargis qui tourne autour de son axe
// (shaders/globe.frag). La hauteur suit Mercator : les hautes latitudes
// s'agrandissent. La face cachée se voit à travers les mers, dans l'ombre.
// Les frontières ne sont pas tracées mais restent connues : chaque point
// sait à quel pays il appartient.
//
// Il n'apparaît que quand le workspace actif de son écran n'a aucune
// fenêtre, et s'efface dès qu'une s'ouvre. Il tourne seul, lentement ; on
// le saisit pour le faire tourner (horizontalement seulement), il garde
// l'élan au lâcher puis reprend sa dérive. Le pays sous la souris s'avive
// et se nomme ; un clic le choisit : ses points se remplissent, le globe
// s'arrête et l'amène au milieu. Rien n'est calculé quand il est caché.
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
    // Les latitudes montrées, en degrés. En Mercator, les hautes latitudes
    // mangent vite la hauteur : chaque degré gagné vers les pôles en ôte aux
    // pays (avec stretch, il faudrait alors les aplatir pour garder la même
    // taille). 56° S laisse l'Antarctique hors champ, 76° N garde toute la
    // Scandinavie ; les deux bouts s'effacent en fondu.
    readonly property real latMin: -56
    readonly property real latMax: 76
    function merc(deg) {
        var phi = deg * Math.PI / 180;
        return Math.log(Math.tan(Math.PI / 4 + phi / 2));
    }
    readonly property real vMin: globe.merc(globe.latMin)
    readonly property real vMax: globe.merc(globe.latMax)

    // La forme : à 1 une sphère ; moins, les calottes restent larges au
    // lieu de se refermer (0,8 : la ligne du pôle garde près de la moitié
    // de la largeur de l'équateur).
    readonly property real polar: 0.8
    // L'allongement, au centre : un radian de longitude prend `stretch` fois
    // plus de place qu'une unité de Mercator en hauteur. À 1, les pays
    // garderaient leurs vraies proportions à l'équateur ; plus, ils
    // s'aplatissent.
    readonly property real stretch: 1.4
    // La courbure des bords : à 1, chaque ligne s'enroule comme sur une
    // sphère (les bords très tassés) ; moins, les bords se tassent moins et
    // le géoïde s'élargit, sans rien changer au centre (les proportions des
    // pays y restent celles que donne stretch). À 0, une carte plate.
    readonly property real curve: 0.7
    // La largeur de la forme pour un radian d'échelle au centre :
    // sin(curve·π/2)/curve (1 pour une sphère, π/2 pour une carte plate).
    readonly property real widen: Math.sin(Math.max(globe.curve, 1e-3) * Math.PI / 2)
                                  / Math.max(globe.curve, 1e-3)

    // La place, celle des fenêtres (cf. GlobeLayer). Quand le panneau
    // s'ouvre, Hyprland la rétrécit d'un coup ; le géoïde, lui, suit en
    // douceur, comme les fenêtres qui glissent. Le bord gauche ne bouge pas
    // (le panneau est à droite, la barre en bas) : le centre est compté
    // depuis le coin haut-gauche, et il glisse avec la largeur.
    //
    // La couche peut renaître à zéro puis prendre sa taille : une taille
    // nulle est ignorée, et tant qu'il apparaît (ou n'a jamais eu de place)
    // la nouvelle est prise d'un coup. Seul un géoïde déjà là glisse.
    property real areaW: 0
    property real areaH: 0
    onWidthChanged: globe._resize()
    onHeightChanged: globe._resize()
    function _resize() {
        if (globe.width <= 0 || globe.height <= 0)
            return;
        if (globe.appear < 1 || globe.areaW <= 0 || globe.areaH <= 0) {
            slide.stop();
            globe.areaW = globe.width;
            globe.areaH = globe.height;
            return;
        }
        slide.stop();
        slideW.from = globe.areaW;
        slideW.to = globe.width;
        slideH.from = globe.areaH;
        slideH.to = globe.height;
        slide.start();
    }
    ParallelAnimation {
        id: slide
        NumberAnimation { id: slideW; target: globe; property: "areaW"; duration: 380; easing.type: Easing.OutCubic }
        NumberAnimation { id: slideH; target: globe; property: "areaH"; duration: 380; easing.type: Easing.OutCubic }
    }
    readonly property real centerX: globe.areaW / 2
    readonly property real centerY: globe.areaH / 2

    // La forme tient dans 88 % de la hauteur (le nom du pays dessous) et
    // 92 % de la largeur, à l'échelle : ses proportions ne changent pas.
    readonly property real halfH: Math.min(globe.areaH * 0.44,
                                           globe.areaW * 0.46 * ((globe.vMax - globe.vMin) / 2)
                                           / (globe.stretch * globe.widen))
    // Pixels par unité de Mercator, et par radian de longitude au centre ;
    // la demi-largeur de l'équateur, qui couvre 90°, en découle.
    readonly property real unitY: globe.halfH / ((globe.vMax - globe.vMin) / 2)
    readonly property real unitX: globe.stretch * globe.unitY
    readonly property real halfW: globe.unitX * globe.widen

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
        var k = Math.max(globe.curve, 1e-3);
        var lon = Math.asin(nx * Math.sin(k * Math.PI / 2)) / k - globe.yaw;
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

    // L'apparition, de 0 à 1 : un fondu, et le géoïde qui grandit un peu
    // depuis son centre (de 92 % à sa taille) ; l'inverse quand il s'en va.
    property real appear: globe.empty ? 1 : 0
    Behavior on appear {
        NumberAnimation { duration: 460; easing.type: Easing.OutCubic }
    }
    // À la fin de l'apparition, la place a pu changer entre-temps.
    onAppearChanged: if (globe.appear >= 1) globe._resize()
    opacity: globe.appear
    visible: opacity > 0
    // Pour la couche qui le porte : là dès qu'il doit paraître, jusqu'à la
    // fin de son fondu.
    readonly property bool shown: globe.empty || globe.appear > 0
    transform: Scale {
        origin.x: globe.centerX
        origin.y: globe.centerY
        xScale: 0.92 + 0.08 * globe.appear
        yScale: 0.92 + 0.08 * globe.appear
    }
    onVisibleChanged: if (!visible) globe.hoverId = 0

    // Il tourne seul tant qu'aucun pays n'est choisi : un pays choisi
    // arrête la dérive et l'élan, le temps qu'on le regarde.
    FrameAnimation {
        running: globe.visible && !hand.pressed && globe.selectId === 0 && !focusAnim.running
        onTriggered: {
            var dt = Math.min(frameTime, 0.1);
            // L'élan s'amortit, la dérive reprend la main.
            globe.spin *= Math.exp(-dt * 2.2);
            globe.yaw += (globe.drift + globe.spin) * dt;
        }
    }

    // La carte défile sous une souris immobile : le pays survolé suit.
    onYawChanged: if (hand.containsMouse) globe.hoverId = globe.countryAt(hand.mouseX, hand.mouseY)

    // Le pays choisi vient au milieu : on tourne jusqu'à son centre
    // (countries.json), par le plus court chemin.
    NumberAnimation {
        id: focusAnim
        target: globe
        property: "yaw"
        duration: 900
        easing.type: Easing.InOutCubic
    }

    function focusOn(id) {
        if (id <= 0 || !globe._map || !globe._map.centers)
            return;
        var lon = globe._map.centers[id - 1][0] * Math.PI / 180;
        // Au milieu de l'écran, l'angle vaut 0 : lon + yaw = 0.
        var d = -lon - globe.yaw;
        d -= 2 * Math.PI * Math.round(d / (2 * Math.PI));
        focusAnim.stop();
        focusAnim.from = globe.yaw;
        focusAnim.to = globe.yaw + d;
        focusAnim.start();
    }

    function select(id) {
        globe.spin = 0;
        if (id === 0 || id === globe.selectId) {
            globe.selectId = 0;
            return;
        }
        globe.selectId = id;
        globe.focusOn(id);
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
        property real curve: globe.curve
        property real vMin: globe.vMin
        property real vMax: globe.vMax
        property real yaw: globe.yaw
        property real unitX: globe.unitX
        property real unitY: globe.unitY
        // L'écart de la trame de points, au centre : assez fin pour qu'on
        // lise le profil des petits pays (à 8, la France n'était qu'un pavé).
        property real dotPx: 5
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

    // ── Le cartouche ─────────────────────────────────────────────
    // En bas à gauche de la place : le nom du pays survolé, ou à défaut du
    // pays choisi ; pour le pays choisi, ce qu'on lit et ce qu'on écoute
    // chez lui (services/World.qml). Les lignes s'ouvrent au clic.
    readonly property var trendsEntry: globe.selectedCode ? World.trends[globe.selectedCode] : undefined
    readonly property var musicEntry: globe.selectedCode ? World.music[globe.selectedCode] : undefined
    readonly property bool showDetails: globe.selectId > 0
                                        && (globe.hoverId === 0 || globe.hoverId === globe.selectId)

    onSelectIdChanged: {
        if (globe.selectId > 0 && globe._map)
            World.fetch(globe.selectedCode, globe._map.en[globe.selectId - 1] || "");
    }

    component Heading: Text {
        color: Theme.textSecondary
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.Medium
        font.letterSpacing: 1.5
        font.capitalization: Font.AllUppercase
    }

    component Note: Text {
        width: card.width
        color: Theme.textDim
        font.family: "Inter"
        font.pixelSize: 12
        wrapMode: Text.WordWrap
    }

    // Une ligne : un titre, ce qui le précise en plus pâle, un lien.
    component Line: Item {
        id: line
        property string main
        property string aside
        property string url
        width: card.width
        height: lineText.implicitHeight + 4

        Text {
            id: lineText
            width: parent.width
            textFormat: Text.StyledText
            text: line.main.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                  + (line.aside ? "  <font color=\"" + Theme.textDim + "\">"
                     + line.aside.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</font>" : "")
            color: lineMouse.containsMouse ? Theme.accentColor : Theme.textPrimary
            font.family: "Inter"
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        MouseArea {
            id: lineMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: line.url !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: Qt.openUrlExternally(line.url)
        }
    }

    Column {
        id: card
        z: 2
        x: 0
        anchors.bottom: parent.bottom
        width: Math.min(340, globe.width * 0.3)
        spacing: 6
        visible: globe.shownId > 0

        Text {
            width: card.width
            text: globe.shownName
            color: Theme.accentColor
            opacity: globe.hoverId && globe.hoverId !== globe.selectId ? 0.75 : 1
            font.family: "Inter"
            font.pixelSize: 18
            font.weight: Font.Medium
            font.letterSpacing: 2
            font.capitalization: Font.AllUppercase
            wrapMode: Text.WordWrap
        }

        Note {
            visible: !globe.showDetails
            text: I18n.tr("globe.hint")
        }

        Item { width: 1; height: 6; visible: globe.showDetails }

        // Les tendances
        Heading {
            visible: globe.showDetails
            text: I18n.tr("globe.trends")
        }
        Note {
            visible: globe.showDetails && (!globe.trendsEntry || globe.trendsEntry.state !== "ok"
                                           || globe.trendsEntry.data.articles.length === 0)
            text: !globe.trendsEntry || globe.trendsEntry.state === "loading" ? I18n.tr("globe.loading")
                  : globe.trendsEntry.state === "error" ? globe.trendsEntry.data.error
                  : I18n.tr("globe.nothing")
        }
        Repeater {
            model: globe.showDetails && globe.trendsEntry && globe.trendsEntry.state === "ok"
                   ? globe.trendsEntry.data.articles : []
            delegate: Line {
                required property var modelData
                main: modelData.title
                aside: modelData.lang
                url: modelData.url
            }
        }

        Item { width: 1; height: 6; visible: globe.showDetails }

        // La musique
        Heading {
            visible: globe.showDetails
            text: I18n.tr("globe.music")
        }
        Note {
            visible: globe.showDetails && (!globe.musicEntry || globe.musicEntry.state !== "ok"
                                           || globe.musicEntry.data.tracks.length === 0)
            text: {
                var e = globe.musicEntry;
                if (!e || e.state === "loading")
                    return I18n.tr("globe.loading");
                if (e.state === "error")
                    return e.data.error === "no-key" ? I18n.tr("globe.noKey")
                         : e.data.error === "bad-key" ? I18n.tr("globe.badKey")
                         : e.data.error;
                return I18n.tr("globe.nothing");
            }
        }
        Repeater {
            model: globe.showDetails && globe.musicEntry && globe.musicEntry.state === "ok"
                   ? globe.musicEntry.data.tracks : []
            delegate: Line {
                required property var modelData
                main: modelData.title
                aside: modelData.artist
                url: modelData.url
            }
        }
    }

    // La main : glisser fait tourner (un pixel vaut un pixel de carte, au
    // centre), relâcher laisse l'élan du dernier geste ; le mouvement
    // vertical est ignoré. Un clic sans glisser choisit le pays : il se
    // s'allume, le globe s'arrête et l'amène au milieu. Un second
    // clic sur lui, ou un clic dans le vide, le relâche et la dérive reprend.
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
            focusAnim.stop();
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
                globe.select(globe.countryAt(mouse.x, mouse.y));
                return;
            }
            // Un pays choisi tient le globe : pas d'élan, il reste où on
            // l'a laissé. Sinon, un geste arrêté avant de lâcher ne lance rien.
            var still = globe.selectId !== 0 || Date.now() - lastT > 80;
            globe.spin = still ? 0 : Math.max(-6, Math.min(6, velocity - globe.drift));
        }
    }
}
