pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../services"

// La barre de conversation : tout ce qui reste de la barre du haut. Une
// pastille en bas au centre, le flocon NixOS à gauche, le champ à droite ;
// ce qu'on y écrit va au pilote (ClaudeLive.pilotAsk), et sa réponse
// s'affiche juste au-dessus.
//
//        ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
//      ░░  › baisse le son                            ░░   le dernier tour,
//      ░░  · volume {"delta":-10}                     ░░   sans cadre, sur un
//      ░░  Volume à 40 %.          (en grand)         ░░   voile flouté
//        ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
//         ✦╭──────────────────────────────────────────╮✦  capsule de verre,
//         ✦│ ❄  Demander à Karénine…             (🎤) │✦  halo irisé quand
//         ✦╰──────────────────────────────────────────╯✦  elle écoute ou pense
//
// Cachée par défaut : elle monte du bord de l'écran quand on dit « Karénine »
// ou qu'on tape Super, et repart une fois la réponse lue. La voix passe par le même
// chemin : dire « Karénine » (ou Super+V, ou un clic sur le micro, à droite)
// change le micro en indicateur d'écoute, la phrase s'écrit dans le champ à mesure qu'anna la
// comprend, une forme d'onde suit la voix, puis la phrase part au pilote.
//
// Le flocon, à gauche, agrandit la capsule vers le haut pour montrer les
// widgets, un onglet à la fois (panels/WidgetHub.qml).
//
// La même barre cherche : ce qu'on tape alimente l'onglet « Recherche » du
// hub, où les résultats (applications, fichiers, réglages, web — le service
// Search, celui de l'ancien dock) forment un quadrillage, le meilleur en bas
// à gauche, près du champ. L'onglet ne s'ouvre pas de lui-même : on y va (flocon, ↑,
// clic). Entrée part toujours au pilote ; sur l'onglet, ↑ entre dans la
// grille, et Entrée ou un clic ouvre alors le résultat retenu.
//
// Le texte est en Inter (installée par la config NixOS), le reste du bureau
// en JetBrains Mono.
PanelWindow { // qmllint disable uncreatable-type
    id: bar

    // Le champ a le clavier : Super l'a appelée (cf. toggle).
    property bool focusRequested: false
    // Super l'a renvoyée : ni le texte, ni une réponse en attente ne la
    // ramènent avant le prochain Super, « Karénine » ou une demande venue
    // d'ailleurs.
    property bool dismissed: false

    readonly property int barH: 52
    readonly property int barW: Math.min(700, (bar.screen ? bar.screen.width : 1280) - 32)
    // Distance au bord de l'écran.
    readonly property int gap: 120

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-conversation"
    // Exclusive le temps d'une demande au clavier : une surface layer ne
    // reçoit les frappes qu'une fois cliquée sinon.
    WlrLayershell.keyboardFocus: bar.focusRequested ? WlrKeyboardFocus.Exclusive
                                                    : WlrKeyboardFocus.OnDemand

    anchors { bottom: true }
    margins { // qmllint disable unqualified unresolved-type
        bottom: bar.gap
    }
    // Cachée la plupart du temps : elle passe par-dessus les fenêtres quand
    // elle vient, plutôt que de leur prendre de la place pour rien.
    exclusiveZone: 0
    // Plus large que la barre : le voile de la réponse s'efface sur les côtés.
    implicitWidth: bar.barW + 240
    implicitHeight: Math.max(480, bar.barH + bar.hubMax + 20)
    color: "transparent"

    mask: Region { // qmllint disable unqualified
        Region { item: bar.shown ? pill : null }
        Region { item: answer.shown && !bar.searching && !bar.dismissed && !Widgets.hubOpen ? flick : null }
    }

    // ── Apparaître, disparaître ──────────────────────────────────
    // La barre n'est là que quand on l'appelle : « Karénine », un tap sur
    // Super (focusRequested), ou tant qu'il se passe quelque chose — une
    // phrase en cours, le pilote qui travaille, une réponse à lire. Elle
    // repart un instant après, le temps qu'une étape enchaîne sur la
    // suivante (la voix qui se tait, le pilote qui prend la main).
    readonly property bool wanted: !bar.dismissed
                                   && (bar.voiceOn || bar.focusRequested || input.activeFocus
                                       || input.text.length > 0 || ClaudeLive.pilotBusy || answer.shown
                                       || Widgets.hubOpen)
    property bool shown: false
    // ── Les widgets ──────────────────────────────────────────────
    // Le flocon (ou anna) agrandit la capsule vers le haut : `expand` va de
    // 0 (fermée) à 1 (ouverte), et la retient tant qu'elle est ouverte. Elle
    // s'ouvre en décélérant, sans rebond ; elle se referme plus vite, les
    // widgets s'effaçant avant que la capsule ne se rétracte (WidgetHub).
    readonly property bool hubOn: Widgets.hubOpen && bar.shown
    property real expand: 0
    // La place que demande l'onglet affiché ; elle glisse d'un onglet à l'autre.
    // La plus grande (l'onglet le plus haut) : la taille des surfaces.
    readonly property int hubMax: 480
    property real hubH: widgetHub.preferredHeight
    Behavior on hubH { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

    onHubOnChanged: {
        // La capsule qui grandit ou rapetisse change sa distance au curseur
        // sans qu'il ait bougé : la mesure repart de là.
        bar.closest = -1;
        if (bar.hubOn) {
            collapse.stop();
            unfold.restart();
        } else {
            unfold.stop();
            collapse.restart();
        }
    }
    NumberAnimation {
        id: unfold
        target: bar
        property: "expand"
        to: 1
        duration: 560
        easing.type: Easing.OutQuint
    }
    NumberAnimation {
        id: collapse
        target: bar
        property: "expand"
        to: 0
        duration: 300
        easing.type: Easing.InOutCubic
    }

    Connections {
        target: Widgets
        // Les résultats cachés, Entrée ne doit plus ouvrir celui qui était retenu.
        function onHubTabChanged() {
            bar.selected = -1;
        }
        function onHubOpenChanged() {
            bar.selected = -1;
            if (Widgets.hubOpen)
                bar.dismissed = false;
            // Fermés avec le clavier dedans : il retourne au champ, sinon la
            // barre garderait le clavier sans rien pour le recevoir.
            else if (widgetHub.activeFocus && bar.focusRequested)
                input.forceActiveFocus();
        }
    }

    // Super : la montrer si elle n'est pas là, la renvoyer si elle l'est,
    // quoi qu'elle contienne.
    function toggle() {
        if (bar.wanted) {
            bar.dismiss();
        } else {
            bar.dismissed = false;
            bar.focusRequested = true;
        }
    }

    // Tout de suite, sans délai : le texte, la recherche et la réponse
    // partent avec elle. Le pilote, lui, continue son travail.
    function dismiss() {
        Widgets.hubOpen = false;
        input.text = "";
        answer.hide();
        bar.selected = -1;
        bar.focusRequested = false;
        input.focus = false;
        bar.dismissed = true;
        hideDelay.stop();
        bar.shown = false;
    }

    // ── La souris qui part ailleurs ──────────────────────────────
    // Ouverte pour écrire, elle se referme quand la souris s'en va. Aller
    // vers elle (pour cliquer un résultat) la garde : seul compte le fait de
    // s'éloigner de plus de `leaveSlack` du point le plus proche atteint.
    // Une surface layer ne voit le curseur que quand il la survole ; ailleurs,
    // sa position se lit chez Hyprland, le temps seulement que la barre
    // attend du texte. Pas pendant le contrôle gestuel : le curseur piloté au
    // doigt bouge sans cesse.
    readonly property int leaveSlack: 60
    readonly property bool pointerInside: pillHover.hovered
    readonly property bool typing: bar.shown && !bar.dismissed && !bar.voiceOn
                                   && !ClaudeLive.pilotBusy
                                   && (bar.focusRequested || input.activeFocus || input.text.length > 0)
    // La plus courte distance du curseur à la barre depuis l'ouverture ;
    // -1 : pas encore mesurée.
    property real closest: -1

    // Un `hyprctl` par mesure : quatre par seconde suffisent pour sentir la
    // souris partir, et aucun tant qu'elle survole la barre (la distance y
    // est nulle).
    Timer {
        interval: 250
        repeat: true
        running: bar.typing && !Gesture.active
        onRunningChanged: bar.closest = -1
        onTriggered: {
            if (bar.pointerInside)
                bar.closest = 0;
            else if (!cursorProbe.running)
                cursorProbe.running = true;
        }
    }

    Process {
        id: cursorProbe
        command: ["hyprctl", "cursorpos"]
        stdout: StdioCollector {
            id: cursorOut
            onStreamFinished: bar.cursorAt(cursorOut.text)
        }
    }

    // `hyprctl cursorpos` : « x, y », en coordonnées logiques, comme celles
    // de l'écran.
    function cursorAt(line) {
        var xy = line.trim().split(",");
        var s = bar.screen;
        if (xy.length !== 2 || !s || !bar.typing)
            return;
        var x = parseFloat(xy[0]);
        var y = parseFloat(xy[1]);

        // Le rectangle de la capsule, widgets ou résultats compris.
        var left = s.x + (s.width - bar.barW) / 2;
        var bottom = s.y + s.height - bar.gap;
        var top = bottom - pill.height;
        var dx = Math.max(left - x, 0, x - (left + bar.barW));
        var dy = Math.max(top - y, 0, y - bottom);
        var d = bar.pointerInside ? 0 : Math.sqrt(dx * dx + dy * dy);

        if (bar.closest < 0 || d < bar.closest)
            bar.closest = d;
        else if (d > bar.closest + bar.leaveSlack)
            bar.dismiss();
    }

    onWantedChanged: {
        if (bar.wanted) {
            hideDelay.stop();
            bar.shown = true;
        } else {
            hideDelay.restart();
        }
    }

    Timer {
        id: hideDelay
        interval: 900
        onTriggered: bar.shown = false
    }

    // ── Le mouvement ─────────────────────────────────────────────
    // Une seule valeur, de 0 (cachée) à 1 (là), porte tout ce qui accompagne
    // la capsule : le verre, son ombre et le halo bougent ensemble. Elle
    // arrive en décélérant, sans rebond, et repart plus vite qu'elle n'est
    // venue.
    property real reveal: 0
    // Le chemin parcouru : court, la capsule glisse plus qu'elle ne surgit.
    readonly property real lift: (1 - bar.reveal) * 18

    onShownChanged: {
        if (bar.shown) {
            revealOut.stop();
            revealIn.restart();
        } else {
            revealIn.stop();
            revealOut.restart();
        }
    }
    NumberAnimation {
        id: revealIn
        target: bar
        property: "reveal"
        to: 1
        duration: 520
        easing.type: Easing.OutQuint
    }
    NumberAnimation {
        id: revealOut
        target: bar
        property: "reveal"
        to: 0
        duration: 200
        easing.type: Easing.InCubic
    }

    // Le niveau de la voix, lissé : le halo, le flocon et l'onde le suivent
    // sans à-coups.
    property real level: ClaudeLive.voicePhase === "listening"
                         ? Math.min(1, ClaudeLive.voiceLevel * 1.5) : 0
    Behavior on level { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    onFocusRequestedChanged: {
        if (focusRequested)
            input.forceActiveFocus();
        // Super à nouveau, champ vide : on la renvoie.
        else if (input.text.length === 0)
            input.focus = false;
    }

    function release() {
        input.text = "";
        answer.hide();
        bar.focusRequested = false;
    }

    function submit() {
        if (bar.resultsShown && bar.selected >= 0) {
            bar.activateResult(Search.results[bar.selected]);
            return;
        }
        var text = input.text.trim();
        if (text.length === 0)
            return;
        bar.launch(text);
        ClaudeLive.pilotAsk(text, false);
        // La réponse s'affiche au-dessus de la capsule fermée.
        Widgets.hubOpen = false;
        input.text = "";
        answer.notice = "";
        answer.show();
        // Le clavier redevient libre : un clic dans le champ le reprend.
        bar.focusRequested = false;
    }

    // ── La recherche ─────────────────────────────────────────────
    // Ce qu'on tape part aussi dans Search, et ses résultats s'affichent dans
    // l'onglet « Recherche » ; tant qu'on cherche, ils passent devant la
    // réponse du pilote.
    readonly property bool searching: Search.active && !bar.voiceOn
    // L'onglet des résultats est celui qu'on voit.
    readonly property bool resultsShown: bar.hubOn && Widgets.hubTab === "recherche"
    // Le résultat retenu au clavier ; -1 : Entrée va au pilote.
    property int selected: -1

    Connections {
        target: Search
        function onResultsChanged() {
            bar.selected = -1;
        }
    }

    function activateResult(item) {
        if (!item)
            return;
        // Un réglage à contrôle se règle sur place : la barre reste. Le
        // thème bascule, l'écran passe au suivant ; un curseur ne s'active pas.
        var control = bar.controlFor(item);
        if (control !== "") {
            if (control === "theme" || control === "screens")
                Search.activate(item, "open");
            return;
        }
        Search.activate(item, "open");
        bar.release();
    }

    // ← → dans le champ : vrai s'ils ont servi (tuile d'à côté, réglage
    // retenu, ou widget d'à côté), faux pour laisser bouger le curseur du
    // texte. Sur une tuile, ils passent à la voisine ; avec Maj, ils règlent
    // le réglage retenu (volume, accent).
    function arrow(dir, shift) {
        if (bar.resultsShown && bar.selected >= 0) {
            if (shift)
                bar.adjustSelected(dir);
            else
                bar.selected = Math.max(0, Math.min(Search.results.length - 1, bar.selected + dir));
            return true;
        }
        if (!Widgets.hubOpen || input.text.length > 0)
            return false;
        widgetHub.step(dir);
        return true;
    }

    function adjustSelected(dir) {
        var item = bar.selected >= 0 ? Search.results[bar.selected] : null;
        if (!item || !item.payload || !item.payload.adjust)
            return false;
        Search.activate(item, dir > 0 ? "up" : "down");
        return true;
    }

    // ↑ ↓ dans la grille, une rangée à la fois (la première en bas, contre
    // le champ) : ↑ y entre par la première tuile, ↓ depuis la première
    // rangée revient au champ (-1). Vrai s'ils ont servi.
    function rowStep(dir) {
        var n = bar.resultsShown && bar.searching ? Search.results.length : 0;
        if (n === 0 || (dir < 0 && bar.selected < 0))
            return false;
        if (dir > 0)
            bar.selected = bar.selected < 0 ? 0 : Math.min(n - 1, bar.selected + bar.gridColumns);
        else
            bar.selected = bar.selected >= bar.gridColumns ? bar.selected - bar.gridColumns : -1;
        return true;
    }

    // Le contrôle qu'une ligne de réglage porte à droite, ou "".
    function controlFor(item) {
        if (!item || item.type !== "setting")
            return "";
        return ({ "volume": "volume", "theme": "theme",
                  "accent": "accent", "screen": "screens" })[item.payload.key] || "";
    }

    // La couleur d'accent à une teinte donnée : saturation et luminosité ne
    // bougent pas, comme quand on la fait tourner aux flèches (SettingSource).
    function accentAt(h) {
        var c = Theme.accentColor;
        return Qt.hsva(h, Math.max(0.35, c.hsvSaturation), Math.max(0.35, c.hsvValue), 1);
    }
    readonly property real accentHue: Theme.accentColor.hsvHue < 0 ? 0 : Theme.accentColor.hsvHue

    // ── Les contrôles des réglages ───────────────────────────────
    // Un curseur fin : la piste, sa partie remplie (ou un arc-en-ciel) et un
    // bouton. Pendant le glisser il suit la souris, puis retombe sur la
    // valeur réelle.
    component BarSlider: Item {
        id: slider

        property real value: 0
        property color knobColor: Theme.accentColor
        // L'arc-en-ciel garde la saturation et la luminosité de l'accent.
        property real saturation: 0.6
        property real brightness: 0.8
        property bool rainbow: false
        property real dragValue: -1
        readonly property real shown: dragValue >= 0 ? dragValue : Math.max(0, Math.min(1, value))
        signal moved(real v)
        signal committed(real v)

        implicitWidth: 170
        implicitHeight: 18

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: slider.rainbow ? 6 : 4
            radius: height / 2
            color: Qt.alpha(Theme.textPrimary, 0.18)
            gradient: slider.rainbow ? hues : null

            Gradient {
                id: hues
                orientation: Gradient.Horizontal
                GradientStop { position: 0 / 6; color: Qt.hsva(0 / 6, slider.saturation, slider.brightness, 1) }
                GradientStop { position: 1 / 6; color: Qt.hsva(1 / 6, slider.saturation, slider.brightness, 1) }
                GradientStop { position: 2 / 6; color: Qt.hsva(2 / 6, slider.saturation, slider.brightness, 1) }
                GradientStop { position: 3 / 6; color: Qt.hsva(3 / 6, slider.saturation, slider.brightness, 1) }
                GradientStop { position: 4 / 6; color: Qt.hsva(4 / 6, slider.saturation, slider.brightness, 1) }
                GradientStop { position: 5 / 6; color: Qt.hsva(5 / 6, slider.saturation, slider.brightness, 1) }
                GradientStop { position: 6 / 6; color: Qt.hsva(0.999, slider.saturation, slider.brightness, 1) }
            }
        }

        Rectangle {
            visible: !slider.rainbow
            anchors.verticalCenter: parent.verticalCenter
            width: track.width * slider.shown
            height: track.height
            radius: track.radius
            color: slider.knobColor
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: slider.shown * (slider.width - width)
            width: 14
            height: 14
            radius: 7
            color: slider.knobColor
            border.width: 2
            border.color: "#ffffff"
            scale: knobMa.pressed ? 1.15 : 1
            Behavior on scale { NumberAnimation { duration: 100 } }
        }

        MouseArea {
            id: knobMa
            anchors.fill: parent
            anchors.topMargin: -8
            anchors.bottomMargin: -8
            preventStealing: true
            cursorShape: Qt.PointingHandCursor

            function follow(mx) {
                slider.dragValue = Math.max(0, Math.min(1, (mx - 7) / Math.max(1, slider.width - 14)));
                slider.moved(slider.dragValue);
            }
            onPressed: (mouse) => follow(mouse.x)
            onPositionChanged: (mouse) => follow(mouse.x)
            onReleased: {
                slider.committed(slider.dragValue);
                slider.dragValue = -1;
            }
        }
    }

    Component {
        id: themeControl
        Row {
            spacing: 8
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.darkMode ? "sombre" : "clair"
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Theme.textSecondary
            }
            Rectangle {
                width: 34
                height: 18
                radius: 9
                color: Theme.darkMode ? bar.hue(0) : Qt.alpha(Theme.textPrimary, 0.22)
                Behavior on color { ColorAnimation { duration: 160 } }
                Rectangle {
                    y: 2
                    x: Theme.darkMode ? parent.width - width - 2 : 2
                    width: 14
                    height: 14
                    radius: 7
                    color: "#ffffff"
                    Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Theme.toggleTheme()
                }
            }
        }
    }

    Component {
        id: volumeControl
        Row {
            spacing: 8
            // Le niveau n'est sondé que tant que la tuile est là.
            Component.onCompleted: Audio.active = true
            Component.onDestruction: Audio.active = false
            BarSlider {
                anchors.verticalCenter: parent.verticalCenter
                // À la largeur d'une tuile de résultat.
                implicitWidth: 64
                value: Audio.level
                knobColor: Audio.muted ? Theme.textDim : bar.hue(0)
                onMoved: (v) => Audio.set(v)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 34
                text: Audio.muted ? "muet" : Audio.percent + " %"
                horizontalAlignment: Text.AlignRight
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Theme.textSecondary
            }
        }
    }

    // L'accent se règle à sa teinte. Il ne part à anna qu'au lâcher : chaque
    // changement d'accent recharge Hyprland.
    Component {
        id: accentControl
        BarSlider {
            id: accentSlider
            implicitWidth: 104
            rainbow: true
            saturation: Math.max(0.35, Theme.accentColor.hsvSaturation)
            brightness: Math.max(0.35, Theme.accentColor.hsvValue)
            value: bar.accentHue
            knobColor: bar.accentAt(accentSlider.shown)
            onCommitted: (v) => Theme.setAccentColor(bar.accentAt(Math.min(v, 0.999)).toString())
        }
    }

    // L'icône d'un résultat, prise au thème ; vide, l'initiale prend le relais.
    function iconFor(item) {
        var p = item.payload || {};
        switch (item.type) {
        case "app":
            return p.entry && p.entry.icon ? Quickshell.iconPath(p.entry.icon, true) : "";
        case "file":
            if (p.isDir)
                return Quickshell.iconPath("folder", true);
            // Une image se montre elle-même.
            if (bar.imageSuffixes.indexOf((p.suffix || "").toLowerCase()) !== -1)
                return "file://" + p.path.split("/").map(encodeURIComponent).join("/");
            return Quickshell.iconPath("text-x-generic", true);
        case "web":
            return DefaultApps.browser ? DefaultApps.browser.icon : "";
        case "setting":
            switch (p.key) {
            case "volume":     return Quickshell.iconPath("audio-volume-high", true);
            case "theme":      return Quickshell.iconPath("preferences-desktop-theme", true);
            case "accent":     return Quickshell.iconPath("preferences-desktop-color", true);
            case "screenshot": return Quickshell.iconPath("applets-screenshooter", true);
            }
        }
        return "";
    }

    readonly property var imageSuffixes: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
    readonly property var typeLabels: ({
        "app": "app", "file": "fichier", "setting": "réglage", "web": "web"
    })

    // ── Le dernier tour du pilote ────────────────────────────────
    // Les éléments depuis la dernière demande : { heard, actions, reply,
    // failed }.
    readonly property var turn: {
        var items = ClaudeLive.pilotItems;
        var start = items.length - 1;
        while (start >= 0 && items[start].kind !== "user")
            start--;
        if (start < 0)
            return null;
        var rest = items.slice(start + 1);
        var said = rest.filter(i => i.kind === "reply" || i.kind === "error");
        return {
            heard: items[start].text,
            actions: rest.filter(i => i.kind === "action").map(i => i.text),
            reply: said.length > 0 ? said[said.length - 1].text : "",
            failed: said.length > 0 && said[said.length - 1].kind === "error"
        };
    }

    readonly property bool voiceOn: ClaudeLive.voicePhase !== "idle"

    // Le pilote a fini sur une question (« quelle fenêtre ? ») : la réponse
    // reste affichée jusqu'à ce qu'on y réponde.
    readonly property bool asking: !ClaudeLive.pilotBusy && bar.turn !== null
                                   && !bar.turn.failed && bar.turn.reply.trim().endsWith("?")

    Connections {
        target: ClaudeLive
        // Une demande partie d'ailleurs (la voix, `anna`) : sa réponse
        // s'affiche ici aussi.
        function onPilotBusyChanged() {
            if (ClaudeLive.pilotBusy) {
                bar.dismissed = false;
                answer.show();
            }
        }
        function onPilotDone() {
            var t = bar.turn;
            answer.hideLater(t ? t.reply.length : 0);
        }
        // Rien entendu, modèle absent… : dit une fois, brièvement.
        function onVoiceErrorChanged() {
            if (ClaudeLive.voiceError.length === 0)
                return;
            answer.notice = "🎙 " + ClaudeLive.voiceError;
            answer.show();
            answer.hideLater(0);
        }
    }

    // ── La réponse, au-dessus de la barre ────────────────────────
    // Pas de cadre : le texte, en grand, sur un voile flouté
    // (veilWindow, plus bas).
    Item {
        id: answer

        property bool shown: false
        // Un message d'anna plutôt qu'un tour du pilote (erreur de la voix).
        property string notice: ""

        function show() {
            hideTimer.stop();
            answer.shown = true;
        }
        function hide() {
            hideTimer.stop();
            answer.shown = false;
            answer.notice = "";
        }
        // Le temps de lire : plus long pour une longue réponse. Une question
        // du pilote reste une minute, le temps d'y répondre.
        function hideLater(length) {
            hideTimer.interval = bar.asking ? 60000 : Math.min(20000, 5000 + 45 * length);
            if (!hover.hovered)
                hideTimer.restart();
        }

        readonly property bool hasContent: notice.length > 0 || bar.turn !== null

        // Le voile déborde largement du texte pour s'effacer en douceur.
        readonly property int fade: 90

        anchors.bottom: pill.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.width
        height: Math.min(column.implicitHeight + fade * 2, bar.height - bar.barH)

        visible: opacity > 0
        opacity: shown && hasContent && !bar.searching && !bar.dismissed && !Widgets.hubOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // Elle monte de la barre en décélérant, comme la capsule.
        transformOrigin: Item.Bottom
        scale: shown ? 1 : 0.98
        Behavior on scale { NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }
        transform: Translate {
            y: answer.shown ? 0 : 12
            Behavior on y { NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }
        }

        Timer {
            id: hideTimer
            onTriggered: answer.hide()
        }

        // Survoler la réponse la retient ; la quitter relance le compte.
        HoverHandler {
            id: hover
            onHoveredChanged: {
                if (hovered)
                    hideTimer.stop();
                else if (answer.shown && !ClaudeLive.pilotBusy)
                    hideTimer.restart();
            }
        }

        // Un clic droit la congédie.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: answer.hide()
        }

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.leftMargin: (answer.width - bar.barW) / 2 + 12
            anchors.rightMargin: anchors.leftMargin
            anchors.topMargin: answer.fade
            anchors.bottomMargin: answer.fade * 0.6
            contentHeight: column.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // La fin de la réponse reste en vue pendant qu'elle s'écrit.
            onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

            Column {
                id: column
                width: flick.width
                spacing: 8

                // Le texte seul, sous son ombre ; les points animés restent
                // dehors, sinon l'ombre se recalculerait à chaque image tant que
                // le pilote réfléchit.
                Column {
                    width: parent.width
                    spacing: 8

                    // Une ombre douce sous les lettres : lisibles même là où le
                    // voile s'éclaircit.
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Theme.darkMode ? "#000000" : "#ffffff"
                        shadowBlur: 0.8
                        shadowOpacity: 0.8
                        shadowHorizontalOffset: 0
                        shadowVerticalOffset: 1
                    }

                    Text {
                        width: parent.width
                        visible: answer.notice.length > 0
                        text: answer.notice
                        wrapMode: Text.Wrap
                        font.family: bar.uiFont
                        font.pixelSize: 18
                        color: Theme.colorDanger
                    }

                    // Ce qui a été demandé — ou compris, pour vérifier la voix.
                    Text {
                        width: parent.width
                        visible: answer.notice.length === 0 && bar.turn !== null
                        text: "› " + (bar.turn ? bar.turn.heard : "")
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        font.family: bar.uiFont
                        font.pixelSize: 12
                        color: Theme.textSecondary
                    }

                    // Ce que le pilote a fait, en une ligne discrète.
                    Text {
                        width: parent.width
                        visible: text.length > 0
                        text: answer.notice.length === 0 && bar.turn
                              ? bar.turn.actions.map(a => "· " + a).join("   ") : ""
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        color: Theme.accentMuted
                    }

                    Text {
                        width: parent.width
                        visible: answer.notice.length === 0 && bar.turn !== null && bar.turn.reply.length > 0
                        text: bar.turn ? bar.turn.reply : ""
                        textFormat: Text.MarkdownText
                        wrapMode: Text.Wrap
                        // Une confirmation courte s'affiche en grand, une longue
                        // réponse un peu moins pour tenir à l'écran.
                        font.family: bar.uiFont
                        font.pixelSize: text.length > 220 ? 17 : 22
                        font.weight: Font.Medium
                        lineHeight: 1.15
                        color: bar.turn && bar.turn.failed ? Theme.colorDanger : Theme.textPrimary
                        linkColor: Theme.accentColor
                        onLinkActivated: (link) => Qt.openUrlExternally(link)
                    }

                    // Le pilote attend une réponse : on la tape dans la barre.
                    Text {
                        visible: bar.asking && answer.notice.length === 0
                        text: "↵ réponds dans la barre"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        color: Theme.accentColor
                    }
                }

                // Le pilote réfléchit : trois points qui respirent.
                Row {
                    visible: answer.notice.length === 0 && ClaudeLive.pilotBusy
                    spacing: 5
                    Repeater {
                        model: 3
                        Rectangle {
                            id: dot
                            required property int index
                            width: 8
                            height: 8
                            radius: 4
                            color: bar.hue(dot.index * 0.14)
                            SequentialAnimation on opacity {
                                running: ClaudeLive.pilotBusy
                                loops: Animation.Infinite
                                PauseAnimation { duration: dot.index * 160 }
                                NumberAnimation { to: 0.25; duration: 420; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Les résultats, dans l'onglet « Recherche » ───────────────
    // La page de l'onglet (WidgetHub.searchPage) : un quadrillage de tuiles,
    // une par résultat — l'icône, le nom, puis où il se trouve. Le meilleur
    // est en bas à gauche, contre les onglets et le champ, pour que ↑ y entre
    // directement. Trois rangées tiennent ; au-delà, la grille défile.
    readonly property int gridColumns: 5

    Component {
        id: searchPage

        Item {
            id: results

            readonly property int tileH: 100

            // Pas de résultat, ou rien d'écrit : ce que l'onglet attend.
            Text {
                anchors.centerIn: parent
                width: parent.width - 40
                visible: grid.count === 0
                text: bar.searching ? "Aucun résultat — Entrée demande à Karénine"
                                    : "Écris dans le champ : applications, fichiers, réglages, web"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                font.family: bar.uiFont
                font.pixelSize: 13
                color: Theme.textSecondary
            }

            GridView {
                id: grid
                anchors.fill: parent

                model: bar.searching ? Search.results : []
                cellWidth: width / bar.gridColumns
                cellHeight: results.tileH
                verticalLayoutDirection: GridView.BottomToTop
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                currentIndex: bar.selected
                highlightFollowsCurrentItem: false
                onCurrentIndexChanged: {
                    if (currentIndex >= 0)
                        positionViewAtIndex(currentIndex, GridView.Contain);
                }

                delegate: Item {
                    id: tile
                    required property var modelData
                    required property int index
                    width: grid.cellWidth
                    height: grid.cellHeight

                    readonly property bool current: bar.selected === tile.index
                    readonly property string icon: bar.iconFor(tile.modelData)
                    // Un réglage se règle sur place : son contrôle prend la
                    // place du sous-titre.
                    readonly property string control: bar.controlFor(tile.modelData)
                    readonly property bool hasControl: tile.control !== "" && tile.control !== "screens"

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 14
                        color: Qt.alpha(bar.hue(0), tile.current ? 0.22 : 0.1)
                        border.width: tile.current ? 1 : 0
                        border.color: Qt.alpha(bar.hue(0), 0.38)
                        opacity: tile.current || tileMa.containsMouse ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                    }

                    // L'icône, en haut au centre.
                    Item {
                        id: tileIcon
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 14
                        width: 32
                        height: 32

                        Image {
                            id: tileImage
                            anchors.fill: parent
                            source: tile.icon
                            sourceSize.width: 64
                            sourceSize.height: 64
                            fillMode: tile.icon.startsWith("file://") ? Image.PreserveAspectCrop
                                                                      : Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            visible: tile.icon.length > 0 && tileImage.status !== Image.Error
                        }

                        // Repli : l'initiale, sur une pastille de la teinte du type.
                        Rectangle {
                            anchors.fill: parent
                            radius: 9
                            visible: !tileImage.visible
                            color: Qt.alpha(tile.modelData.tone, 0.2)

                            Text {
                                anchors.centerIn: parent
                                text: tile.modelData.title.substring(0, 1).toUpperCase()
                                color: tile.modelData.tone
                                font.family: bar.uiFont
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    Text {
                        id: tileTitle
                        anchors.top: tileIcon.bottom
                        anchors.topMargin: 8
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 16
                        text: tile.modelData.title
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        font.family: bar.uiFont
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                    }

                    // Où il se trouve, ou à défaut son type, en plus discret.
                    Text {
                        visible: !tile.hasControl
                        anchors.top: tileTitle.bottom
                        anchors.topMargin: 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 16
                        text: tile.modelData.subtitle
                              || bar.typeLabels[tile.modelData.type] || tile.modelData.type
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideMiddle
                        font.family: bar.uiFont
                        font.pixelSize: 10
                        color: Theme.textSecondary
                    }

                    MouseArea {
                        id: tileMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: bar.activateResult(tile.modelData)
                    }

                    // Après la zone de clic de la tuile : le contrôle reçoit
                    // les siens en premier.
                    Loader {
                        anchors.top: tileTitle.bottom
                        anchors.topMargin: 6
                        anchors.horizontalCenter: parent.horizontalCenter
                        active: tile.hasControl
                        sourceComponent: tile.control === "theme" ? themeControl
                                       : tile.control === "volume" ? volumeControl
                                       : tile.control === "accent" ? accentControl : null
                    }
                }
            }
        }
    }

    // ── La barre ─────────────────────────────────────────────────
    // Une capsule de verre, à la façon de macOS, toujours à sa pleine largeur :
    // seules son arrivée et son départ s'animent. L'écoute et la réflexion
    // l'entourent d'un halo irisé qui tourne lentement.
    readonly property bool glowing: bar.voiceOn || ClaudeLive.pilotBusy
    readonly property string uiFont: "Inter"

    // Les teintes du halo, autour de la couleur d'accent.
    function hue(shift) {
        return Theme.glow(shift);
    }

    // ── Le halo ──────────────────────────────────────────────────
    // Un anneau au dégradé conique, collé au bord de la capsule : une copie
    // floutée pour la lueur, une copie nette pour le fil. Il vit dans sa
    // propre surface, sans flou ni clic : sur celle de la barre, Hyprland
    // flouterait toute la zone où la lueur laisse une trace.
    property PanelWindow glowWindow: PanelWindow { // qmllint disable uncreatable-type
        screen: bar.screen
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-conversation-glow"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { bottom: true }
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: bar.barW + 2 * glow.pad + 160
        implicitHeight: bar.barH + bar.gap + 2 * glow.pad + 90 + bar.hubMax
        color: "transparent"
        mask: Region {} // qmllint disable unqualified

        // L'ombre portée de la capsule, découpée à sa forme : elle ne
        // passe jamais sous le verre. Ses calques ont la taille de la
        // capsule et de la marge du flou, pas de la surface ; la capsule qui
        // monte les déplace (Translate) sans les redessiner ni les reflouter.
        Item {
            id: shadowBox
            // Le flou (blurMax) et le décalage de l'ombre y tiennent.
            readonly property int margin: 40
            x: (parent.width - pill.width) / 2 - margin
            y: parent.height - bar.gap - pill.height - margin
            width: pill.width + 2 * margin
            height: pill.height + 2 * margin
            transform: Translate { y: bar.lift }

            Item {
                id: shadowShape
                anchors.fill: parent
                visible: false
                layer.enabled: true
                Rectangle {
                    x: shadowBox.margin
                    y: shadowBox.margin + 6
                    width: pill.width
                    height: pill.height
                    radius: bar.barH / 2
                    color: "#000000"
                }
            }
            Item {
                id: pillShape
                anchors.fill: parent
                visible: false
                layer.enabled: true
                Rectangle {
                    x: shadowBox.margin
                    y: shadowBox.margin
                    width: pill.width
                    height: pill.height
                    radius: bar.barH / 2
                    color: "#000000"
                }
            }
            MultiEffect {
                anchors.fill: parent
                source: shadowShape
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1.0
                blurMax: 32
                opacity: (Theme.darkMode ? 0.55 : 0.22) * pill.opacity
                visible: opacity > 0
                maskEnabled: true
                maskSource: pillShape
                maskInverted: true
            }
        }

        Item {
            id: glow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.gap - glow.pad - bar.lift
            width: pill.width + 2 * pad
            height: pill.height + 2 * pad
            scale: pill.scale * (0.97 + 0.03 * bar.reveal)
            transformOrigin: Item.Bottom

            readonly property int pad: 14
            readonly property real thickness: 1.5
            property real angle: 0

            // L'écoute l'allume franchement, la réflexion à mi-voix.
            opacity: (bar.glowing ? (bar.voiceOn ? 1 : 0.55) : 0) * pill.opacity
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

            // Une rotation lente : les couleurs dérivent plus qu'elles ne tournent.
            NumberAnimation on angle {
                from: 0
                to: 360
                duration: 9000
                loops: Animation.Infinite
                running: glow.visible
            }

            Shape {
                id: ring
                anchors.fill: parent
                visible: false
                layer.enabled: true
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeWidth: -1
                    fillRule: ShapePath.OddEvenFill
                    fillGradient: ConicalGradient {
                        centerX: ring.width / 2
                        centerY: ring.height / 2
                        angle: glow.angle
                        GradientStop { position: 0.0;  color: bar.hue(0) }
                        GradientStop { position: 0.25; color: bar.hue(0.07) }
                        GradientStop { position: 0.5;  color: bar.hue(-0.06) }
                        GradientStop { position: 0.75; color: bar.hue(0.12) }
                        GradientStop { position: 1.0;  color: bar.hue(0) }
                    }
                    PathRectangle {
                        x: glow.pad - glow.thickness
                        y: glow.pad - glow.thickness
                        width: pill.width + 2 * glow.thickness
                        height: pill.height + 2 * glow.thickness
                        radius: bar.barH / 2 + glow.thickness
                    }
                    PathRectangle {
                        x: glow.pad
                        y: glow.pad
                        width: pill.width
                        height: pill.height
                        radius: bar.barH / 2
                    }
                }
            }

            // La lueur : une auréole douce dont l'intensité suit la voix
            // (lissée), sans que l'anneau ne change de taille.
            MultiEffect {
                anchors.fill: ring
                source: ring
                blurEnabled: true
                blur: 1.0
                blurMax: 40
                opacity: 0.45 + 0.55 * bar.level
            }

            // Le fil net, discret.
            MultiEffect {
                anchors.fill: ring
                source: ring
                opacity: 0.85
            }
        }
    }

    // ── Le voile de la réponse ───────────────────────────────────
    // Les résultats, eux, sont dans la capsule (l'onglet « Recherche »).
    // Une zone plus sombre, sans aucun bord, qui se fond dans l'écran. Deux
    // couches : un rectangle flouté sous le texte, et un halo bien plus large
    // flouté à mi-résolution puis agrandi deux fois, ce qui double la douceur
    // du fondu (le flou de Qt plafonne à 64 px). Le voile descend autour de
    // la capsule, découpé à sa forme : il ne passe jamais sur le verre.
    // Il vit dans sa propre surface, sans flou ni clic : sur celle de la
    // barre, la règle `ignore_alpha` d'Hyprland découperait une zone floutée
    // à bord net au milieu du dégradé.
    property PanelWindow veilWindow: PanelWindow { // qmllint disable uncreatable-type
        screen: bar.screen
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-conversation-veil"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { bottom: true }
        margins { // qmllint disable unqualified unresolved-type
            bottom: bar.gap - answerVeil.below
        }
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: bar.barW + 2 * answerVeil.spread
        implicitHeight: answerVeil.below + bar.height + answerVeil.spread
        color: "transparent"
        mask: Region {} // qmllint disable unqualified

        // La capsule, à sa place dans cette surface : le trou du voile.
        Item {
            id: veilCut
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                x: answerVeil.spread
                y: answerVeil.height - answerVeil.below - pill.height + bar.lift
                width: bar.barW
                height: pill.height
                radius: bar.barH / 2
                color: "#000000"
            }
        }

        Item {
            id: answerVeil
            // La marge laissée au fondu autour du contenu, et sous la capsule.
            readonly property int spread: 240
            readonly property int below: 90
            // Ce qu'il couvre : le texte de la réponse.
            readonly property real contentH: flick.height
            // L'écart entre le bas du contenu et la capsule.
            readonly property real contentGap: answer.fade * 0.6
            // Le bas du contenu et son centre, dans cette surface.
            readonly property real listBottom: height - below - bar.barH - contentGap
            readonly property real listCenter: listBottom - contentH / 2
            readonly property color tint: Theme.bgDeep
            anchors.fill: parent

            opacity: answer.opacity
            // Effacé, ses calques et ses flous ne sont plus recalculés.
            visible: opacity > 0
            transform: Translate {
                y: answer.shown ? 0 : 12
                Behavior on y { NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }
            }

            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskInverted: true
                maskSource: veilCut
            }

            // Le halo large : la moitié de sa taille, flouté, agrandi deux fois.
            Item {
                id: halo
                width: (bar.barW + 120) / 2
                height: (answerVeil.contentH + 120) / 2
                x: (answerVeil.width - width) / 2
                y: answerVeil.listCenter - height / 2
                scale: 2

                Rectangle {
                    id: haloSource
                    anchors.fill: parent
                    radius: 30
                    color: Qt.alpha(answerVeil.tint, Theme.darkMode ? 0.5 : 0.42)
                    visible: false
                    layer.enabled: true
                }
                MultiEffect {
                    anchors.fill: haloSource
                    source: haloSource
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 64
                }
            }

            // Le cœur, plus sombre, juste sous le texte. Son calque a la
            // taille du rectangle et de la marge du flou, pas de la surface :
            // la réponse qui s'écrit le refloute sur bien moins
            // de pixels.
            Item {
                id: core
                // Le flou (blurMax) y tient.
                readonly property int margin: 64
                x: answerVeil.spread - 10 - margin
                y: answerVeil.listBottom - answerVeil.contentH - 10 - margin
                width: bar.barW + 20 + 2 * margin
                height: answerVeil.contentH + 30 + 2 * margin
                visible: false
                layer.enabled: true
                Rectangle {
                    x: core.margin
                    y: core.margin
                    width: bar.barW + 20
                    height: answerVeil.contentH + 30
                    radius: 40
                    color: Qt.alpha(answerVeil.tint, Theme.darkMode ? 0.6 : 0.5)
                }
            }
            MultiEffect {
                anchors.fill: core
                source: core
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1.0
                blurMax: 64
            }
        }
    }

    Item {
        id: pill
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.barW
        // Le flocon l'agrandit vers le haut : les widgets prennent la place
        // gagnée au-dessus du champ (cf. expand).
        height: bar.barH + bar.expand * bar.hubH

        // Elle glisse de quelques pixels en apparaissant, à peine plus petite
        // au départ (cf. reveal). Le fondu va plus vite que le mouvement :
        // elle est déjà nette quand elle finit de se poser.
        opacity: Math.min(1, bar.reveal * 1.6)
        visible: bar.reveal > 0
        transform: [
            Scale {
                origin.x: pill.width / 2
                origin.y: pill.height
                xScale: 0.97 + 0.03 * bar.reveal
                yScale: xScale
            },
            Translate {
                y: bar.lift
            }
        ]

        HoverHandler { id: pillHover }

        // Un léger tassement quand une demande part.
        SequentialAnimation {
            id: sendBounce
            NumberAnimation { target: pill; property: "scale"; to: 0.985; duration: 90; easing.type: Easing.OutQuad }
            NumberAnimation { target: pill; property: "scale"; to: 1.0; duration: 380; easing.type: Easing.OutQuint }
        }

        // ── Le verre ─────────────────────────────────────────────
        // Translucide : Hyprland floute ce qui passe derrière (même règle de
        // couche que le voile de la réponse). Son ombre portée vit avec le
        // halo, dans la surface sans flou.
        // Les coins gardent le rayon de la capsule fermée : ouverte, elle
        // devient une carte aux mêmes arrondis.
        Rectangle {
            id: glass
            anchors.fill: parent
            radius: bar.barH / 2
            color: Qt.alpha(Theme.bgDeep, Theme.darkMode ? 0.62 : 0.7)
            border.width: 1
            border.color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.08)
        }

        // Le reflet : un liseré clair en haut, qui s'éteint sur la hauteur
        // d'une capsule fermée.
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: bar.barH / 2 - 1
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(1, 1, 1, 0.55) }
                GradientStop { position: 0.55 * bar.barH / Math.max(bar.barH, pill.height); color: "transparent" }
            }
        }

        // ── Les widgets, au-dessus du champ ──────────────────────
        WidgetHub {
            id: widgetHub
            bar: bar
            expand: bar.expand
            searchPage: searchPage
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: inputRow.top
            onLeave: input.forceActiveFocus()
        }

        // Le fil entre les widgets et le champ.
        Rectangle {
            anchors.bottom: inputRow.top
            x: 22
            width: pill.width - 44
            height: 1
            opacity: widgetHub.opacity
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.5; color: Qt.alpha(Theme.textPrimary, 0.12) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }

        // La ligne du champ : toujours la hauteur d'une capsule fermée, en bas.
        Item {
            id: inputRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: bar.barH
        }

        // ── Le flocon : les widgets ──────────────────────────────
        Item {
            id: logo
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: inputRow.verticalCenter
            width: 28
            height: 28

            // Transcription ou pilote au travail : il tourne doucement.
            readonly property bool turning: ClaudeLive.voicePhase === "transcribing" || ClaudeLive.pilotBusy
            // Revient droit une fois le travail fini.
            onTurningChanged: if (!turning) settle.restart()

            Item {
                id: flake
                anchors.fill: parent
                transformOrigin: Item.Center

                scale: logoMa.pressed ? 0.92 : logoMa.containsMouse || Widgets.hubOpen ? 1.06 : 1.0
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                RotationAnimation on rotation {
                    running: logo.turning
                    loops: Animation.Infinite
                    from: flake.rotation
                    to: flake.rotation + 360
                    duration: 4200
                }
                NumberAnimation {
                    id: settle
                    target: flake
                    property: "rotation"
                    to: Math.round(flake.rotation / 60) * 60
                    duration: 600
                    easing.type: Easing.OutCubic
                }

                Image {
                    id: flakeSource
                    anchors.fill: parent
                    source: "../assets/nixos.svg"
                    sourceSize.width: 96
                    sourceSize.height: 96
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    visible: false
                }

                // L'artwork est blanc : recoloré au thème, à l'accent quand
                // le menu est ouvert.
                MultiEffect {
                    anchors.fill: flakeSource
                    source: flakeSource
                    colorization: 1.0
                    colorizationColor: Widgets.hubOpen ? bar.hue(0.05) : Theme.iconColor
                    opacity: Widgets.hubOpen || logo.turning ? 1.0 : (logoMa.containsMouse ? 0.95 : 0.75)
                    Behavior on colorizationColor { ColorAnimation { duration: 200 } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
            }

            MouseArea {
                id: logoMa
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Widgets.toggleHub()
            }
        }

        // ── À droite : le micro, l'écoute, ou envoyer ────────────
        // Au repos, un micro : un clic lance l'écoute. Pendant qu'anna
        // écoute ou transcrit, il devient l'indicateur — une pastille teintée
        // où ondule la voix ; un clic coupe l'écoute. Dès qu'il y a du texte,
        // le bouton d'envoi prend sa place.
        Item {
            id: accessory
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: inputRow.verticalCenter
            width: 34
            height: 34

            // « Karénine » entendu : la barre revient, et l'indicateur
            // marque le coup d'une brève pulsation.
            Connections {
                target: bar
                function onVoiceOnChanged() {
                    if (bar.voiceOn) {
                        bar.dismissed = false;
                        Widgets.hubOpen = false;
                        voicePop.restart();
                    }
                }
            }

            Rectangle {
                id: voiceBtn
                anchors.centerIn: parent
                width: 34
                height: 34
                radius: 17
                readonly property bool on: !sendBtn.on
                property real popScale: 1.0
                color: bar.voiceOn ? Qt.alpha(bar.hue(0), 0.2)
                     : voiceMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.08) : "transparent"
                border.width: bar.voiceOn ? 1 : 0
                border.color: Qt.alpha(bar.hue(0), 0.45)
                Behavior on color { ColorAnimation { duration: 220; easing.type: Easing.OutCubic } }
                opacity: on ? 1 : 0
                scale: popScale * (on ? (voiceMa.pressed ? 0.92 : 1) : 0.7)
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                SequentialAnimation {
                    id: voicePop
                    NumberAnimation { target: voiceBtn; property: "popScale"; to: 1.12; duration: 160; easing.type: Easing.OutCubic }
                    NumberAnimation { target: voiceBtn; property: "popScale"; to: 1.0; duration: 460; easing.type: Easing.OutQuint }
                }

                // Le micro, qui s'efface quand l'onde prend sa place.
                Item {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    opacity: bar.voiceOn ? 0 : (voiceMa.containsMouse ? 0.95 : 0.7)
                    scale: bar.voiceOn ? 0.6 : 1
                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutQuint } }

                    Image {
                        id: micSource
                        anchors.fill: parent
                        source: "../assets/icons/mic.svg"
                        sourceSize.width: 48
                        sourceSize.height: 48
                        visible: false
                    }
                    MultiEffect {
                        anchors.fill: micSource
                        source: micSource
                        colorization: 1.0
                        colorizationColor: Theme.iconColor
                    }
                }

                MouseArea {
                    id: voiceMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Parler au pilote, ou couper l'écoute en cours.
                    onClicked: ClaudeLive.voiceToggle(true)
                }
            }

            // Le bouton d'envoi, qui éclot quand il y a quelque chose à envoyer.
            Rectangle {
                id: sendBtn
                anchors.centerIn: parent
                width: 32
                height: 32
                radius: 16
                color: bar.hue(0)
                readonly property bool on: input.text.trim().length > 0 && !bar.voiceOn
                opacity: on ? 1 : 0
                scale: on ? (sendMa.pressed ? 0.92 : 1) : 0.7
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

                Text {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1
                    text: "↑"
                    font.family: bar.uiFont
                    font.pixelSize: 17
                    font.weight: Font.Bold
                    color: "#ffffff"
                }

                MouseArea {
                    id: sendMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: bar.submit()
                }
            }

            // La forme d'onde : cinq barres portées par une onde continue,
            // dont l'amplitude suit le niveau lissé de la voix. Pendant la
            // transcription, une petite vague les parcourt de gauche à droite.
            Row {
                id: wave
                anchors.centerIn: parent
                spacing: 3
                readonly property bool on: bar.voiceOn
                readonly property bool transcribing: ClaudeLive.voicePhase === "transcribing"
                property real phase: 0
                opacity: on ? 1 : 0
                scale: on ? 1 : 0.7
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }

                NumberAnimation on phase {
                    from: 0
                    to: 2 * Math.PI
                    duration: wave.transcribing ? 1400 : 1000
                    loops: Animation.Infinite
                    running: wave.visible
                }

                Repeater {
                    model: [0.55, 0.85, 1.0, 0.85, 0.55]
                    Rectangle {
                        id: waveBar
                        required property real modelData
                        required property int index
                        anchors.verticalCenter: parent.verticalCenter
                        width: 3
                        radius: 1.5
                        color: bar.hue(waveBar.index * 0.03)

                        readonly property real swing: 0.5 + 0.5 * Math.sin(wave.phase - waveBar.index * 0.9)
                        height: wave.transcribing
                                ? 4 + 6 * waveBar.swing
                                : 4 + 18 * waveBar.modelData * bar.level * (0.65 + 0.35 * waveBar.swing)
                    }
                }
            }
        }

        // ── Le champ ─────────────────────────────────────────────
        Item {
            id: field
            anchors.left: logo.right
            anchors.leftMargin: 12
            anchors.right: accessory.left
            anchors.rightMargin: 8
            anchors.top: inputRow.top
            anchors.bottom: inputRow.bottom
            clip: true

            TextInput {
                id: input
                anchors.fill: parent
                verticalAlignment: TextInput.AlignVCenter
                opacity: bar.voiceOn ? 0 : 1
                enabled: !bar.voiceOn
                Behavior on opacity { NumberAnimation { duration: 180 } }
                font.family: bar.uiFont
                font.pixelSize: 15
                font.weight: Font.Medium
                color: Theme.textPrimary
                selectionColor: Qt.alpha(bar.hue(0), 0.45)
                selectedTextColor: Theme.textPrimary

                // La recherche suit la frappe ; la voix, elle, n'écrit pas ici.
                onTextChanged: {
                    // Les résultats attendent dans leur onglet : écrire ne
                    // l'ouvre pas.
                    Search.query = text;
                }

                Keys.onReturnPressed: bar.submit()
                Keys.onEnterPressed: bar.submit()
                // La grille est au-dessus : ↑ y monte, ↓ redescend vers le champ.
                // Champ vide, les widgets sont au-dessus : ↑ les ouvre, puis
                // y entre (sur les onglets) ; ↓ les referme.
                Keys.onUpPressed: (event) => {
                    if (bar.rowStep(1))
                        return;
                    if (input.text.length === 0 && Widgets.hubOpen)
                        widgetHub.enter();
                    else if (input.text.length === 0)
                        Widgets.hubOpen = true;
                    // Du texte, les widgets fermés : ↑ va voir les résultats.
                    else if (!Widgets.hubOpen) {
                        Widgets.hubTab = "recherche";
                        Widgets.hubOpen = true;
                    } else
                        event.accepted = false;
                }
                Keys.onDownPressed: (event) => {
                    if (bar.rowStep(-1))
                        return;
                    if (Widgets.hubOpen)
                        Widgets.hubOpen = false;
                    else
                        event.accepted = false;
                }
                // Tab mène aux widgets ouverts et en revient ; Ctrl+Tab
                // change d'onglet sans quitter le champ.
                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (Widgets.hubOpen && (event.modifiers & Qt.ControlModifier)
                        && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
                        widgetHub.step(event.key === Qt.Key_Backtab ? -1 : 1);
                        event.accepted = true;
                    }
                }
                // Sur une tuile retenue, ← → passent à la voisine (Maj+← →
                // règlent le volume ou l'accent) ; champ vide et widgets
                // ouverts, ils changent de widget ; ailleurs ils déplacent le
                // curseur du texte.
                Keys.onLeftPressed: (event) => event.accepted = bar.arrow(-1, event.modifiers & Qt.ShiftModifier)
                Keys.onRightPressed: (event) => event.accepted = bar.arrow(1, event.modifiers & Qt.ShiftModifier)
                // Une sélection en cours s'abandonne avant la barre. Sur
                // l'onglet Recherche, Échap abandonne la recherche : le champ
                // se vide.
                Keys.onEscapePressed: {
                    if (bar.selected >= 0)
                        bar.selected = -1;
                    else if (bar.resultsShown && input.text.length > 0)
                        bar.release();
                    else if (Widgets.hubOpen)
                        Widgets.hubOpen = false;
                    else
                        bar.release();
                }

                // Le clavier passé aux widgets (Tab) reste à la barre : seul
                // un départ ailleurs rend le clavier aux fenêtres. Vérifié un
                // instant après : le hub ne le reçoit qu'une fois le champ quitté.
                onActiveFocusChanged: {
                    if (!activeFocus && bar.focusRequested)
                        Qt.callLater(() => {
                            if (!input.activeFocus && !widgetHub.activeFocus)
                                bar.focusRequested = false;
                        });
                }
            }

            // L'invite : s'efface en glissant dès la première lettre.
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                readonly property bool on: !bar.voiceOn && input.text.length === 0
                opacity: on ? 1 : 0
                x: on ? 0 : 10
                Behavior on opacity { NumberAnimation { duration: 160 } }
                Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                text: bar.asking && answer.shown ? "Ta réponse…"
                    : ClaudeLive.voiceWake ? "Demander ou chercher, ou dire « Karénine »"
                    : "Demander à Karénine ou chercher…"
                font.family: bar.uiFont
                font.pixelSize: 15
                color: Qt.alpha(Theme.textPrimary, 0.42)
                elide: Text.ElideRight
            }

            // La demande qui vient de partir s'envole vers la réponse.
            Text {
                id: ghost
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                opacity: 0
                font: input.font
                color: Theme.textPrimary
                elide: Text.ElideRight

                ParallelAnimation {
                    id: flyAway
                    NumberAnimation { target: ghost; property: "anchors.verticalCenterOffset"; from: 0; to: -22; duration: 380; easing.type: Easing.OutCubic }
                    NumberAnimation { target: ghost; property: "opacity"; from: 1; to: 0; duration: 380; easing.type: Easing.OutCubic }
                }
            }

            // Ce qu'anna comprend, en direct ; les derniers mots gagnent
            // quand ça ne tient plus.
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                opacity: bar.voiceOn ? 1 : 0
                x: bar.voiceOn ? 0 : -10
                Behavior on opacity { NumberAnimation { duration: 200 } }
                Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                elide: Text.ElideLeft
                text: ClaudeLive.voiceText.length > 0 ? ClaudeLive.voiceText
                    : ClaudeLive.voicePhase === "listening" ? "J'écoute…" : "Je transcris…"
                font.family: bar.uiFont
                font.pixelSize: 15
                font.weight: Font.Medium
                color: ClaudeLive.voicePartial || ClaudeLive.voicePhase === "transcribing"
                       ? Theme.textSecondary : Theme.textPrimary
                Behavior on color { ColorAnimation { duration: 200 } }
            }
        }
    }

    function launch(text) {
        ghost.text = text;
        flyAway.restart();
        sendBounce.restart();
    }
}
