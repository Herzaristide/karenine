pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtCore
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Bluetooth
import Quickshell.Io
import "../services"
import "../widgets"

// La barre du bas : toujours là, sur toute la largeur de l'écran, de
// l'encre de la surface (panels/Surface.qml). Les fenêtres se posent
// au-dessus (exclusiveZone) ; ce qui en sort — les suggestions, la réponse
// du pilote, les volets — y reste attaché par des coins creusés
// (widgets/Lip.qml).
//
//  ⏻ 14:32 │ ⌂ ▣▣ ♫ 4 5 │ ❄  Demander à Karénine…      ᯤ ᛒ │ 🔊 🎤 │ ⌗ ● │ ☑ 🔔 │ ▯64 % ▮87 % │ ✦
//  l'heure   workspaces    le flocon, puis le champ     connexions audio   capture  tâches,   téléphone, batterie  le panneau
//                                                                                   notif.
//
// Les workspaces 1-5 de l'écran montrent les icônes de leurs fenêtres ; un
// clic y va. Le flocon ouvre son volet : les outils de karenine et les
// applications (widgets/AppsPop.qml). Le micro, au bout du champ, parle au
// pilote : la phrase s'écrit dans le champ pendant qu'on parle (anna la
// transcrit en local), puis part au pilote ; le mot d'éveil fait la même
// chose. Ce qu'on tape
// cherche (applications, fichiers, réglages, web — le service Search) et
// part au pilote avec Entrée.
//
// À droite, les groupes : chaque icône ouvre son volet au-dessus d'elle, un
// seul à la fois ; un clic ailleurs dans la barre, Échap ou la même icône le
// referme. Le dernier bouton montre ou cache le panneau de droite.
PanelWindow { // qmllint disable uncreatable-type
    id: bar

    // Le champ a le clavier : Super l'a appelé (cf. toggle).
    property bool focusRequested: false

    readonly property int barH: 48
    // Le vide au-dessus des boutons (30 px, centrés dans la barre) : laissé
    // hors de la zone réservée, pour que l'écart entre une fenêtre et les
    // boutons soit le gaps_out d'Hyprland (18), comme entre deux fenêtres.
    readonly property int padTop: (bar.barH - 30) / 2
    // La place au-dessus de la barre, pour ce qui en sort.
    readonly property int above: 560
    readonly property string uiFont: "Inter"

    // Top : sous une fenêtre en plein écran, la barre s'efface avec le reste.
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-bar"
    // Exclusif le temps d'écrire (le champ, ou le mot de passe d'un réseau
    // Wi-Fi) : une surface layer ne reçoit les frappes qu'une fois cliquée
    // sinon. Pas pendant un glisser depuis l'explorateur : Hyprland ne
    // donnerait plus le pointeur aux fenêtres, qui ne verraient jamais le
    // fichier arriver.
    // Le clavier rendu, un instant à personne : Hyprland le redonne aussitôt
    // à la fenêtre d'avant (en OnDemand, la barre le garderait jusqu'au
    // prochain clic ailleurs, et les frappes s'y perdraient).
    WlrLayershell.keyboardFocus: bar.dropKeyboard ? WlrKeyboardFocus.None
                                 : bar.focusRequested && !DragState.active
                                 ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    anchors { // qmllint disable unqualified unresolved-type
        left: true
        right: true
        bottom: true
    }
    exclusiveZone: bar.barH - bar.padTop
    implicitHeight: bar.barH + bar.above
    color: "transparent"

    // Seule la barre et ce qui en sort prennent la souris : le reste de la
    // fenêtre laisse passer les clics aux fenêtres de dessous.
    mask: Region { // qmllint disable unqualified
        Region { item: strip }
    }

    // ── Le clavier ───────────────────────────────────────────────
    // Super : le champ prend le clavier s'il ne l'a pas, le rend sinon.
    function toggle() {
        if (bar.focusRequested || input.activeFocus)
            bar.release();
        else
            bar.focusRequested = true;
    }

    // Tout repart : le texte, la recherche, la réponse, le volet. Le
    // pilote, lui, continue son travail.
    function dismiss() {
        bar.pop = "";
        bar.release();
    }

    function release() {
        var had = bar.focusRequested;
        input.text = "";
        answer.hide();
        bar.selected = -1;
        bar.focusRequested = false;
        input.focus = false;
        if (had)
            bar.dropFocus();
    }

    // Le champ appelé par Super rend le clavier au moindre geste : la souris
    // qui s'en va, un autre bureau, une fenêtre qui s'ouvre. Vide, il repart
    // comme d'un Échap ; ce qu'on y avait tapé reste, un clic le reprend.
    function loseFocus() {
        if (!bar.focusRequested)
            return;
        if (input.text.length === 0) {
            bar.release();
            return;
        }
        bar.focusRequested = false;
        input.focus = false;
        bar.dropFocus();
    }

    property bool dropKeyboard: false
    function dropFocus() {
        bar.dropKeyboard = true;
        dropTimer.restart();
    }
    Timer {
        id: dropTimer
        interval: 120
        onTriggered: bar.dropKeyboard = false
    }

    // La souris sur la barre, ses suggestions ou sa réponse : on s'en sert.
    readonly property bool pointerInside: stripHover.hovered || answerHover.hovered || resultsHover.hovered

    // Le pointeur, suivi tant que le champ tient le clavier (Hyprland ne dit
    // pas quand il bouge ailleurs, et une surface n'en voit que ce qui passe
    // sur elle). Il bouge hors de la barre : le champ rend le clavier.
    property point cursorOrigin: Qt.point(0, 0)
    property bool cursorKnown: false
    Timer {
        interval: 80
        repeat: true
        triggeredOnStart: true
        running: bar.focusRequested
        onRunningChanged: bar.cursorKnown = false
        onTriggered: if (!cursorProc.running) cursorProc.running = true
    }
    Process {
        id: cursorProc
        command: ["hyprctl", "cursorpos"]
        stdout: StdioCollector { id: cursorOut }
        onRunningChanged: if (!running) bar.cursorAt(cursorOut.text)
    }
    function cursorAt(text) {
        if (!bar.focusRequested)
            return;
        var m = /(-?\d+)\s*,\s*(-?\d+)/.exec(text);
        if (!m)
            return;
        var p = Qt.point(Number(m[1]), Number(m[2]));
        if (!bar.cursorKnown || bar.pointerInside) {
            bar.cursorOrigin = p;
            bar.cursorKnown = true;
            return;
        }
        if (Math.abs(p.x - bar.cursorOrigin.x) + Math.abs(p.y - bar.cursorOrigin.y) > 10)
            bar.loseFocus();
    }

    // Un autre bureau, un autre écran, une fenêtre qui s'ouvre (un raccourci
    // tapé par-dessus) : le geste est ailleurs.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!bar.focusRequested)
                return;
            switch (event.name) {
            case "workspacev2":
            case "focusedmonv2":
            case "activespecialv2":
            case "openwindow":
                bar.loseFocus();
            }
        }
    }

    onFocusRequestedChanged: {
        if (focusRequested) {
            dropTimer.stop();
            bar.dropKeyboard = false;
            bar.pop = "";
            input.forceActiveFocus();
        } else if (input.text.length === 0) {
            input.focus = false;
        }
    }

    function submit() {
        if (bar.selected >= 0) {
            bar.activateResult(Search.results[bar.selected]);
            return;
        }
        // « tâche … » : Entrée ajoute la tâche plutôt que de la demander
        // au pilote. Relue ici : la liste peut avoir une frappe de retard.
        var task = Search.taskSource.parse(input.text);
        if (task.asked && task.title !== "" && Google.connected) {
            bar.activateResult({ type: "task", payload: task });
            return;
        }
        var text = input.text.trim();
        if (text.length === 0)
            return;
        bar.launch(text);
        Pilot.pilotAsk(text, false);
        input.text = "";
        answer.clearNotice();
        answer.show();
        // Le clavier redevient libre : un clic dans le champ le reprend.
        bar.focusRequested = false;
    }

    // Le bouton du panneau de droite, compté depuis le bord droit de
    // l'écran : le panneau sort de lui (SidePanel).
    readonly property real panelButtonInset: tray.anchors.rightMargin
    readonly property real panelButtonWidth: panelBtn.width

    // ── Les volets ───────────────────────────────────────────────
    // Le volet ouvert ("" : aucun) et le bouton sous lequel il se tient.
    property string pop: ""
    property Item popAnchor: null
    // Le volet en tiroir ("" : aucun). Le téléphone et l'alimentation n'en
    // ont pas : leurs boutons montent en colonne au-dessus d'eux (BarStack).
    readonly property string drawer: bar.pop === "phone" || bar.pop === "power" ? "" : bar.pop

    function togglePop(name, button) {
        if (bar.pop === name) {
            bar.pop = "";
            return;
        }
        bar.popAnchor = button;
        bar.pop = name;
    }

    // Un volet demandé d'ailleurs (le pilote, la FIFO : Widgets.apply),
    // ouvert sous son bouton comme d'un clic. Il reste jusqu'à ce que la
    // souris y passe puis le quitte, ou qu'on le referme.
    Connections {
        target: Widgets
        function onPopRequested(name, action) {
            var buttons = {
                sound: soundBtn, mic: micBtn, wifi: wifiBtn, bluetooth: btBtn, phone: phoneBtn,
                notifications: notifBtn, tasks: tasksBtn, power: powerBtn, apps: logo,
                energy: batteryBtn.visible ? batteryBtn : clockBtn
            };
            var on = action === "ouvrir" ? true
                   : action === "fermer" ? false
                   : bar.pop !== name;
            if (on) {
                bar.popAnchor = buttons[name] || null;
                bar.pop = name;
            } else if (bar.pop === name) {
                bar.pop = "";
            }
        }
    }

    // Le volet se referme quand la souris le quitte : ni sur lui, ni sur la
    // colonne de son bouton (le chemin de l'un à l'autre). Pas avant que la
    // souris y soit passée une fois, ni tant qu'un champ du volet a le
    // clavier (le mot de passe d'un Wi-Fi).
    readonly property bool anchorHovered: {
        if (!bar.popAnchor || !stripHover.hovered)
            return false;
        var p = bar.popAnchor.mapFromItem(strip, stripHover.point.position.x, 0);
        return p.x >= 0 && p.x < bar.popAnchor.width;
    }
    readonly property bool popHovered: bar.pop !== ""
        && (bar.anchorHovered || popHover.hovered || phoneHover.hovered || powerHover.hovered)
    property bool popArmed: false

    onPopChanged: bar.popArmed = bar.popHovered
    onPopHoveredChanged: {
        if (bar.popHovered) {
            bar.popArmed = true;
            popLeave.stop();
        } else if (bar.popArmed) {
            popLeave.restart();
        }
    }

    Timer {
        id: popLeave
        interval: 350
        onTriggered: {
            // Un champ qui a le clavier garde le volet ouvert ; celui des
            // tâches, qui le prend dès l'ouverture, seulement s'il a du texte.
            var f = popHost.Window.activeFocusItem as TextInput;
            if (bar.popHovered || (f !== null && (bar.pop !== "tasks" || f.text !== "")))
                return;
            bar.pop = "";
        }
    }

    // La largeur du contenu de chaque volet.
    readonly property var popWidths: ({
        "wifi": 320, "bluetooth": 320, "sound": 300, "mic": 300,
        "notifications": 380, "energy": 300, "tasks": 380, "apps": 400
    })

    // ── La recherche ─────────────────────────────────────────────
    // Ce qu'on tape part aussi dans Search ; tant qu'il y a des suggestions,
    // elles passent devant la réponse du pilote.
    readonly property bool searching: Search.active && !bar.voiceOn
    // La suggestion retenue au clavier ; -1 : Entrée va au pilote.
    property int selected: -1

    // La liste ne change qu'une fois par frappe (Search) : taper ramène
    // déjà au champ.
    // ↑ pressé pendant le chargement : il s'applique à l'arrivée de la
    // liste, sur sa première ligne.
    property bool pendingUp: false
    Connections {
        target: Search
        function onResultsChanged() {
            bar.selected = -1;
        }
        function onLoadingChanged() {
            if (Search.loading)
                return;
            if (bar.pendingUp && Search.results.length > 0)
                bar.selected = 0;
            bar.pendingUp = false;
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

    // ↑ ↓ dans la liste (la meilleure en bas, contre le champ) : ↑ y entre
    // par la première, ↓ depuis elle revient au champ (-1). Vrai s'ils ont
    // servi.
    function rowStep(dir) {
        // Pendant le chargement, la liste à l'écran est celle de la frappe
        // d'avant : on n'y entre pas, ↑ attend la nouvelle.
        if (Search.loading && bar.searching) {
            bar.pendingUp = dir > 0;
            return true;
        }
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
                  "accent": "accent", "screen": "screens", "language": "screens" })[item.payload.key] || "";
    }

    // La couleur d'accent à une teinte donnée : saturation et luminosité ne
    // bougent pas, comme quand on la fait tourner aux flèches (SettingSource).
    function accentAt(h) {
        var c = Theme.accentColor;
        return Qt.hsva(h, Math.max(0.35, c.hsvSaturation), Math.max(0.35, c.hsvValue), 1);
    }
    readonly property real accentHue: Theme.accentColor.hsvHue < 0 ? 0 : Theme.accentColor.hsvHue

    // Une icône de assets/icons (Phosphor), que la ligne teinte.
    readonly property string glyphDir: "../assets/icons/"
    function glyph(name) {
        return bar.glyphDir + name + ".svg";
    }

    // L'icône d'un résultat : celle de l'application (prise au thème), une
    // image qui se montre elle-même, ou une icône de assets/icons ; vide,
    // l'initiale prend le relais.
    function iconFor(item) {
        var p = item.payload || {};
        switch (item.type) {
        case "app":
            return p.entry && p.entry.icon ? Theme.icon(p.entry.icon, true) : "";
        case "file":
            if (p.isDir)
                return bar.glyph("folder");
            if (bar.imageSuffixes.indexOf((p.suffix || "").toLowerCase()) !== -1)
                return "file://" + p.path.split("/").map(encodeURIComponent).join("/");
            return bar.glyph("file-text");
        case "web":
            return DefaultApps.browser ? DefaultApps.browser.icon : "";
        case "wallpaper":
            return bar.glyph("wallpaper");
        case "task":
            return bar.glyph("check");
        case "note":
            if (p.create)
                return bar.glyph("file-new");
            if (p.note && p.note.image)
                return "file://" + p.note.image.split("/").map(encodeURIComponent).join("/");
            return bar.glyph("notes");
        case "setting":
            switch (p.key) {
            case "volume":     return bar.glyph("volume");
            case "theme":      return bar.glyph("theme");
            case "accent":     return bar.glyph("accent");
            case "screenshot": return bar.glyph("screenshot");
            case "language":   return bar.glyph("language");
            }
        }
        return "";
    }

    readonly property var imageSuffixes: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
    readonly property var typeLabels: ({
        "app": I18n.tr("search.type.app"), "file": I18n.tr("search.type.file"),
        "setting": I18n.tr("search.type.setting"), "web": I18n.tr("search.type.web"),
        "wallpaper": I18n.tr("search.type.wallpaper"), "note": I18n.tr("search.type.note"),
        "task": I18n.tr("search.type.task")
    })

    // ── Le dernier tour du pilote ────────────────────────────────
    // Les éléments depuis la dernière demande : { heard, actions, reply,
    // failed }.
    readonly property var turn: {
        var items = Pilot.pilotItems;
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

    readonly property bool voiceOn: Pilot.voicePhase !== "idle"
    readonly property bool glowing: bar.voiceOn || Pilot.pilotBusy

    // Le niveau de la voix, lissé : le halo et l'onde le suivent sans
    // à-coups.
    property real level: Pilot.voicePhase === "listening" ? Math.min(1, Pilot.voiceLevel * 1.5) : 0
    Behavior on level { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    // Le pilote a fini sur une question (« quelle fenêtre ? ») : la réponse
    // reste affichée jusqu'à ce qu'on y réponde.
    readonly property bool asking: !Pilot.pilotBusy && bar.turn !== null
                                   && !bar.turn.failed && bar.turn.reply.trim().endsWith("?")

    // Une nouvelle demande commence : la réponse d'avant lui laisse la
    // place.
    onVoiceOnChanged: {
        if (bar.voiceOn) {
            bar.pop = "";
            if (!Pilot.pilotBusy)
                answer.hide();
        }
    }

    Connections {
        target: Pilot
        // Une demande partie d'ailleurs (la voix, `anna`) : sa réponse
        // s'affiche ici aussi.
        function onPilotBusyChanged() {
            if (Pilot.pilotBusy) {
                // Une demande part : la conversation, pas un vieux message.
                answer.clearNotice();
                answer.show();
            }
        }
        function onPilotDone() {
            answer.settle();
        }
        // Une vraie panne de la voix (modèle absent, micro…) : dite une
        // fois, brièvement, et partie d'elle-même.
        function onVoiceErrorChanged() {
            if (Pilot.voiceError.length > 0)
                answer.flash(Pilot.voiceError);
        }
    }

    // ── Les workspaces ───────────────────────────────────────────
    // Les principaux (1-5) de l'écran de l'interface (cf. Display) : les
    // autres appartiennent chacun à son écran.
    readonly property var monitor: bar.screen ? Hyprland.monitorFor(bar.screen) : null
    readonly property int currentWs: bar.monitor && bar.monitor.activeWorkspace
                                     ? bar.monitor.activeWorkspace.id : -1

    // Les fenêtres d'un workspace, en pictogrammes génériques (assets/ui) :
    // une famille par application — terminal, code, navigateur, fichiers… —,
    // trois au plus, chaque famille une fois. La famille vient des
    // catégories de son entrée de bureau, à défaut de son identifiant
    // Wayland (sa classe pour XWayland) ; une inconnue reste « app ».
    readonly property var families: [
        { glyph: "terminal", cats: ["TerminalEmulator"],
          ids: /kitty|alacritty|foot|wezterm|ghostty|konsole|terminal|xterm|tilix|terminator/i },
        { glyph: "code", cats: ["IDE", "Development", "TextEditor"],
          ids: /code|codium|zed|jetbrains|idea|pycharm|clion|rustrover|webstorm|nvim|neovide|gedit|kate|emacs|sublime/i },
        { glyph: "globe", cats: ["WebBrowser"],
          ids: /firefox|chrom|brave|vivaldi|zen|librewolf|qutebrowser|epiphany|opera/i },
        { glyph: "folder", cats: ["FileManager"], ids: /nautilus|thunar|dolphin|nemo|pcmanfm|yazi/i },
        { glyph: "chat", cats: ["Chat", "InstantMessaging"],
          ids: /discord|vesktop|slack|telegram|signal|element|whatsapp|teams/i },
        { glyph: "mail", cats: ["Email"], ids: /thunderbird|evolution|geary|mail/i },
        { glyph: "music", cats: ["Audio", "Music", "Midi"], ids: /reaper|spotify|ardour|bitwig|audacity|music/i },
        { glyph: "video", cats: ["Video", "Player"], ids: /mpv|vlc|celluloid|obs|kdenlive|shotcut/i },
        { glyph: "paint", cats: ["2DGraphics", "3DGraphics", "RasterGraphics", "VectorGraphics"],
          ids: /gimp|krita|inkscape|blender|darktable|figma/i },
        // Avant les images : une liseuse de PDF se dit aussi « Viewer ».
        { glyph: "file", cats: ["Office", "WordProcessor", "Spreadsheet"],
          ids: /libreoffice|soffice|onlyoffice|evince|zathura|okular|papers/i },
        { glyph: "image", cats: ["Viewer", "Photography"], ids: /imv|eog|loupe|feh|gwenview|nomacs/i },
        { glyph: "game", cats: ["Game"], ids: /steam|lutris|heroic|minecraft|prism/i }
    ]

    function familyOf(app) {
        var entry = DesktopEntries.heuristicLookup(app);
        var cats = entry && entry.categories ? entry.categories : [];
        for (var i = 0; i < bar.families.length; i++) {
            var f = bar.families[i];
            if (f.ids.test(app) || f.cats.some(c => cats.indexOf(c) !== -1))
                return f.glyph;
        }
        return "app";
    }

    function wsIcons(id) {
        var ws = Hyprland.workspaces.values.find(w => w.id === id);
        if (!ws)
            return [];
        var out = [];
        var tops = ws.toplevels.values;
        for (var i = 0; i < tops.length && out.length < 3; i++) {
            var t = tops[i];
            var app = t.wayland ? t.wayland.appId : (t.lastIpcObject && t.lastIpcObject.class) || "";
            var glyph = bar.familyOf(app);
            if (out.indexOf(glyph) === -1)
                out.push(glyph);
        }
        return out;
    }

    // La syntaxe Lua des dispatchers, comme anna (anna/src/claude/desk.rs) :
    // un workspace qui n'existe pas encore est créé.
    function goTo(id) {
        Hyprland.dispatch("hl.dsp.focus({ workspace = " + id + " })");
    }

    // ── La capture d'écran ───────────────────────────────────────
    // Clic : une région ; clic droit : l'écran entier. Copiée et enregistrée
    // dans le dossier Images. Le volet se ferme d'abord, et on attend qu'il
    // ait disparu pour ne pas le capturer.
    readonly property string picturesDir:
        StandardPaths.writableLocation(StandardPaths.PicturesLocation).toString().replace(/^file:\/\//, "")

    function screenshot(region) {
        bar.dismiss();
        shotTimer.region = region;
        shotTimer.restart();
    }

    Timer {
        id: shotTimer
        property string region: "area"
        interval: 350
        onTriggered: {
            var path = bar.picturesDir + "/capture-"
                     + Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss") + ".png";
            Quickshell.execDetached(["grimblast", "--notify", "copysave", shotTimer.region, path]);
        }
    }

    // L'enregistrement de l'écran, tenu par anna (services/Recorder.qml) :
    // clic, une région ; clic droit, l'écran qui a le focus.
    function screenRecord(region) {
        bar.dismiss();
        recTimer.region = region;
        recTimer.restart();
    }

    Timer {
        id: recTimer
        property string region: "area"
        interval: 350
        onTriggered: Recorder.toggleScreen(recTimer.region)
    }

    // ── Le Bluetooth, pour la teinte de son bouton ───────────────
    readonly property bool btPowered: Bluetooth.defaultAdapter !== null && Bluetooth.defaultAdapter.enabled // qmllint disable unresolved-type
    readonly property bool btConnected: bar.btPowered
                                        && Bluetooth.defaultAdapter.devices.values.some(d => d.connected) // qmllint disable unresolved-type

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // ── Un curseur fin, pour les réglages des suggestions ────────
    component BarSlider: Item {
        id: slider

        property real value: 0
        property color knobColor: Theme.accentColor
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
                GradientStop { position: 0 / 6; color: bar.accentAt(0 / 6) }
                GradientStop { position: 1 / 6; color: bar.accentAt(1 / 6) }
                GradientStop { position: 2 / 6; color: bar.accentAt(2 / 6) }
                GradientStop { position: 3 / 6; color: bar.accentAt(3 / 6) }
                GradientStop { position: 4 / 6; color: bar.accentAt(4 / 6) }
                GradientStop { position: 5 / 6; color: bar.accentAt(5 / 6) }
                GradientStop { position: 6 / 6; color: bar.accentAt(0.999) }
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
            border.color: Theme.bgDeep
        }
        MouseArea {
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
                text: Theme.darkMode ? I18n.tr("theme.dark") : I18n.tr("theme.light")
                font.family: bar.uiFont
                font.pixelSize: 11
                color: Theme.textSecondary
            }
            Rectangle {
                width: 34
                height: 18
                radius: 9
                color: Theme.darkMode ? Theme.accentColor : Qt.alpha(Theme.textPrimary, 0.22)
                Behavior on color { ColorAnimation { duration: 160 } }
                Rectangle {
                    y: 2
                    x: Theme.darkMode ? parent.width - width - 2 : 2
                    width: 14
                    height: 14
                    radius: 7
                    color: Theme.darkMode ? Theme.bgDeep : "#ffffff"
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
            BarSlider {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 140
                value: Audio.level
                knobColor: Audio.muted ? Theme.textDim : Theme.accentColor
                onMoved: (v) => Audio.set(v)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 40
                text: Audio.muted ? I18n.tr("volume.muted") : I18n.tr("common.percent", { n: Audio.percent })
                horizontalAlignment: Text.AlignRight
                font.family: bar.uiFont
                font.pixelSize: 11
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
            value: bar.accentHue
            knobColor: bar.accentAt(accentSlider.shown)
            onCommitted: (v) => Theme.setAccentColor(bar.accentAt(Math.min(v, 0.999)).toString())
        }
    }

    // ── Petits éléments de la barre ──────────────────────────────
    component Separator: Rectangle {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: 1
        height: 20
        color: Qt.alpha(Theme.textPrimary, 0.14)
    }

    Item {
        id: root
        anchors.fill: parent

        // Un clic ailleurs dans la barre referme le volet.
        MouseArea {
            anchors.fill: strip
            enabled: bar.pop !== ""
            onClicked: bar.pop = ""
        }

        Component { id: wifiPop; WifiSettings {} }
        Component {
            id: btPop
            BluetoothMenu {
                open: true
                fontFamily: bar.uiFont
                color: "transparent"
                border.width: 0
            }
        }
        Component { id: soundPop; SoundDevices { input: false } }
        Component { id: micPop; SoundDevices { input: true } }
        Component {
            id: notifPop
            NotificationCenter {}
        }
        Component { id: energyPop; EnergyCard {} }
        Component { id: appsPop; AppsPop { onLaunched: bar.pop = "" } }
        Component {
            id: tasksPop
            TaskList {
                compact: true
                onOpenTask: (task) => {
                    bar.pop = "";
                    Widgets.showTasks(task);
                }
                onOpenAll: {
                    bar.pop = "";
                    Widgets.showTasks(null);
                }
            }
        }

        // ── La barre ─────────────────────────────────────────────
        Rectangle {
            id: strip
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: bar.barH
            color: Theme.bgDeep

            HoverHandler { id: stripHover }

            // ── À gauche : l'alimentation, puis l'heure ──
            Row {
                id: machineRow
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                BarButton {
                    id: powerBtn
                    icon: "power.svg"
                    on: bar.pop === "power"
                    onClicked: bar.togglePop("power", powerBtn)
                }
                // Sans batterie, la luminosité reste à portée sous l'heure.
                BarPill {
                    id: clockBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: clockText.implicitWidth + 16
                    height: 34
                    interactive: !Battery.present && Brightness.present
                    on: !Battery.present && bar.pop === "energy"
                    onClicked: bar.togglePop("energy", clockBtn)

                    Text {
                        id: clockText
                        anchors.centerIn: parent
                        text: Qt.formatTime(clock.date, "HH:mm")
                        font.family: bar.uiFont
                        font.pixelSize: 14
                        font.weight: Font.Medium
                        font.features: { "tnum": 1 }
                        color: Theme.textPrimary
                    }
                }
            }

            Separator {
                id: machineSep
                anchors.left: machineRow.right
                anchors.leftMargin: 14
            }

            // ── Les workspaces ──
            Row {
                id: wsRow
                anchors.left: machineSep.right
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Repeater {
                    model: [1, 2, 3, 4, 5]

                    BarPill {
                        id: wsButton
                        required property int modelData
                        readonly property bool focused: wsButton.modelData === bar.currentWs
                        readonly property var icons: bar.wsIcons(wsButton.modelData)

                        width: Math.max(30, wsIconsRow.implicitWidth + 16)
                        height: 30
                        on: wsButton.focused
                        rest: wsButton.icons.length > 0
                        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                        onClicked: bar.goTo(wsButton.modelData)

                        // Vide : son numéro.
                        Text {
                            anchors.centerIn: parent
                            visible: wsButton.icons.length === 0
                            text: wsButton.modelData
                            font.family: bar.uiFont
                            font.pixelSize: 13
                            font.weight: wsButton.focused ? Font.DemiBold : Font.Medium
                            font.features: { "tnum": 1 }
                            color: wsButton.focused ? Theme.accentColor : wsButton.hovered ? Theme.textSecondary : Theme.textDim
                            Behavior on color { ColorAnimation { duration: 220 } }
                        }

                        // Occupé : les icônes de ses fenêtres.
                        Row {
                            id: wsIconsRow
                            anchors.centerIn: parent
                            spacing: 6
                            visible: wsButton.icons.length > 0

                            Repeater {
                                model: wsButton.icons

                                NixIcon {
                                    id: appIcon
                                    required property string modelData
                                    iconSize: 16
                                    source: "../assets/ui/" + appIcon.modelData + ".svg"
                                    color: wsButton.focused ? Theme.accentColor : Theme.iconColor
                                    opacity: wsButton.focused || wsButton.hovered ? 1 : 0.75
                                    Behavior on color { ColorAnimation { duration: 220 } }
                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                    // Une fenêtre arrive : son icône éclot.
                                    scale: 0.4
                                    Component.onCompleted: scale = 1
                                    Behavior on scale { NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 1.8 } }
                                }
                            }
                        }
                    }
                }
            }

            Separator {
                id: wsSep
                anchors.left: wsRow.right
                anchors.leftMargin: 14
            }

            // ── Le flocon : les outils et les applications ──
            Item {
                id: logo
                anchors.left: wsSep.right
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                width: 30
                height: 30

                // Pendant l'écoute : un halo de l'accent qui respire avec la voix.
                Rectangle {
                    anchors.centerIn: parent
                    width: 38 + 10 * bar.level
                    height: width
                    radius: width / 2
                    color: Theme.selectedFill
                    opacity: bar.voiceOn || bar.pop === "apps" ? 1 : logoMa.containsMouse ? 0.6 : 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                Item {
                    id: flake
                    anchors.fill: parent
                    transformOrigin: Item.Center
                    scale: logoMa.pressed ? 0.9 : 1
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    // Écoute, transcription ou pilote au travail : il tourne
                    // doucement, puis revient droit.
                    readonly property bool turning: bar.voiceOn || Pilot.pilotBusy
                    onTurningChanged: if (!turning) settle.restart()

                    RotationAnimation on rotation {
                        running: flake.turning
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
                    MultiEffect {
                        anchors.fill: flakeSource
                        source: flakeSource
                        colorization: 1.0
                        colorizationColor: Theme.accentColor
                    }
                }

                MouseArea {
                    id: logoMa
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: bar.togglePop("apps", logo)
                }
            }

            // ── Le champ ──
            Item {
                id: field
                anchors.left: logo.right
                anchors.leftMargin: 14
                anchors.right: tray.left
                anchors.rightMargin: 16
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                clip: true

                TextInput {
                    id: input
                    anchors.left: parent.left
                    anchors.right: voiceBtn.left
                    anchors.rightMargin: 8
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    verticalAlignment: TextInput.AlignVCenter
                    opacity: bar.voiceOn ? 0 : 1
                    enabled: !bar.voiceOn
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    font.family: bar.uiFont
                    font.pixelSize: 15
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                    selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                    selectedTextColor: Theme.textPrimary

                    onTextChanged: {
                        // Taper ramène au champ : la liste reprend vie.
                        bar.selected = -1;
                        bar.pendingUp = false;
                        Search.query = text;
                        if (text.length > 0)
                            bar.pop = "";
                    }
                    onActiveFocusChanged: {
                        if (activeFocus)
                            bar.pop = "";
                        else if (bar.focusRequested)
                            Qt.callLater(() => {
                                if (!input.activeFocus)
                                    bar.focusRequested = false;
                            });
                    }

                    Keys.onReturnPressed: bar.submit()
                    Keys.onEnterPressed: bar.submit()
                    Keys.onUpPressed: (event) => event.accepted = bar.rowStep(1)
                    Keys.onDownPressed: (event) => event.accepted = bar.rowStep(-1)
                    // Sur un réglage retenu (volume, accent), ← → le règlent ;
                    // ailleurs ils déplacent le curseur du texte.
                    Keys.onLeftPressed: (event) => event.accepted = bar.adjustSelected(-1)
                    Keys.onRightPressed: (event) => event.accepted = bar.adjustSelected(1)
                    Keys.onEscapePressed: {
                        if (bar.selected >= 0)
                            bar.selected = -1;
                        else
                            bar.release();
                    }
                }

                // L'invite : s'efface en glissant dès la première lettre.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: voiceBtn.left
                    readonly property bool on: !bar.voiceOn && input.text.length === 0
                    opacity: on ? 1 : 0
                    anchors.leftMargin: on ? 0 : 10
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    Behavior on anchors.leftMargin { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    text: bar.asking && answer.shown ? I18n.tr("bar.yourAnswer")
                        : Pilot.voiceWake ? I18n.tr("bar.placeholderWake", { word: Pilot.voiceWakeWord })
                        : I18n.tr("bar.placeholder")
                    font.family: bar.uiFont
                    font.pixelSize: 15
                    color: Qt.alpha(Theme.textPrimary, 0.42)
                    elide: Text.ElideRight
                }

                // Pendant qu'on parle : l'onde de la voix, puis ce qu'anna a
                // compris jusqu'ici ; le mot d'éveil, discret, à droite.
                Row {
                    id: listening
                    anchors.left: parent.left
                    anchors.right: voiceBtn.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    opacity: bar.voiceOn ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Row {
                        id: wave
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        readonly property bool transcribing: Pilot.voicePhase === "transcribing"
                        property real phase: 0

                        NumberAnimation on phase {
                            from: 0
                            to: 2 * Math.PI
                            duration: wave.transcribing ? 1400 : 1000
                            loops: Animation.Infinite
                            running: listening.visible
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
                                color: Theme.accentColor
                                readonly property real swing: 0.5 + 0.5 * Math.sin(wave.phase - waveBar.index * 0.9)
                                height: wave.transcribing
                                        ? 4 + 6 * waveBar.swing
                                        : 4 + 16 * waveBar.modelData * bar.level * (0.65 + 0.35 * waveBar.swing)
                            }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: listening.width - wave.width - wakeHint.width - 2 * listening.spacing
                        text: Pilot.voiceText.length > 0 ? Pilot.voiceText : I18n.tr("bar.listening")
                        elide: Text.ElideLeft
                        font.family: bar.uiFont
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        color: Pilot.voiceText.length > 0 ? Theme.textPrimary : Theme.textSecondary
                    }

                    Text {
                        id: wakeHint
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Pilot.voiceWake
                        width: visible ? implicitWidth : 0
                        text: I18n.tr("bar.orSay", { word: Pilot.voiceWakeWord })
                        font.family: bar.uiFont
                        font.pixelSize: 12
                        color: Theme.textDim
                    }
                }

                // Le micro : parler au pilote, ou finir l'écoute en cours.
                Rectangle {
                    id: voiceBtn
                    anchors.right: sendBtn.left
                    anchors.rightMargin: sendBtn.on ? 6 : 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32
                    height: 32
                    radius: Theme.radiusSmall
                    color: bar.voiceOn ? Qt.alpha(Theme.accentColor, 0.2 + 0.5 * bar.level)
                         : voiceMa.containsMouse ? Theme.hoverOverlay : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    NixIcon {
                        anchors.centerIn: parent
                        iconSize: 16
                        source: "../assets/ui/mic.svg"
                        color: bar.voiceOn ? Theme.accentColor
                             : voiceMa.containsMouse ? Theme.textPrimary : Theme.iconColor
                    }
                    MouseArea {
                        id: voiceMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Pilot.voiceToggle(true)
                    }
                }

                // Le bouton d'envoi, qui éclot quand il y a quelque chose à
                // envoyer.
                Rectangle {
                    id: sendBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property bool on: input.text.trim().length > 0 && !bar.voiceOn
                    width: on ? 32 : 0
                    height: 32
                    radius: Theme.radiusSmall
                    color: Theme.accentColor
                    opacity: on ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                    NixIcon {
                        anchors.centerIn: parent
                        iconSize: 15
                        source: "../assets/icons/send.svg"
                        color: Theme.selectedTextColor
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: bar.submit()
                    }
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
            }

            // ── À droite, les groupes ──
            Row {
                id: tray
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                // Les connexions.
                BarButton {
                    id: wifiBtn
                    icon: "wifi.svg"
                    on: bar.pop === "wifi"
                    onClicked: bar.togglePop("wifi", wifiBtn)
                }
                BarButton {
                    id: btBtn
                    visible: Bluetooth.defaultAdapter !== null // qmllint disable unresolved-type
                    icon: "bluetooth.svg"
                    tint: bar.btConnected ? Theme.accentColor : bar.btPowered ? Theme.iconColor : Theme.textDim
                    on: bar.pop === "bluetooth"
                    onClicked: bar.togglePop("bluetooth", btBtn)
                }

                Item { width: 10; height: 1 }
                Separator {}
                Item { width: 10; height: 1 }

                // L'audio.
                BarButton {
                    id: soundBtn
                    icon: Audio.muted ? "volume-mute.svg" : "volume.svg"
                    on: bar.pop === "sound"
                    onClicked: (button) => button === Qt.RightButton ? Audio.toggleMute() : bar.togglePop("sound", soundBtn)
                }
                // Un clic droit coupe le micro, comme le son.
                BarButton {
                    id: micBtn
                    icon: Audio.micMuted ? "mic-mute.svg" : "mic.svg"
                    on: bar.pop === "mic"
                    onClicked: (button) => button === Qt.RightButton ? Audio.toggleMicMute() : bar.togglePop("mic", micBtn)
                }

                Item { width: 10; height: 1 }
                Separator {}
                Item { width: 10; height: 1 }

                // La capture : une image, ou un film de l'écran. Pendant un
                // enregistrement, son étiquette prend la place du bouton.
                BarButton {
                    icon: "screenshot.svg"
                    onClicked: (button) => bar.screenshot(button === Qt.RightButton ? "screen" : "area")
                }
                BarButton {
                    visible: Recorder.available && !Recorder.screenOn
                    icon: "screen-record.svg"
                    onClicked: (button) => bar.screenRecord(button === Qt.RightButton ? "screen" : "area")
                }
                RecordingTag {
                    visible: Recorder.screenOn
                    kind: "screen"
                    track: Recorder.screen
                }
                RecordingTag {
                    visible: Recorder.audioOn
                    kind: "audio"
                    track: Recorder.audio
                }

                Item { width: 10; height: 1 }
                Separator {}
                Item { width: 10; height: 1 }

                // Les tâches : celles qui restent à faire, en pastille.
                BarButton {
                    id: tasksBtn
                    icon: "tasks.svg"
                    badge: Agenda.pendingCount
                    on: bar.pop === "tasks"
                    onClicked: bar.togglePop("tasks", tasksBtn)
                }
                // Les notifications. (Le thème et l'accent : onglet Réglages du panneau.)
                BarButton {
                    id: notifBtn
                    icon: "bell.svg"
                    badge: Notifications.all.length
                    on: bar.pop === "notifications"
                    onClicked: bar.togglePop("notifications", notifBtn)
                }

                Item { width: 10; height: 1 }
                Separator {}
                Item { width: 10; height: 1 }

                // Le téléphone et la batterie (et l'écran) ; l'heure et
                // l'alimentation sont à gauche.
                // Le téléphone : connecté, sa batterie, comme celle du PC ; le
                // pourcentage s'ouvre et se referme avec la connexion.
                BarPill {
                    id: phoneBtn
                    readonly property bool showLevel: Phone.battery >= 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34 + (phoneBtn.showLevel ? phoneLevel.implicitWidth + 6 : 0)
                    height: 34
                    clip: true
                    on: bar.pop === "phone"
                    Behavior on width { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
                    onClicked: bar.togglePop("phone", phoneBtn)

                    NixIcon {
                        x: 8
                        anchors.verticalCenter: parent.verticalCenter
                        iconSize: 18
                        source: "../assets/ui/phone.svg"
                        color: phoneBtn.on ? Theme.accentColor
                             : Phone.charging ? Theme.colorSuccess
                             : Phone.low ? Theme.colorDanger : Theme.iconColor
                        opacity: Phone.connected || phoneBtn.on || phoneBtn.hovered ? 1 : 0.8
                        Behavior on color { ColorAnimation { duration: 260 } }
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                    Text {
                        id: phoneLevel
                        x: 32
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: phoneBtn.showLevel ? 0 : 4
                        text: I18n.tr("common.percent", { n: Math.max(0, Phone.battery) })
                        font.family: bar.uiFont
                        font.pixelSize: 13
                        font.features: { "tnum": 1 }
                        color: Theme.textSecondary
                        opacity: phoneBtn.showLevel ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                    }
                }
                BarPill {
                    id: batteryBtn
                    visible: Battery.present
                    anchors.verticalCenter: parent.verticalCenter
                    width: batteryRow.implicitWidth + 16
                    height: 34
                    on: bar.pop === "energy"
                    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                    onClicked: bar.togglePop("energy", batteryBtn)

                    Row {
                        id: batteryRow
                        anchors.centerIn: parent
                        spacing: 6
                        BarIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            icon: Battery.status === "Charging" ? "bolt.svg" : "battery.svg"
                            color: Battery.status === "Charging" ? Theme.colorSuccess
                                 : Battery.percent <= Battery.lowAt ? Theme.colorDanger : Theme.iconColor
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.tr("common.percent", { n: Battery.percent })
                            font.family: bar.uiFont
                            font.pixelSize: 13
                            font.features: { "tnum": 1 }
                            color: batteryBtn.on ? Theme.textPrimary : Theme.textSecondary
                            Behavior on color { ColorAnimation { duration: 220 } }
                        }
                    }
                }

                Item { width: 10; height: 1 }
                Separator {}
                Item { width: 10; height: 1 }

                // Le panneau de droite : il s'ouvre depuis ce bouton.
                BarButton {
                    id: panelBtn
                    icon: "claude.svg"
                    // Une session Claude attend une réponse : un point.
                    dot: ClaudeSessions.waiting > 0
                    on: Widgets.panelOpen
                    onClicked: Widgets.panelOpen = !Widgets.panelOpen
                }
            }
        }
    }

    // Un enregistrement en cours : le point rouge qui bat, le temps écoulé,
    // et ■ pour l'arrêter.
    component RecordingTag: Rectangle {
        id: tag
        property string kind
        property var track: null

        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: tagRow.implicitWidth + 20
        height: 30
        radius: 15
        color: Qt.alpha(Theme.colorDanger, tagMa.containsMouse ? 0.26 : 0.18)

        Row {
            id: tagRow
            anchors.centerIn: parent
            spacing: 8

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8
                height: 8
                radius: 4
                color: Theme.colorDanger
                SequentialAnimation on opacity {
                    running: tag.visible
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Recorder.elapsed(tag.track)
                font.family: bar.uiFont
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: Theme.textPrimary
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 9
                height: 9
                radius: 2
                color: Theme.textSecondary
            }
        }
        MouseArea {
            id: tagMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Recorder.stop(tag.kind)
        }
    }

    // ── Ce qui sort de la barre ──────────────────────────────────
    // Les volets, les suggestions et la réponse du pilote, dans une fenêtre
    // à part, sur la couche Overlay : au-dessus du panneau de droite (couche
    // Top, comme la barre), qu'ils peuvent chevaucher. Elle a la taille et la
    // place de la barre, si bien que les deux se superposent au pixel près ;
    // elle ne réserve rien et ne prend la souris que sur ce qu'elle montre.
    PanelWindow { // qmllint disable uncreatable-type
        id: over

        screen: bar.screen
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-bar-over"
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        // Le mot de passe d'un réseau Wi-Fi s'y tape, et les tâches.
        WlrLayershell.keyboardFocus: bar.pop === "wifi" || bar.pop === "tasks" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

        anchors { // qmllint disable unqualified unresolved-type
            left: true
            right: true
            bottom: true
        }
        exclusiveZone: 0
        implicitHeight: bar.barH + bar.above
        color: "transparent"

        mask: Region { // qmllint disable unqualified
            Region { item: answer.on ? answer : null }
            Region { item: results.on ? results : null }
            Region { item: bar.drawer !== "" ? popHost : null }
            Region { item: phoneStack.visible ? phoneStack : null }
            Region { item: powerStack.visible ? powerStack : null }
        }

        Item {
            anchors.fill: parent

        // ── Le résultat de la commande, au-dessus du champ ───────
        // Une commande, pas une conversation : seulement ce que le pilote
        // vient de faire, en lignes discrètes, et sa confirmation — puis ça
        // s'efface. Ni la demande, ni les tours précédents. Pour répondre à
        // une question du pilote, on tape simplement dans la barre.
        Item {
            id: answer

            property bool shown: false
            // Un message d'anna plutôt qu'un tour du pilote (erreur de la voix).
            property string notice: ""

            // La réponse arrivée reste à l'écran tant qu'on ne fait rien, et
            // s'en va au premier geste (souris, clavier) — ou dès qu'une
            // nouvelle demande commence. Pas de minuterie : on la lit à son
            // rythme, mais elle ne s'attarde jamais au-delà.
            property bool armed: false

            function show() {
                graceTimer.stop();
                answer.armed = false;
                answer.shown = true;
            }
            function hide() {
                graceTimer.stop();
                answer.armed = false;
                answer.shown = false;
                answer.clearNotice();
            }
            // Le tour est fini : un court répit (qu'un geste déjà en cours ne
            // la ferme pas à peine apparue), puis le premier geste la ferme.
            function settle() {
                if (answer.shown)
                    graceTimer.restart();
            }
            Timer {
                id: graceTimer
                interval: 900
                onTriggered: answer.armed = answer.shown && !Pilot.pilotBusy
            }
            // ext-idle-notify : « inactif » après une seconde sans geste, puis
            // « actif » au geste suivant, où qu'il ait lieu — c'est lui qui
            // la ferme. Les inhibiteurs (une vidéo) n'y changent rien.
            IdleMonitor {
                enabled: answer.armed
                timeout: 1
                respectInhibitors: false
                onIsIdleChanged: {
                    if (isIdle || !answer.armed || Pilot.pilotBusy)
                        return;
                    // On la lit à la souris (défilement, lien), ou on tape
                    // dans la barre : elle reste.
                    if (answerHover.hovered || input.activeFocus)
                        return;
                    answer.hide();
                }
            }

            // Un message d'anna : quatre secondes, survolé ou non, puis la
            // bulle revient à ce qu'elle montrait — ou se ferme si elle
            // n'était ouverte que pour lui.
            function flash(text) {
                noticeTimer.keepOpen = answer.on && answer.notice.length === 0;
                answer.notice = text;
                answer.show();
                noticeTimer.restart();
            }
            function clearNotice() {
                noticeTimer.stop();
                answer.notice = "";
            }
            Timer {
                id: noticeTimer
                property bool keepOpen: false
                interval: 4000
                onTriggered: {
                    answer.notice = "";
                    if (!noticeTimer.keepOpen && !Pilot.pilotBusy)
                        answer.hide();
                }
            }

            // Le journal du pilote, recopié pas à pas : la réponse qui
            // s'écrit ne change que son texte, un nouveau message s'ajoute —
            // les autres restent tels quels, sans clignoter. Un journal
            // raccourci ou vidé (nouvelle conversation) est recopié d'un coup.
            ListModel { id: thread }
            function sync() {
                var items = Pilot.pilotItems;
                var rebuild = items.length < thread.count
                    || (thread.count > 1 && (thread.get(0).kind !== items[0].kind
                                             || thread.get(0).text !== items[0].text));
                if (rebuild)
                    thread.clear();
                for (var i = 0; i < items.length; i++) {
                    if (i < thread.count) {
                        if (thread.get(i).text !== items[i].text)
                            thread.setProperty(i, "text", items[i].text);
                    } else {
                        thread.append({ kind: items[i].kind, text: items[i].text, fresh: !rebuild });
                    }
                }
            }
            Connections {
                target: Pilot
                function onPilotItemsChanged() { answer.sync(); }
            }
            Component.onCompleted: answer.sync()

            // Le début du tour en cours : ce qui précède est estompé.
            readonly property int current: {
                var items = Pilot.pilotItems;
                for (var i = items.length - 1; i >= 0; i--)
                    if (items[i].kind === "user")
                        return i;
                return 0;
            }

            readonly property bool hasContent: notice.length > 0 || bar.turn !== null
            readonly property bool on: shown && hasContent && !bar.searching && bar.pop === ""
            readonly property int padX: 18
            readonly property int padY: 14

            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.barH
            x: field.x - 18
            width: Math.min(680, field.width + 36)
            height: Math.min(column.implicitHeight + 2 * padY, bar.above - 20)
            Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

            visible: opacity > 0
            opacity: on ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            // Elle monte de la barre en décélérant.
            property real rise: answer.on ? 0 : 12
            Behavior on rise { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            transform: Translate { y: answer.rise }

            // Le pointeur dessus la retient ; le geste qui l'en sort la ferme.
            HoverHandler {
                id: answerHover
                onHoveredChanged: {
                    if (!hovered && answer.armed)
                        answer.hide();
                }
            }

            Lip {
                anchors.fill: parent
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
                // La fin de la conversation reste en vue pendant qu'elle s'écrit.
                onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

                Column {
                    id: column
                    width: flick.width
                    spacing: 8

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

                    Repeater {
                        model: answer.notice.length === 0 ? thread : null

                        Item {
                            id: msg
                            required property int index
                            required property string kind
                            required property string text
                            required property bool fresh

                            // Une confirmation courte en plus grand, une longue
                            // réponse à la taille du texte courant.
                            readonly property bool long: msg.text.length > 220

                            // Seulement le tour en cours, et sans la demande.
                            visible: msg.index > answer.current && msg.kind !== "user"
                            width: column.width
                            height: msg.kind === "action" ? actionLine.height : said.height

                            // Un nouveau message entre en glissant vers le haut.
                            property real appear: 1
                            NumberAnimation on appear {
                                running: msg.fresh
                                from: 0
                                to: 1
                                duration: 220
                                easing.type: Easing.OutCubic
                            }
                            opacity: msg.appear
                            transform: Translate { y: (1 - msg.appear) * 6 }

                            // Ce que le pilote fait : une ligne discrète.
                            Row {
                                id: actionLine
                                visible: msg.kind === "action"
                                width: column.width
                                spacing: 8

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 5
                                    height: 5
                                    radius: 2.5
                                    color: Theme.accentColor
                                }
                                Text {
                                    width: column.width - 13
                                    text: msg.kind === "action" ? msg.text : ""
                                    elide: Text.ElideRight
                                    font.family: "JetBrains Mono"
                                    font.pixelSize: 11
                                    color: Theme.textSecondary
                                }
                            }

                            // Ce qu'il répond.
                            Text {
                                id: said
                                visible: msg.kind === "reply" || msg.kind === "error"
                                width: column.width
                                text: said.visible ? msg.text : ""
                                textFormat: Text.MarkdownText
                                wrapMode: Text.Wrap
                                font.family: bar.uiFont
                                font.pixelSize: msg.long ? 14 : 16
                                font.weight: msg.long ? Font.Normal : Font.Medium
                                lineHeight: 1.2
                                color: msg.kind === "error" ? Theme.colorDanger : Theme.textPrimary
                                linkColor: Theme.accentColor
                                onLinkActivated: (link) => Qt.openUrlExternally(link)
                            }
                        }
                    }

                    // Le pilote réfléchit : trois points qui respirent.
                    Row {
                        visible: answer.notice.length === 0 && Pilot.pilotBusy
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
                                color: Theme.accentColor
                                SequentialAnimation on opacity {
                                    running: Pilot.pilotBusy
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

            // La fermer : au survol seulement, dans le coin.
            BarButton {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 6
                size: 22
                icon: "close.svg"
                opacity: answerHover.hovered ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 160 } }
                onClicked: answer.hide()
            }
        }

        // ── Les suggestions, au-dessus du champ ──────────────────
        // Une ligne par suggestion : l'icône, le nom puis où il se trouve, et
        // son type à droite. La meilleure est en bas, contre la barre, pour
        // que ↑ y entre directement.
        Item {
            id: results

            readonly property int rowH: 40
            readonly property int maxRows: 8
            readonly property int pad: 8
            // Seulement quand le champ a le clavier : le texte gardé après
            // un geste ailleurs reste dans le champ, sans sa liste. Le pointeur
            // dessus la retient, le temps d'un clic sur une suggestion (cliquer
            // ici peut donner le clavier à cette autre surface).
            readonly property bool on: bar.searching && bar.pop === "" && Search.results.length > 0
                                       && (input.activeFocus || resultsHover.hovered)

            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.barH
            x: field.x - 18
            width: Math.min(680, field.width + 36)
            height: Math.min(Search.results.length, maxRows) * rowH + 2 * pad
            Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }

            opacity: on ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            property real drop: results.on ? 0 : 10
            Behavior on drop { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            transform: Translate { y: results.drop }

            HoverHandler { id: resultsHover }

            Lip {
                anchors.fill: parent
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
                    readonly property bool glyph: row.icon.indexOf(bar.glyphDir) === 0
                    // Un réglage se règle sur place : son contrôle prend la
                    // place de la pastille du type. Les écrans, eux, passent
                    // au suivant d'un clic.
                    readonly property string control: bar.controlFor(row.modelData)
                    readonly property bool hasControl: row.control !== "" && row.control !== "screens"

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusSmall
                        color: row.current ? Theme.selectedFill
                                           : rowMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

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
                            source: row.glyph ? "" : row.icon
                            sourceSize.width: 48
                            sourceSize.height: 48
                            fillMode: row.icon.startsWith("file://") ? Image.PreserveAspectCrop
                                                                     : Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            visible: !row.glyph && row.icon.length > 0 && rowImage.status !== Image.Error
                        }

                        // Sinon, une pastille de la teinte du type : l'icône
                        // de assets/icons, ou à défaut l'initiale.
                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            visible: !rowImage.visible
                            color: Qt.alpha(row.modelData.tone, 0.2)

                            NixIcon {
                                anchors.centerIn: parent
                                visible: row.glyph
                                iconSize: 14
                                source: row.glyph ? row.icon : ""
                                color: row.modelData.tone
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !row.glyph
                                text: row.modelData.title.substring(0, 1).toUpperCase()
                                color: row.modelData.tone
                                font.family: bar.uiFont
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    // Le type ; sur la ligne retenue, ce qu'Entrée fera.
                    Rectangle {
                        id: kind
                        visible: !row.hasControl
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: kindLabel.implicitWidth + 16
                        height: 22
                        radius: 6
                        color: row.current ? "transparent" : Theme.hoverOverlay

                        Text {
                            id: kindLabel
                            anchors.centerIn: parent
                            text: row.current ? "↵ " + (row.modelData.type === "task" ? I18n.tr("common.add") : I18n.tr("common.open"))
                                              : bar.typeLabels[row.modelData.type] || row.modelData.type
                            font.family: bar.uiFont
                            font.pixelSize: 10
                            font.weight: Font.Medium
                            color: row.current ? Theme.textPrimary : Theme.textSecondary
                        }
                    }

                    // Le nom, puis où il se trouve, en plus discret.
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

                    // Après la zone de clic de la ligne : le contrôle reçoit
                    // les siens en premier.
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

        // ── Les boutons du téléphone, qui montent au-dessus de lui ──
        PhonePop {
            id: phoneStack
            shown: bar.pop === "phone"
            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.barH
            x: {
                // Centrée sur son bouton, au pixel ; contre un bord de l'écran,
                // son coin creusé peut en sortir.
                // (Lus pour suivre le bouton quand la rangée bouge.)
                void (phoneBtn.x + tray.x + root.width);
                var p = phoneBtn.mapToItem(root, phoneBtn.width / 2, 0);
                return Math.round(Math.max(0, Math.min(p.x - width / 2, root.width - width)));
            }
            HoverHandler { id: phoneHover }
        }

        // ── L'alimentation, de même, au-dessus de son bouton ──
        PowerStack {
            id: powerStack
            shown: bar.pop === "power"
            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.barH
            x: {
                // Centrée sur son bouton, au pixel ; contre un bord de l'écran,
                // son coin creusé peut en sortir.
                // (Lus pour suivre le bouton quand la rangée bouge.)
                void (powerBtn.x + machineRow.x + root.width);
                var p = powerBtn.mapToItem(root, powerBtn.width / 2, 0);
                return Math.round(Math.max(0, Math.min(p.x - width / 2, root.width - width)));
            }
            onLeaving: bar.dismiss()
            HoverHandler { id: powerHover }
        }

        // ── Le volet ouvert, au-dessus de son bouton ─────────────
        // Il sort de la barre comme un tiroir : sa surface monte et
        // s'élargit depuis la largeur du bouton, le contenu monte avec elle
        // en apparaissant ; à la fermeture, il y redescend, plus vite. D'un
        // volet à l'autre, la surface glisse vers le nouveau bouton en
        // changeant de taille, pendant que les contenus se relaient en
        // fondu.
        Item {
            id: popHost

            readonly property int pad: 16
            // Le volet à l'écran : gardé pendant qu'il se referme.
            property string shown: ""
            // 0 : rentré dans la barre ; 1 : ouvert.
            property real open: 0
            // Ouvert pour de bon : les changements de taille et de place
            // s'animent (avant, ils suivent `open`).
            readonly property bool settled: popHost.open >= 1

            readonly property int contentW: bar.popWidths[popHost.shown]
                || (popLoader.item ? popLoader.implicitWidth : 300)
            readonly property real fullW: popHost.contentW + 2 * popHost.pad
            readonly property real fullH: Math.min(popLoader.implicitHeight + popHost.pad + 12, bar.above - 20)

            property real animW: popHost.fullW
            property real animH: popHost.fullH
            Behavior on animW { enabled: popHost.settled; NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            Behavior on animH { enabled: popHost.settled; NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

            // Le milieu du bouton, là où le volet se centre.
            readonly property real anchorX: {
                if (!bar.popAnchor)
                    return root.width / 2;
                return bar.popAnchor.mapToItem(root, bar.popAnchor.width / 2, 0).x;
            }
            readonly property real anchorW: bar.popAnchor ? bar.popAnchor.width : 34
            property real centerX: popHost.anchorX
            Behavior on centerX { enabled: popHost.settled; NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }

            anchors.bottom: parent.bottom
            anchors.bottomMargin: bar.barH
            width: popHost.anchorW + (popHost.animW - popHost.anchorW) * popHost.open
            height: popHost.animH * popHost.open
            // Centré sur son bouton, sans sortir de l'écran (les coins
            // creusés compris).
            x: Math.max(Theme.radius + 8, Math.min(popHost.centerX - width / 2, root.width - width - Theme.radius - 8))
            visible: popHost.open > 0.001

            NumberAnimation {
                id: openAnim
                target: popHost
                property: "open"
                to: 1
                duration: 460
                easing.type: Easing.OutExpo
            }
            NumberAnimation {
                id: closeAnim
                target: popHost
                property: "open"
                to: 0
                duration: 220
                easing.type: Easing.OutCubic
                onFinished: popHost.shown = ""
            }

            // D'un volet à l'autre : l'ancien contenu s'efface, le nouveau
            // monte en apparaissant.
            property real fade: 1
            property real lift: 0
            SequentialAnimation {
                id: swapAnim
                ParallelAnimation {
                    NumberAnimation { target: popHost; property: "fade"; to: 0; duration: 110; easing.type: Easing.InCubic }
                    NumberAnimation { target: popHost; property: "lift"; to: -4; duration: 110; easing.type: Easing.InCubic }
                }
                ScriptAction { script: { popHost.shown = bar.drawer; popHost.lift = 8; } }
                ParallelAnimation {
                    NumberAnimation { target: popHost; property: "fade"; to: 1; duration: 260; easing.type: Easing.OutCubic }
                    NumberAnimation { target: popHost; property: "lift"; to: 0; duration: 340; easing.type: Easing.OutQuint }
                }
            }

            Connections {
                target: bar
                function onDrawerChanged() {
                    if (bar.drawer === "") {
                        openAnim.stop();
                        swapAnim.stop();
                        closeAnim.restart();
                    } else if (popHost.shown === "" || popHost.open < 0.05) {
                        // Du fond de la barre : le contenu monte avec la surface.
                        closeAnim.stop();
                        swapAnim.stop();
                        popHost.fade = 1;
                        popHost.lift = 0;
                        popHost.shown = bar.drawer;
                        openAnim.restart();
                    } else {
                        closeAnim.stop();
                        if (popHost.open < 1)
                            openAnim.restart();
                        swapAnim.restart();
                    }
                }
            }

            HoverHandler { id: popHover }

            Lip {
                anchors.fill: parent
            }

            // Les clics sur le volet ne traversent pas.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: (wheel) => wheel.accepted = true
            }

            // Le contenu, découpé par la surface qui grandit : posé contre son
            // haut, il monte avec elle.
            Item {
                anchors.fill: parent
                clip: popHost.open < 1

                Loader {
                    id: popLoader
                    x: (popHost.width - popHost.contentW) / 2
                    y: popHost.height - popHost.animH + popHost.pad + popHost.lift
                    width: popHost.contentW
                    height: Math.min(implicitHeight, popHost.animH - popHost.pad - 12)
                    opacity: popHost.fade * Math.min(1, popHost.open * 1.6 - 0.3)
                    active: popHost.shown !== ""
                    focus: true
                    Keys.onEscapePressed: bar.pop = ""
                    sourceComponent: ({
                        "wifi": wifiPop, "bluetooth": btPop, "sound": soundPop,
                        "mic": micPop, "notifications": notifPop,
                        "energy": energyPop, "tasks": tasksPop, "apps": appsPop
                    })[popHost.shown] || null
                }
            }
        }
        }
    }

    function launch(text) {
        ghost.text = text;
        flyAway.restart();
    }
}
