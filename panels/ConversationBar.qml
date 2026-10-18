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
//          ╭──────────────────────────────────────────╮
//          │ › baisse le son                       ✕  │   le dernier tour,
//          │ (volume {"delta":-10})                   │   sur une carte du
//          │ Volume à 40 %.                           │   même verre
//          ╰──────────────────────────────────────────╯
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
// La même barre cherche : dès la première lettre, les suggestions
// (applications, fichiers, réglages, web — le service Search, celui de
// l'ancien dock) s'empilent juste au-dessus, sur une carte du même verre que
// la capsule, la meilleure contre la barre. Écrire referme les widgets.
// Entrée part toujours au pilote ; ↑ entre dans la liste, et Entrée ou un
// clic ouvre alors la suggestion retenue.
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
    // Pas pendant un glisser depuis l'explorateur : tant qu'une surface layer
    // tient le clavier en exclusif, Hyprland ne donne plus le focus du
    // pointeur aux fenêtres, qui ne verraient jamais le fichier arriver.
    WlrLayershell.keyboardFocus: bar.focusRequested && !DragState.active
                                 ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    anchors { bottom: true }
    margins { // qmllint disable unqualified unresolved-type
        bottom: bar.gap
    }
    // Cachée la plupart du temps : elle passe par-dessus les fenêtres quand
    // elle vient, plutôt que de leur prendre de la place pour rien.
    exclusiveZone: 0
    // Un peu plus large que la barre : de la marge autour des cartes.
    implicitWidth: bar.barW + 240
    implicitHeight: Math.max(480, bar.barH + bar.hubMax + 20)
    color: "transparent"

    mask: Region { // qmllint disable unqualified
        Region { item: bar.shown ? pill : null }
        Region { item: answer.on ? answer : null }
        Region { item: results.visible ? results : null }
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
        function onHubOpenChanged() {
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
    readonly property bool pointerInside: pillHover.hovered || resultsHover.hovered
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
        // Ni pendant un glisser depuis l'explorateur : le curseur part forcément
        // vers une autre application, et fermer la barre détruirait la tuile
        // source au milieu du geste. Il repart de zéro au lâcher.
        running: bar.typing && !Gesture.active && !DragState.active
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
        if (xy.length !== 2 || !s || !bar.typing || DragState.active)
            return;
        var x = parseFloat(xy[0]);
        var y = parseFloat(xy[1]);

        // Le rectangle de la capsule (widgets compris) seule : y ajouter les
        // suggestions ferait sauter la distance quand elles apparaissent ou
        // disparaissent (champ vidé), et la barre se fermerait sans que la
        // souris ait bougé. Les survoler compte quand même (pointerInside).
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
        if (bar.selected >= 0) {
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
    // Ce qu'on tape part aussi dans Search ; tant qu'il y a des suggestions,
    // elles passent devant la réponse du pilote.
    readonly property bool searching: Search.active && !bar.voiceOn
    // La suggestion retenue au clavier ; -1 : Entrée va au pilote.
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

    // ← → dans le champ : vrai s'ils ont servi (réglage retenu, ou widget
    // d'à côté), faux pour laisser bouger le curseur du texte. Sur un
    // réglage retenu (volume, accent), ils le règlent.
    function arrow(dir) {
        if (bar.adjustSelected(dir))
            return true;
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

    // ↑ ↓ dans la liste (la meilleure en bas, contre le champ) : ↑ y entre
    // par la première, ↓ depuis elle revient au champ (-1). Vrai s'ils ont
    // servi.
    function rowStep(dir) {
        var n = results.on ? Search.results.length : 0;
        if (n === 0 || (dir < 0 && bar.selected < 0))
            return false;
        bar.selected = Math.max(-1, Math.min(n - 1, bar.selected + dir));
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
                implicitWidth: 140
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
            implicitWidth: 170
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
        case "wallpaper":
            return Quickshell.iconPath("preferences-desktop-wallpaper", true);
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
        "app": "app", "file": "fichier", "setting": "réglage", "web": "web",
        "wallpaper": "fond"
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
    // Une carte du même verre que la capsule et les suggestions (Hyprland la
    // floute, son ombre vit avec celle de la capsule). En haut, ce qui a été
    // demandé, discret, et de quoi la fermer ; puis ce que le pilote a fait,
    // en pastilles ; puis sa réponse.
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
        readonly property bool on: shown && hasContent && !bar.searching && !bar.dismissed && !Widgets.hubOpen
        readonly property int padX: 20
        readonly property int padY: 16

        anchors.bottom: pill.top
        anchors.bottomMargin: 10
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.barW
        height: Math.min(column.implicitHeight + 2 * padY, bar.height - bar.barH - 20)
        Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

        visible: opacity > 0
        opacity: on ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // Elle monte de la barre en décélérant, comme la capsule.
        property real rise: answer.on ? 0 : 12
        Behavior on rise { NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }
        transform: Translate { y: answer.rise }

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

        // Le verre, et son reflet en haut, comme la capsule.
        Rectangle {
            anchors.fill: parent
            radius: 22
            color: Qt.alpha(Theme.bgDeep, Theme.darkMode ? 0.62 : 0.7)
            border.width: 1
            border.color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.08)
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: 21
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.5) }
                GradientStop { position: Math.min(1, 30 / Math.max(1, answer.height)); color: "transparent" }
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
            anchors.leftMargin: answer.padX
            anchors.rightMargin: answer.padX
            anchors.topMargin: answer.padY
            anchors.bottomMargin: answer.padY
            contentHeight: column.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // La fin de la réponse reste en vue pendant qu'elle s'écrit.
            onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

            Column {
                id: column
                width: flick.width
                spacing: 10

                Text {
                    width: parent.width
                    visible: answer.notice.length > 0
                    text: answer.notice
                    wrapMode: Text.Wrap
                    font.family: bar.uiFont
                    font.pixelSize: 14
                    font.weight: Font.Medium
                    color: Theme.colorDanger
                }

                // Ce qui a été demandé — ou compris, pour vérifier la voix —,
                // et la croix, à droite.
                Item {
                    width: parent.width
                    height: Math.max(heard.implicitHeight, 22)
                    visible: answer.notice.length === 0 && bar.turn !== null

                    Text {
                        id: heard
                        anchors.left: parent.left
                        anchors.right: closeBtn.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "<font color='" + bar.hue(0) + "'>›</font>  "
                              + (bar.turn ? bar.turn.heard.replace(/&/g, "&amp;").replace(/</g, "&lt;") : "")
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.family: bar.uiFont
                        font.pixelSize: 12
                        color: Theme.textSecondary
                    }

                    Rectangle {
                        id: closeBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22
                        height: 22
                        radius: 11
                        color: Qt.alpha(Theme.textPrimary, closeMa.containsMouse ? 0.1 : 0.05)
                        Behavior on color { ColorAnimation { duration: 140 } }

                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.family: bar.uiFont
                            font.pixelSize: 10
                            color: closeMa.containsMouse ? Theme.textPrimary : Theme.textSecondary
                        }
                        MouseArea {
                            id: closeMa
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: answer.hide()
                        }
                    }
                }

                // Ce que le pilote a fait : une pastille par action, de la
                // teinte de la barre, comme les types des suggestions.
                Flow {
                    width: parent.width
                    spacing: 6
                    visible: answer.notice.length === 0 && bar.turn !== null && bar.turn.actions.length > 0

                    Repeater {
                        model: answer.notice.length === 0 && bar.turn ? bar.turn.actions : []

                        Rectangle {
                            id: chip
                            required property string modelData
                            width: Math.min(chipLabel.implicitWidth + 18, column.width)
                            height: 22
                            radius: 11
                            color: Qt.alpha(bar.hue(0), 0.13)
                            border.width: 1
                            border.color: Qt.alpha(bar.hue(0), 0.22)

                            Text {
                                id: chipLabel
                                anchors.centerIn: parent
                                width: Math.min(implicitWidth, column.width - 18)
                                text: chip.modelData
                                elide: Text.ElideRight
                                font.family: "JetBrains Mono"
                                font.pixelSize: 10
                                color: Theme.textSecondary
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: answer.notice.length === 0 && bar.turn !== null && bar.turn.reply.length > 0
                    text: bar.turn ? bar.turn.reply : ""
                    textFormat: Text.MarkdownText
                    wrapMode: Text.Wrap
                    // Une confirmation courte s'affiche plus grand, une longue
                    // réponse à la taille du texte courant.
                    font.family: bar.uiFont
                    font.pixelSize: text.length > 220 ? 14 : 17
                    font.weight: text.length > 220 ? Font.Normal : Font.Medium
                    lineHeight: 1.2
                    color: bar.turn && bar.turn.failed ? Theme.colorDanger : Theme.textPrimary
                    linkColor: bar.hue(0.05)
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                }

                // Le pilote attend une réponse : on la tape dans la barre.
                Rectangle {
                    visible: bar.asking && answer.notice.length === 0
                    width: askLabel.implicitWidth + 20
                    height: 24
                    radius: 12
                    color: Qt.alpha(bar.hue(0), 0.18)
                    border.width: 1
                    border.color: Qt.alpha(bar.hue(0), 0.38)

                    Text {
                        id: askLabel
                        anchors.centerIn: parent
                        text: "↵ réponds dans la barre"
                        font.family: bar.uiFont
                        font.pixelSize: 11
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                    }
                }

                // Le pilote réfléchit : trois points qui respirent.
                Row {
                    visible: answer.notice.length === 0 && ClaudeLive.pilotBusy
                    height: 14
                    spacing: 5
                    Repeater {
                        model: 3
                        Rectangle {
                            id: dot
                            required property int index
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7
                            height: 7
                            radius: 3.5
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

    // ── Les suggestions, au-dessus de la barre ───────────────────
    // Une carte du même verre que la capsule (Hyprland la floute aussi, son
    // ombre vit avec celle de la capsule), posée juste au-dessus : une ligne
    // par suggestion, l'icône, le nom puis où il se trouve, et son type dans
    // une pastille à droite. La meilleure est en bas, contre la barre, pour
    // que ↑ y entre directement ; la retenue prend la teinte de la barre,
    // comme l'onglet actif des widgets.
    Item {
        id: results

        readonly property int rowH: 40
        readonly property int maxRows: 7
        readonly property int pad: 6
        // Les widgets ouverts (le flocon, champ rempli) les cachent.
        readonly property bool on: bar.searching && bar.shown && !Widgets.hubOpen
                                   && Search.results.length > 0
        // La liste qui part peut laisser le curseur loin de la capsule sans
        // qu'il ait bougé : la distance repart de là.
        onOnChanged: bar.closest = -1

        anchors.bottom: pill.top
        anchors.bottomMargin: 10
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.barW
        height: Math.min(Search.results.length, maxRows) * rowH + 2 * pad
        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }

        opacity: on ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        // Elle monte de la barre en décélérant, comme la capsule.
        property real drop: results.on ? 0 : 10
        Behavior on drop { NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }
        transform: Translate { y: results.drop }

        HoverHandler { id: resultsHover }

        // Le verre, et son reflet en haut, comme la capsule.
        Rectangle {
            anchors.fill: parent
            radius: 22
            color: Qt.alpha(Theme.bgDeep, Theme.darkMode ? 0.62 : 0.7)
            border.width: 1
            border.color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.08)
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: 21
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.5) }
                GradientStop { position: Math.min(1, 30 / Math.max(1, results.height)); color: "transparent" }
            }
        }

        ListView {
            id: list
            anchors.fill: parent
            anchors.margins: results.pad

            model: Search.results
            verticalLayoutDirection: ListView.BottomToTop
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            currentIndex: bar.selected
            highlightFollowsCurrentItem: false
            onCurrentIndexChanged: {
                if (currentIndex >= 0)
                    positionViewAtIndex(currentIndex, ListView.Contain);
            }

            delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: list.width
                height: results.rowH

                readonly property bool current: bar.selected === row.index
                readonly property string icon: bar.iconFor(row.modelData)
                // Un réglage se règle sur place : son contrôle prend la place
                // de la pastille du type. Les écrans, eux, passent au suivant
                // d'un clic.
                readonly property string control: bar.controlFor(row.modelData)
                readonly property bool hasControl: row.control !== "" && row.control !== "screens"

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: row.current ? Qt.alpha(bar.hue(0), 0.16)
                                       : Qt.alpha(Theme.textPrimary, rowMa.containsMouse ? 0.06 : 0)
                    border.width: row.current ? 1 : 0
                    border.color: Qt.alpha(bar.hue(0), 0.38)
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // L'icône, à la taille du flocon de la barre, alignée sur lui.
                Item {
                    id: rowIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24

                    Image {
                        id: rowImage
                        anchors.fill: parent
                        source: row.icon
                        sourceSize.width: 48
                        sourceSize.height: 48
                        fillMode: row.icon.startsWith("file://") ? Image.PreserveAspectCrop
                                                                 : Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        visible: row.icon.length > 0 && rowImage.status !== Image.Error
                    }

                    // Repli : l'initiale, sur une pastille de la teinte du type.
                    Rectangle {
                        anchors.fill: parent
                        radius: 7
                        visible: !rowImage.visible
                        color: Qt.alpha(row.modelData.tone, 0.2)

                        Text {
                            anchors.centerIn: parent
                            text: row.modelData.title.substring(0, 1).toUpperCase()
                            color: row.modelData.tone
                            font.family: bar.uiFont
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }
                    }
                }

                // Le type, dans une pastille de sa teinte ; sur la ligne
                // retenue, ce qu'Entrée fera.
                Rectangle {
                    id: kind
                    visible: !row.hasControl
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: kindLabel.implicitWidth + 16
                    height: 22
                    radius: 11
                    color: row.current ? Qt.alpha(bar.hue(0), 0.22) : Qt.alpha(row.modelData.tone, 0.13)
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        id: kindLabel
                        anchors.centerIn: parent
                        text: row.current ? "↵ ouvrir"
                                          : bar.typeLabels[row.modelData.type] || row.modelData.type
                        font.family: bar.uiFont
                        font.pixelSize: 10
                        font.weight: Font.Medium
                        color: row.current ? Theme.textPrimary : Theme.textSecondary
                    }
                }

                // Le nom, aligné sur le texte du champ, puis où il se
                // trouve, en plus discret.
                Row {
                    anchors.left: rowIcon.right
                    anchors.leftMargin: 14
                    anchors.right: row.hasControl ? controlSlot.left : kind.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        id: rowTitle
                        width: Math.min(implicitWidth, parent.width)
                        text: row.modelData.title
                        elide: Text.ElideRight
                        font.family: bar.uiFont
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                    }

                    Text {
                        width: Math.max(0, parent.width - rowTitle.width - parent.spacing)
                        anchors.baseline: rowTitle.baseline
                        // Le contrôle dit déjà la valeur.
                        text: row.hasControl ? "" : row.modelData.subtitle || ""
                        elide: Text.ElideMiddle
                        font.family: bar.uiFont
                        font.pixelSize: 11
                        color: Theme.textSecondary
                    }
                }

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: bar.activateResult(row.modelData)
                }

                // Après la zone de clic de la ligne : le contrôle reçoit les
                // siens en premier.
                Loader {
                    id: controlSlot
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    active: row.hasControl
                    sourceComponent: row.control === "theme" ? themeControl
                                   : row.control === "volume" ? volumeControl
                                   : row.control === "accent" ? accentControl : null
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

    // L'ombre portée d'une carte de verre (suggestions, réponse), découpée à
    // sa forme comme celle de la capsule : elle ne passe jamais sous le verre.
    component CardShadow: Item {
        id: cs
        required property Item card
        readonly property int margin: 40
        width: cs.card.width + 2 * cs.margin
        height: cs.card.height + 2 * cs.margin
        visible: cs.card.visible

        Item {
            id: csShadow
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                x: cs.margin
                y: cs.margin + 6
                width: cs.card.width
                height: cs.card.height
                radius: 22
                color: "#000000"
            }
        }
        Item {
            id: csCut
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                x: cs.margin
                y: cs.margin
                width: cs.card.width
                height: cs.card.height
                radius: 22
                color: "#000000"
            }
        }
        MultiEffect {
            anchors.fill: parent
            source: csShadow
            autoPaddingEnabled: false
            blurEnabled: true
            blur: 1.0
            blurMax: 32
            opacity: (Theme.darkMode ? 0.55 : 0.22) * cs.card.opacity
            maskEnabled: true
            maskSource: csCut
            maskInverted: true
        }
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

        // La même ombre sous la carte des suggestions et sous celle de la
        // réponse (jamais affichées ensemble).
        CardShadow {
            card: results
            x: (parent.width - results.width) / 2 - margin
            y: parent.height - bar.gap - pill.height - results.anchors.bottomMargin
               - results.height - margin
            transform: Translate { y: results.drop }
        }
        CardShadow {
            card: answer
            x: (parent.width - answer.width) / 2 - margin
            y: parent.height - bar.gap - pill.height - answer.anchors.bottomMargin
               - answer.height - margin
            transform: Translate { y: answer.rise }
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
        // couche que les cartes de la réponse et des suggestions). Son ombre
        // portée vit avec le halo, dans la surface sans flou.
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
                    Search.query = text;
                    // Écrire referme les widgets : les suggestions prennent
                    // leur place, au-dessus de la capsule.
                    if (text.length > 0)
                        Widgets.hubOpen = false;
                }

                Keys.onReturnPressed: bar.submit()
                Keys.onEnterPressed: bar.submit()
                // Les suggestions sont au-dessus : ↑ y monte, ↓ redescend vers
                // le champ. Champ vide, les widgets sont au-dessus : ↑ les
                // ouvre, puis y entre (sur les onglets) ; ↓ les referme.
                Keys.onUpPressed: (event) => {
                    if (bar.rowStep(1))
                        return;
                    if (input.text.length === 0 && Widgets.hubOpen)
                        widgetHub.enter();
                    else if (input.text.length === 0)
                        Widgets.hubOpen = true;
                    else
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
                // Sur un réglage retenu (volume, accent), ← → le règlent ;
                // champ vide et widgets ouverts, ils changent de widget ;
                // ailleurs ils déplacent le curseur du texte.
                Keys.onLeftPressed: (event) => event.accepted = bar.arrow(-1)
                Keys.onRightPressed: (event) => event.accepted = bar.arrow(1)
                // Une sélection en cours s'abandonne avant les widgets, puis
                // la barre.
                Keys.onEscapePressed: {
                    if (bar.selected >= 0)
                        bar.selected = -1;
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
