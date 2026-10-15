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
//         ✦│ ❄  Demander à Karénine…              (↑) │✦  halo irisé quand
//         ✦╰──────────────────────────────────────────╯✦  elle écoute ou pense
//
// Cachée par défaut : elle monte du bord de l'écran quand on dit « Karénine »
// ou qu'on tape Super, et repart une fois la réponse lue. La voix passe par le même
// chemin : dire « Karénine » (ou Super+V, ou un clic sur le flocon) fait
// sauter le flocon, la phrase s'écrit dans le champ à mesure qu'anna la
// comprend, une forme d'onde suit la voix, puis la phrase part au pilote.
//
// La même barre cherche : dès la première lettre, les résultats (applications,
// fichiers, réglages, web — le service Search, celui de
// l'ancien dock) s'empilent juste au-dessus, en liste, le meilleur contre la
// barre. Entrée part toujours au pilote ; ↑ entre dans la liste, et Entrée
// ou un clic ouvre alors le résultat retenu.
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

    readonly property int barH: 44
    readonly property int barW: Math.min(620, (bar.screen ? bar.screen.width : 1280) - 32)
    // Distance au bord de l'écran.
    readonly property int gap: 26

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
    implicitHeight: 480
    color: "transparent"

    mask: Region { // qmllint disable unqualified
        Region { item: bar.shown ? pill : null }
        Region { item: answer.shown && !bar.searching && !bar.dismissed ? flick : null }
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
                                       || input.text.length > 0 || ClaudeLive.pilotBusy || answer.shown)
    property bool shown: false

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

    Timer {
        interval: 120
        repeat: true
        running: bar.typing && !Gesture.active
        onRunningChanged: bar.closest = -1
        onTriggered: {
            if (!cursorProbe.running)
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

        // Le rectangle de la capsule seule : y ajouter la liste ferait sauter
        // la distance quand elle apparaît ou disparaît (champ vidé), et la
        // barre se fermerait sans que la souris ait bougé. Survoler la liste
        // compte quand même comme être dessus (pointerInside).
        var left = s.x + (s.width - bar.barW) / 2;
        var bottom = s.y + s.height - bar.gap;
        var top = bottom - bar.barH;
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
        input.text = "";
        answer.notice = "";
        answer.show();
        // Le clavier redevient libre : un clic dans le champ le reprend.
        bar.focusRequested = false;
    }

    // ── La recherche ─────────────────────────────────────────────
    // Ce qu'on tape part aussi dans Search ; tant qu'il y a des résultats, ils
    // passent devant la réponse du pilote.
    readonly property bool searching: Search.active && !bar.voiceOn
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

    function adjustSelected(dir) {
        var item = bar.selected >= 0 ? Search.results[bar.selected] : null;
        if (!item || !item.payload || !item.payload.adjust)
            return false;
        Search.activate(item, dir > 0 ? "up" : "down");
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
            spacing: 10
            // Le niveau n'est sondé que tant que la ligne est là.
            Component.onCompleted: Audio.active = true
            Component.onDestruction: Audio.active = false
            BarSlider {
                anchors.verticalCenter: parent.verticalCenter
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
            rainbow: true
            saturation: Math.max(0.35, Theme.accentColor.hsvSaturation)
            brightness: Math.max(0.35, Theme.accentColor.hsvValue)
            value: bar.accentHue
            knobColor: bar.accentAt(accentSlider.shown)
            onCommitted: (v) => Theme.setAccentColor(bar.accentAt(Math.min(v, 0.999)).toString())
        }
    }

    // Les écrans branchés, en pastilles ; « Auto » s'en remet à la config Nix.
    Component {
        id: screensControl
        Row {
            spacing: 4
            Repeater {
                model: [null].concat(Quickshell.screens)
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    readonly property string key: chip.modelData ? Display.screenKey(chip.modelData) : ""
                    readonly property bool selected: Display.preferred === chip.key
                    width: chipLabel.width + 16
                    height: 22
                    radius: 11
                    color: chip.selected ? Qt.alpha(bar.hue(0), 0.3)
                         : chipMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.1) : "transparent"
                    border.width: 1
                    border.color: chip.selected ? bar.hue(0) : Qt.alpha(Theme.textPrimary, 0.18)

                    Text {
                        id: chipLabel
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, 110)
                        text: chip.modelData ? chip.modelData.model || chip.modelData.name : "Auto"
                        elide: Text.ElideRight
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        color: chip.selected ? Theme.textPrimary : Theme.textSecondary
                    }
                    MouseArea {
                        id: chipMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Display.setPreferred(chip.key)
                    }
                }
            }
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
    // Pas de cadre : le texte, en grand, sur un voile. Le voile est une
    // ellipse sombre qui s'efface vers ses bords ; Hyprland floute ce qu'il
    // y a derrière partout où il est assez opaque (règle de couche `blur` +
    // `ignore_alpha` sur « quickshell-conversation », dans la config NixOS).
    // Sans cette règle, le voile seul suffit encore à lire.
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
        opacity: shown && hasContent && !bar.searching && !bar.dismissed ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // Elle monte de la barre sur un ressort.
        transformOrigin: Item.Bottom
        scale: shown ? 1 : 0.95
        Behavior on scale { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.002 } }
        transform: Translate {
            y: answer.shown ? 0 : 18
            Behavior on y { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.1 } }
        }

        // Le voile : un disque au dégradé radial, aplati en ellipse.
        Shape {
            id: veil
            width: answer.width
            height: answer.width
            y: (answer.height - height) / 2
            preferredRendererType: Shape.CurveRenderer
            transform: Scale {
                origin.y: veil.height / 2
                yScale: answer.height / Math.max(1, veil.height)
            }

            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: veil.width / 2
                    centerY: veil.height / 2
                    centerRadius: veil.width / 2
                    focalX: centerX
                    focalY: centerY
                    GradientStop { position: 0.0; color: Qt.alpha(Theme.bgDeep, 0.72) }
                    GradientStop { position: 0.45; color: Qt.alpha(Theme.bgDeep, 0.6) }
                    GradientStop { position: 0.75; color: Qt.alpha(Theme.bgDeep, 0.25) }
                    GradientStop { position: 1.0; color: Qt.alpha(Theme.bgDeep, 0) }
                }
                startX: 0; startY: 0
                PathLine { x: veil.width; y: 0 }
                PathLine { x: veil.width; y: veil.height }
                PathLine { x: 0; y: veil.height }
                PathLine { x: 0; y: 0 }
            }
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

    // ── Les résultats, au-dessus de la barre ─────────────────────
    // Une liste sur un voile en fondu : une ligne par résultat, une icône de
    // la taille du flocon. Le meilleur est en bas, contre la barre, pour que ↑ y entre
    // directement.
    Item {
        id: results

        readonly property int rowH: 36
        readonly property int maxRows: 8
        readonly property bool on: bar.searching && bar.shown && Search.results.length > 0
        // La liste qui part peut laisser le curseur loin de la capsule sans
        // qu'il ait bougé : la distance repart de là.
        onOnChanged: bar.closest = -1

        anchors.bottom: pill.top
        anchors.bottomMargin: 10
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.barW
        height: Math.min(Search.results.length, maxRows) * rowH + 12
        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        opacity: on ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        transform: Translate {
            y: results.on ? 0 : 14
            Behavior on y { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.1 } }
        }

        HoverHandler { id: resultsHover }

        // Le fond : un voile sombre sans bord, qui s'efface vers l'extérieur,
        // comme celui de la réponse. Il déborde largement de la liste pour que
        // le fondu se fasse hors des lignes.
        Shape {
            id: resultsVeil
            readonly property int fade: 70
            x: -fade * 1.6
            width: results.width + fade * 3.2
            height: width
            y: (results.height - height) / 2
            preferredRendererType: Shape.CurveRenderer
            transform: Scale {
                origin.y: resultsVeil.height / 2
                yScale: (results.height + resultsVeil.fade * 2) / Math.max(1, resultsVeil.height)
            }

            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: resultsVeil.width / 2
                    centerY: resultsVeil.height / 2
                    centerRadius: resultsVeil.width / 2
                    focalX: centerX
                    focalY: centerY
                    GradientStop { position: 0.0; color: Qt.alpha(Theme.bgDeep, 0.72) }
                    GradientStop { position: 0.5; color: Qt.alpha(Theme.bgDeep, 0.6) }
                    GradientStop { position: 0.78; color: Qt.alpha(Theme.bgDeep, 0.25) }
                    GradientStop { position: 1.0; color: Qt.alpha(Theme.bgDeep, 0) }
                }
                startX: 0; startY: 0
                PathLine { x: resultsVeil.width; y: 0 }
                PathLine { x: resultsVeil.width; y: resultsVeil.height }
                PathLine { x: 0; y: resultsVeil.height }
                PathLine { x: 0; y: 0 }
            }
        }

        ListView {
            id: list
            anchors.fill: parent
            anchors.margins: 6

            // Une ombre douce sous les lignes, comme sous la réponse : lisibles
            // même là où le voile s'éclaircit.
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Theme.darkMode ? "#000000" : "#ffffff"
                shadowBlur: 0.8
                shadowOpacity: 0.8
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 1
            }

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

                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: Qt.alpha(bar.hue(0), row.current ? 0.22 : 0.1)
                    opacity: row.current || rowMa.containsMouse ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                // L'icône, à la taille du flocon de la barre.
                Item {
                    id: rowIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 11
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

                // Un réglage se règle sur place : son contrôle prend la place
                // du type, à droite.
                readonly property string control: bar.controlFor(row.modelData)

                Text {
                    id: kind
                    visible: row.control === ""
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: bar.typeLabels[row.modelData.type] || row.modelData.type
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Theme.textDim
                }

                // Le nom, puis où il se trouve, en plus discret.
                Row {
                    anchors.left: rowIcon.right
                    anchors.leftMargin: 11
                    anchors.right: row.control === "" ? kind.left : controlSlot.left
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
                        text: row.control === "" ? row.modelData.subtitle || "" : ""
                        elide: Text.ElideRight
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
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    active: row.control !== ""
                    sourceComponent: row.control === "theme" ? themeControl
                                   : row.control === "volume" ? volumeControl
                                   : row.control === "accent" ? accentControl
                                   : row.control === "screens" ? screensControl : null
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
        implicitWidth: bar.barW + 2 * glow.pad + 60
        implicitHeight: bar.barH + 2 * glow.pad + 40
        color: "transparent"
        mask: Region {} // qmllint disable unqualified

        // L'ombre portée de la capsule, découpée à sa forme : elle ne
        // passe jamais sous le verre.
        Item {
            id: shadowShape
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                x: (parent.width - pill.width) / 2
                y: parent.height - bar.gap - pill.height + 6
                width: pill.width
                height: pill.height
                radius: height / 2
                color: "#000000"
            }
        }
        Item {
            id: pillShape
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                x: (parent.width - pill.width) / 2
                y: parent.height - bar.gap - pill.height
                width: pill.width
                height: pill.height
                radius: height / 2
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
            maskEnabled: true
            maskSource: pillShape
            maskInverted: true
        }

        Item {
            id: glow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.gap - glow.pad
            width: pill.width + 2 * pad
            height: pill.height + 2 * pad
            scale: pill.scale

            readonly property int pad: 10
            readonly property real thickness: 2.5
            property real angle: 0

            opacity: bar.glowing ? (bar.voiceOn ? 1 : 0.65) : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

            NumberAnimation on angle {
                from: 0
                to: 360
                duration: 3200
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
                        GradientStop { position: 0.25; color: bar.hue(0.14) }
                        GradientStop { position: 0.5;  color: bar.hue(-0.12) }
                        GradientStop { position: 0.75; color: bar.hue(0.3) }
                        GradientStop { position: 1.0;  color: bar.hue(0) }
                    }
                    PathRectangle {
                        x: glow.pad - glow.thickness
                        y: glow.pad - glow.thickness
                        width: pill.width + 2 * glow.thickness
                        height: pill.height + 2 * glow.thickness
                        radius: height / 2
                    }
                    PathRectangle {
                        x: glow.pad
                        y: glow.pad
                        width: pill.width
                        height: pill.height
                        radius: height / 2
                    }
                }
            }

            // La lueur, qui respire avec la voix.
            MultiEffect {
                anchors.fill: ring
                source: ring
                blurEnabled: true
                blur: 1.0
                blurMax: 24
                opacity: 0.75
                scale: 1.0 + (ClaudeLive.voicePhase === "listening" ? ClaudeLive.voiceLevel * 0.06 : 0)
                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }

            MultiEffect {
                anchors.fill: ring
                source: ring
            }
        }
    }

    Item {
        id: pill
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.barW
        height: bar.barH

        // Elle monte du bord de l'écran en grandissant un peu ; elle
        // redescend en se rétractant.
        opacity: bar.shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        transform: [
            Scale {
                origin.x: pill.width / 2
                origin.y: pill.height
                xScale: bar.shown ? 1 : 0.85
                yScale: xScale
                Behavior on xScale { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.002 } }
            },
            Translate {
                y: bar.shown ? 0 : pill.height + bar.gap
                Behavior on y { SpringAnimation { spring: 3.5; damping: 0.32; epsilon: 0.1 } }
            }
        ]

        HoverHandler { id: pillHover }

        // Un petit tassement quand une demande part, relâché sur un ressort.
        SequentialAnimation {
            id: sendBounce
            NumberAnimation { target: pill; property: "scale"; to: 0.96; duration: 90; easing.type: Easing.OutQuad }
            SpringAnimation { target: pill; property: "scale"; to: 1.0; spring: 4.5; damping: 0.22; epsilon: 0.002 }
        }

        // ── Le verre ─────────────────────────────────────────────
        // Translucide : Hyprland floute ce qui passe derrière (même règle de
        // couche que le voile de la réponse). Son ombre portée vit avec le
        // halo, dans la surface sans flou.
        Rectangle {
            id: glass
            anchors.fill: parent
            radius: height / 2
            color: Qt.alpha(Theme.bgDeep, Theme.darkMode ? 0.62 : 0.7)
            border.width: 1
            border.color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.08)
        }

        // Le reflet : un liseré clair en haut, qui s'éteint vers le milieu.
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: height / 2
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(1, 1, 1, 0.55) }
                GradientStop { position: 0.55; color: "transparent" }
            }
        }

        // ── Le flocon : s'allume quand karenine écoute ───────────
        Item {
            id: logo
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 24

            // Transcription ou pilote au travail : il tourne doucement.
            readonly property bool turning: ClaudeLive.voicePhase === "transcribing" || ClaudeLive.pilotBusy
            // Revient droit une fois le travail fini.
            onTurningChanged: if (!turning) settle.restart()

            // « Karénine » entendu : il saute, comme une icône du Dock.
            Connections {
                target: bar
                function onVoiceOnChanged() {
                    if (bar.voiceOn) {
                        bar.dismissed = false;
                        pop.restart();
                    }
                }
            }

            Item {
                id: flake
                anchors.fill: parent
                transformOrigin: Item.Center

                property real popScale: 1.0
                scale: popScale * (logoMa.pressed ? 0.86
                       : ClaudeLive.voicePhase === "listening" ? 1.0 + ClaudeLive.voiceLevel * 0.22
                       : logoMa.containsMouse ? 1.1 : 1.0)
                Behavior on scale { SpringAnimation { spring: 5; damping: 0.3; epsilon: 0.002 } }

                SequentialAnimation {
                    id: pop
                    NumberAnimation { target: flake; property: "popScale"; to: 1.45; duration: 140; easing.type: Easing.OutCubic }
                    SpringAnimation { target: flake; property: "popScale"; to: 1.0; spring: 4; damping: 0.2; epsilon: 0.002 }
                }

                RotationAnimation on rotation {
                    running: logo.turning
                    loops: Animation.Infinite
                    from: flake.rotation
                    to: flake.rotation + 360
                    duration: 2400
                }
                NumberAnimation {
                    id: settle
                    target: flake
                    property: "rotation"
                    to: Math.round(flake.rotation / 60) * 60
                    duration: 420
                    easing.type: Easing.OutBack
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

                // L'artwork est blanc : recoloré au thème, et auréolé de
                // l'accent quand il s'allume.
                MultiEffect {
                    anchors.fill: flakeSource
                    source: flakeSource
                    colorization: 1.0
                    colorizationColor: bar.voiceOn ? bar.hue(0.05) : Theme.iconColor
                    opacity: bar.voiceOn || logo.turning ? 1.0 : (logoMa.containsMouse ? 0.95 : 0.75)
                    shadowEnabled: true
                    shadowColor: bar.hue(0)
                    shadowBlur: 1.0
                    shadowOpacity: bar.voiceOn ? 1.0 : 0
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                    Behavior on colorizationColor { ColorAnimation { duration: 260 } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    Behavior on shadowOpacity { NumberAnimation { duration: 300 } }
                }
            }

            MouseArea {
                id: logoMa
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Parler au pilote, ou couper l'écoute en cours.
                onClicked: ClaudeLive.voiceToggle(true)
            }
        }

        // ── À droite : envoyer, ou la voix qui ondule ────────────
        Item {
            id: accessory
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28

            // Le bouton d'envoi, qui éclot quand il y a quelque chose à envoyer.
            Rectangle {
                id: sendBtn
                anchors.centerIn: parent
                width: 26
                height: 26
                radius: 13
                color: bar.hue(0)
                readonly property bool on: input.text.trim().length > 0 && !bar.voiceOn
                opacity: on ? 1 : 0
                scale: on ? (sendMa.pressed ? 0.88 : 1) : 0.4
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 160 } }
                Behavior on scale { SpringAnimation { spring: 5; damping: 0.28; epsilon: 0.002 } }

                Text {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1
                    text: "↑"
                    font.family: bar.uiFont
                    font.pixelSize: 15
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

            // La forme d'onde : cinq barres qui suivent le niveau de la voix,
            // puis respirent ensemble pendant la transcription.
            Row {
                anchors.centerIn: parent
                spacing: 3
                readonly property bool on: bar.voiceOn
                opacity: on ? 1 : 0
                scale: on ? 1 : 0.5
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                Behavior on scale { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.002 } }

                Repeater {
                    model: [0.55, 0.85, 1.0, 0.8, 0.5]
                    Rectangle {
                        id: waveBar
                        required property real modelData
                        required property int index
                        anchors.verticalCenter: parent.verticalCenter
                        width: 3
                        radius: 1.5
                        color: bar.hue(waveBar.index * 0.06)

                        property real jitter: 1
                        height: ClaudeLive.voicePhase === "listening"
                                ? 4 + 16 * waveBar.modelData * Math.min(1, ClaudeLive.voiceLevel * 1.6) * jitter
                                : 4
                        Behavior on height { SpringAnimation { spring: 6; damping: 0.35; epsilon: 0.1 } }

                        Timer {
                            interval: 110 + waveBar.index * 23
                            repeat: true
                            running: ClaudeLive.voicePhase === "listening"
                            onTriggered: waveBar.jitter = 0.6 + Math.random() * 0.6
                        }

                        SequentialAnimation on opacity {
                            running: ClaudeLive.voicePhase === "transcribing"
                            loops: Animation.Infinite
                            alwaysRunToEnd: true
                            PauseAnimation { duration: waveBar.index * 90 }
                            NumberAnimation { to: 0.3; duration: 380; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 380; easing.type: Easing.InOutSine }
                        }
                    }
                }
            }
        }

        // ── Le champ ─────────────────────────────────────────────
        Item {
            id: field
            anchors.left: logo.right
            anchors.leftMargin: 11
            anchors.right: accessory.left
            anchors.rightMargin: 8
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            clip: true

            TextInput {
                id: input
                anchors.fill: parent
                verticalAlignment: TextInput.AlignVCenter
                opacity: bar.voiceOn ? 0 : 1
                enabled: !bar.voiceOn
                Behavior on opacity { NumberAnimation { duration: 180 } }
                font.family: bar.uiFont
                font.pixelSize: 14
                font.weight: Font.Medium
                color: Theme.textPrimary
                selectionColor: Qt.alpha(bar.hue(0), 0.45)
                selectedTextColor: Theme.textPrimary

                // La recherche suit la frappe ; la voix, elle, n'écrit pas ici.
                onTextChanged: Search.query = text

                Keys.onReturnPressed: bar.submit()
                Keys.onEnterPressed: bar.submit()
                // La liste est au-dessus : ↑ y monte, ↓ redescend vers le champ.
                Keys.onUpPressed: (event) => {
                    if (!bar.searching || Search.results.length === 0) {
                        event.accepted = false;
                        return;
                    }
                    bar.selected = Math.min(Search.results.length - 1, bar.selected + 1);
                }
                Keys.onDownPressed: (event) => {
                    if (bar.selected < 0) {
                        event.accepted = false;
                        return;
                    }
                    bar.selected--;
                }
                // Sur un réglage retenu (volume, accent), ← → le règlent ;
                // ailleurs ils déplacent le curseur du texte.
                Keys.onLeftPressed: (event) => event.accepted = bar.adjustSelected(-1)
                Keys.onRightPressed: (event) => event.accepted = bar.adjustSelected(1)
                // Une sélection en cours s'abandonne avant la barre.
                Keys.onEscapePressed: {
                    if (bar.selected >= 0)
                        bar.selected = -1;
                    else
                        bar.release();
                }

                onActiveFocusChanged: {
                    if (!activeFocus && bar.focusRequested)
                        bar.focusRequested = false;
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
                font.pixelSize: 14
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
                font.pixelSize: 14
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
