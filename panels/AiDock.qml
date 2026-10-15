pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"

// Le panneau des sessions : la porte d'entrée de l'interface vers Claude
// Code. Il sort de la barre des sessions (SessionBar, la bande noire toujours
// là contre le bord gauche, un point par session) : un clic sur un point l'ouvre sur cette
// session, un clic sur ✦ l'ouvre tout court. Super+P l'ouvre et le referme
// aussi (widget « sessions », cf. services/Widgets.qml), Échap le referme.
// Même verre, mêmes teintes et même capsule de saisie que la barre de
// conversation.
//
//   ╭──────────────────────────────╮
//   │ ● karenine·fix-dock travaille │  la session regardée
//   │ + nouvelle  ⟲ historique  ◈  │  les autres vues
//   ├──────────────────────────────┤
//   │  la conversation de la       │
//   │  session choisie             │
//   │                              │
//   │  ~/ciph3r/karenine · 2 fich. │  son travail
//   │  Zed  Terminal  Commit  …    │
//   │ ( › écrire à Claude      (↑) )│
//   ╰──────────────────────────────╯
//
// À qui l'on parle :
//   - le pilote, par défaut : on lui dit ce qu'on veut (« baisse le son »,
//     « ouvre zed sur karenine », « corrige le dock dans karenine ») ; il agit
//     sur le bureau, ou confie le travail de fond à une session complète. Une
//     action confirmée en une phrase referme le dock, la confirmation passant
//     dans la bulle de la barre ;
//   - une session vivante (ClaudeLive) : sa conversation, et on lui écrit —
//     directement si anna la fait tourner, sinon en la reprenant ;
//   - « nouvelle » : un projet choisi (la recherche, un dépôt) pour lancer une
//     session sans passer par le pilote. Un dépôt se travaille par défaut dans
//     une copie isolée (worktree), dont le travail se revoit ensuite ici ;
//   - l'historique (ClaudeSessions) : relire une ancienne conversation, et la
//     reprendre en lui écrivant ;
//   - le savoir : les notes du coffre Obsidian (recherches, projets, skills,
//     lab, journal des sessions), filtrées par ce qu'on tape ; « Relu » marque
//     ce que Claude a rangé, « Session » rouvre la conversation d'origine. En
//     fin de session, « ◈ Capitaliser » y range ce qu'elle a appris.
//
// Les sessions tournent chez anna, pas ici : fermer le dock ou recharger le
// shell ne les interrompt pas. Leurs demandes de permission arrivent dans la
// bulle de la barre, comme celles d'un terminal.
Scope {
    id: dock

    property var screen: null
    property bool open: false
    signal closeRequested()

    // Le texte en Inter, comme la barre de conversation ; les détails en
    // JetBrains Mono.
    readonly property string uiFont: "Inter"

    // La session à montrer à la prochaine ouverture (un point de la barre des
    // sessions), plutôt que celle que choisit pickDefault.
    property string pendingId: ""

    // Un point de la barre : ouvre le dock sur cette session ; déjà ouvert
    // sur elle, le referme.
    function openOn(id) {
        if (!dock.open) {
            dock.pendingId = id;
            Widgets.apply("sessions", "ouvrir");
        } else if (dock.selectedId === id && !dock.overlay) {
            dock.closeRequested();
        } else {
            dock.select(id);
        }
    }

    // ── Sélection ────────────────────────────────────────────────
    // L'id d'une session vivante, ou "" pour une nouvelle session.
    property string selectedId: ""
    // Une conversation de l'historique ({ id, cwd, project, path, title }),
    // regardée tant qu'elle n'est pas reprise.
    property var past: null
    property bool showHistory: false
    // La vue « savoir » : les notes du coffre.
    property bool showKnowledge: false
    // L'historique ou le savoir recouvrent la vue courante.
    readonly property bool overlay: dock.showHistory || dock.showKnowledge

    // ── Savoir ───────────────────────────────────────────────────
    // Filtre : "" (tout), "à-relire", ou une sorte de note (recherche, projet,
    // skill, lab, journal). Ce qu'on tape dans le champ du bas affine la liste.
    property string noteFilter: ""
    property var note: null          // la note ouverte
    property string noteText: ""     // son corps
    readonly property int toReview: ClaudeLive.notes.filter(n => n.statut === "à-relire").length

    readonly property var shownNotes: {
        var q = dock.showKnowledge ? composer.text.trim() : "";
        var f = dock.noteFilter;
        return ClaudeLive.notes.filter(function (n) {
            if (f === "à-relire" ? n.statut !== "à-relire" : (f !== "" && n.kind !== f))
                return false;
            return q.length === 0
                || Fuzzy.best(q, [n.title, n.sujets.join(" "), n.projet, n.excerpt]) > 0;
        }).slice(0, 200);
    }

    // Ouvre le dock directement sur le savoir (commande « savoir » du FIFO).
    function openKnowledge() {
        dock.showHistory = false;
        dock.showKnowledge = true;
        ClaudeLive.loadNotes();
    }

    // Le savoir s'ouvre sur la note la plus récente plutôt que sur un aperçu
    // vide.
    Connections {
        target: ClaudeLive
        function onNotesChanged() {
            // Une fois la liste filtrée recalculée sur les nouvelles notes.
            Qt.callLater(function () {
                if (dock.showKnowledge && dock.note === null && dock.shownNotes.length > 0)
                    dock.openNote(dock.shownNotes[0]);
            });
        }
    }

    function openNote(n) {
        dock.note = n;
        dock.noteText = "";
        var path = n.path;
        ClaudeLive.readNote(path, function (text) {
            if (dock.note && dock.note.path === path)
                dock.noteText = text === null ? "(note illisible)" : text;
        });
    }

    // La session d'où vient une note (son champ `session` : 8 caractères),
    // si l'historique la connaît encore.
    function sessionOf(n) {
        if (!n || !n.session)
            return null;
        return ClaudeSessions.sessions.find(s => s.id.indexOf(n.session) === 0) || null;
    }

    readonly property var selected: dock.selectedId.length > 0 ? ClaudeLive.find(dock.selectedId) : null
    readonly property bool composingNew: dock.selected === null && dock.past === null

    // À qui va ce qu'on écrit hors d'une session : au pilote (-1, le défaut),
    // ou à une nouvelle session dans ClaudeLive.projects[targetIndex] — dans
    // une copie isolée ou non.
    property int targetIndex: -1
    property bool isolate: true
    readonly property bool toPilot: dock.targetIndex < 0
    readonly property var target: !dock.toPilot && ClaudeLive.projects.length > dock.targetIndex
                                  ? ClaudeLive.projects[dock.targetIndex] : null
    // Dictée, comme dans Claude Code : Espace maintenu fait parler, le texte
    // compris s'écrit en direct dans le champ (après ce qui y était déjà) et
    // y reste au relâchement pour être relu ; Entrée envoie. Le 🎙 lance la
    // même dictée à la souris.
    property bool dictating: false
    property string dictationPrefix: ""
    // Espace enfoncé (l'espace est déjà écrit, en spaceAt), et maintenu
    // assez pour dicter.
    property bool spaceDown: false
    property int spaceAt: 0
    property bool pushToTalk: false

    function startDictation(hold) {
        dock.dictating = true;
        dock.dictationPrefix = composer.text.length > 0 && !/\s$/.test(composer.text)
                               ? composer.text + " " : composer.text;
        if (hold)
            ClaudeLive.voiceHold();
        else
            ClaudeLive.voiceToggle(false);
    }

    Connections {
        target: ClaudeLive
        function onVoiceTextChanged() {
            if (dock.dictating && ClaudeLive.voiceText.length > 0) {
                composer.text = dock.dictationPrefix + ClaudeLive.voiceText;
                composer.cursorPosition = composer.text.length;
            }
        }
        function onVoicePhaseChanged() {
            if (ClaudeLive.voicePhase === "idle")
                dock.dictating = false;
        }
    }

    // Espace gardé au-delà de ce délai, sans autre touche entre-temps :
    // dictée. L'espace écrit à l'appui est alors retiré.
    Timer {
        id: holdTimer
        interval: 350
        onTriggered: {
            if (!dock.spaceDown || dock.inTerminal || ClaudeLive.voicePhase !== "idle")
                return;
            if (composer.text.charAt(dock.spaceAt) === " ")
                composer.remove(dock.spaceAt, dock.spaceAt + 1);
            dock.pushToTalk = true;
            dock.startDictation(true);
        }
    }

    // Une touche du champ : Espace peut devenir une dictée.
    function keyPressed(event) {
        if (event.key !== Qt.Key_Space) {
            if (dock.spaceDown) {
                dock.spaceDown = false;
                holdTimer.stop();
            }
            return;
        }
        if (event.isAutoRepeat) {
            // Pas d'espaces en rafale pendant qu'on dicte.
            if (dock.pushToTalk || dock.spaceDown)
                event.accepted = true;
            return;
        }
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
            return;
        dock.spaceDown = true;
        dock.spaceAt = composer.cursorPosition;
        holdTimer.restart();
    }

    function keyReleased(event) {
        if (event.key !== Qt.Key_Space || event.isAutoRepeat)
            return;
        holdTimer.stop();
        dock.spaceDown = false;
        if (dock.pushToTalk) {
            dock.pushToTalk = false;
            ClaudeLive.voiceRelease();
        }
    }

    // Joindre le presse-papiers à la prochaine demande au pilote.
    property bool withClipboard: false

    // Le travail de la session regardée, si elle est en copie isolée.
    property var review: null
    property bool confirmDiscard: false

    readonly property string followedPath: dock.selected ? dock.selected.transcript
                                           : (dock.past ? dock.past.path : "")
    onFollowedPathChanged: ClaudeLive.follow(dock.followedPath)

    function select(id) {
        dock.past = null;
        dock.showHistory = false;
        dock.showKnowledge = false;
        dock.selectedId = id;
        dock.confirmDiscard = false;
        dock.refreshReview();
        composer.forceActiveFocus();
    }

    function selectPast(p) {
        var liveOne = ClaudeLive.find(p.id);
        if (liveOne) {
            dock.select(p.id);
            return;
        }
        dock.selectedId = "";
        dock.past = p;
        dock.showHistory = false;
        dock.showKnowledge = false;
        dock.review = null;
        composer.forceActiveFocus();
    }

    function startNew() {
        dock.past = null;
        dock.showHistory = false;
        dock.showKnowledge = false;
        dock.selectedId = "";
        dock.review = null;
        composer.forceActiveFocus();
    }

    // À l'ouverture : la session qui attend l'utilisateur si une le fait,
    // sinon le pilote — c'est par lui que tout commence.
    function pickDefault() {
        var waiting = ClaudeLive.sessions.find(s => s.state === "waiting" && s.id !== "pilote");
        if (waiting)
            return dock.select(waiting.id);
        dock.targetIndex = -1;
        dock.startNew();
    }

    // Un tour du pilote vient de finir. S'il a agi et confirmé en une phrase,
    // la confirmation part dans la bulle et le dock se referme : « baisse le
    // son » ne demande rien de plus. Une réponse plus longue, une question en
    // retour ou une erreur restent à l'écran.
    Connections {
        target: ClaudeLive
        function onPilotDone() {
            if (!dock.open || !dock.composingNew || !dock.toPilot || composer.text.length > 0)
                return;
            var items = ClaudeLive.pilotItems;
            var start = items.length - 1;
            while (start >= 0 && items[start].kind !== "user")
                start--;
            var turn = items.slice(start + 1);
            var acted = turn.some(i => i.kind === "action");
            var replies = turn.filter(i => i.kind === "reply");
            var failed = turn.some(i => i.kind === "error");
            var last = replies.length > 0 ? replies[replies.length - 1].text : "";
            if (!acted || failed || last.length === 0 || last.length > 140 || last.endsWith("?"))
                return;
            ClaudeLive.alert({ id: "", project: "pilote", kind: "pilot", text: last });
            closeLater.restart();
        }
    }

    Timer {
        id: closeLater
        interval: 700
        onTriggered: {
            if (dock.open && composer.text.length === 0)
                dock.closeRequested();
        }
    }

    // Une session ouverte dans un terminal s'y poursuit : la reprendre d'ici
    // ferait écrire deux processus dans la même conversation.
    readonly property bool inTerminal: dock.selected !== null && !dock.selected.managed

    function refreshReview() {
        var s = dock.selected;
        if (!s || !s.worktree) {
            dock.review = null;
            return;
        }
        var id = s.id;
        ClaudeLive.review(s.cwd, function (r) {
            if (dock.selectedId === id)
                dock.review = r;
        });
    }

    // Le tour d'une session en copie isolée vient de finir : son travail a
    // pu changer.
    property string _lastState: ""
    readonly property string selectedState: dock.selected ? dock.selected.state : ""
    onSelectedStateChanged: {
        if (dock._lastState !== "" && dock.selectedState === "idle")
            dock.refreshReview();
        dock._lastState = dock.selectedState;
    }

    function submit() {
        // Dans le savoir, le champ cherche : Entrée ouvre la première note.
        if (dock.showKnowledge) {
            if (dock.shownNotes.length > 0)
                dock.openNote(dock.shownNotes[0]);
            return;
        }
        // Entrée pendant une dictée : elle s'arrête, ce qui est écrit part.
        if (dock.dictating) {
            dock.dictating = false;
            ClaudeLive.voiceRelease();
        }
        var text = composer.text.trim();
        if (text.length === 0 || dock.inTerminal)
            return;
        ClaudeLive.lastError = "";

        if (dock.selected) {
            ClaudeLive.send(dock.selected.id, text, dock.selected.cwd);
        } else if (dock.past) {
            var p = dock.past;
            ClaudeLive.send(p.id, text, p.cwd);
            // Reprise : la session redevient vivante sous le même id.
            dock.past = null;
            dock.selectedId = p.id;
        } else if (dock.toPilot) {
            if (ClaudeLive.pilotBusy)
                return;
            ClaudeLive.pilotAsk(text, dock.withClipboard);
            dock.withClipboard = false;
        } else {
            var t = dock.target;
            if (!t)
                return;
            var isolated = dock.isolate && t.kind === "projet";
            ClaudeLive.start(t.path, text, isolated, function (id) {
                if (id.length > 0)
                    dock.select(id);
            });
        }
        composer.text = "";
    }

    function cycleSession(step) {
        var ss = ClaudeLive.sessions;
        if (ss.length === 0)
            return;
        var i = ss.findIndex(s => s.id === dock.selectedId);
        if (i < 0)
            i = step > 0 ? -1 : ss.length;
        i = (i + step + ss.length) % ss.length;
        dock.select(ss[i].id);
    }

    onOpenChanged: {
        if (dock.open) {
            ClaudeLive.loadProjects();
            ClaudeSessions.ensureIndex();
            if (dock.pendingId.length > 0 && ClaudeLive.find(dock.pendingId))
                dock.select(dock.pendingId);
            else
                dock.pickDefault();
            dock.pendingId = "";
            composer.forceActiveFocus();
        } else {
            composer.focus = false;
            dock.showHistory = false;
            dock.showKnowledge = false;
            dock.confirmDiscard = false;
        }
    }

    // ── Petits éléments ──────────────────────────────────────────
    component Chip: Rectangle {
        id: chip
        property string label
        property color dot: Theme.textDim
        property bool hasDot: false
        property bool active: false
        property bool pulsing: false
        signal activated()

        // Les pastilles des réglages de la barre de conversation.
        implicitWidth: chipRow.implicitWidth + 18
        implicitHeight: 24
        radius: height / 2
        color: chip.active ? Qt.alpha(Theme.glow(0), 0.3)
                           : (chipMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.1) : "transparent")
        border.width: 1
        border.color: chip.active ? Theme.glow(0) : Qt.alpha(Theme.textPrimary, 0.18)
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6

            Rectangle {
                visible: chip.hasDot
                anchors.verticalCenter: parent.verticalCenter
                width: 7
                height: 7
                radius: 3.5
                color: chip.dot

                SequentialAnimation on opacity {
                    running: chip.pulsing
                    loops: Animation.Infinite
                    alwaysRunToEnd: true
                    NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.label
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: chip.active ? Theme.textPrimary : Theme.textSecondary
            }
        }

        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.activated()
        }
    }

    component ActionButton: Rectangle {
        id: btn
        property string label
        property color tint: Theme.textSecondary
        property bool primary: false
        signal activated()

        implicitWidth: btnText.implicitWidth + 20
        implicitHeight: 24
        radius: height / 2
        color: btn.primary ? btn.tint : (btnMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.1) : "transparent")
        border.width: btn.primary ? 0 : 1
        border.color: Qt.alpha(Theme.textPrimary, 0.18)
        scale: btnMa.pressed ? 0.92 : 1.0
        Behavior on scale { SpringAnimation { spring: 5; damping: 0.28; epsilon: 0.002 } }

        Text {
            id: btnText
            anchors.centerIn: parent
            text: btn.label
            font.family: "JetBrains Mono"
            font.pixelSize: 10
            font.weight: btn.primary ? Font.DemiBold : Font.Normal
            color: btn.primary ? "#ffffff" : btn.tint
        }

        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
    }

    function stateColor(s) {
        return s === "waiting" ? Theme.colorAmber
             : s === "working" ? Theme.glow(0)
             : Theme.textDim;
    }

    function stateLabel(s) {
        return s.state === "waiting" ? "t'attend"
             : s.state === "working" ? "travaille"
             : "au repos";
    }

    function sessionLabel(s) {
        return s.worktree ? s.project + "·" + s.worktree.name.replace(/-[0-9a-f]{4}$/, "") : s.project;
    }

    // ── Surface ──────────────────────────────────────────────────
    // Le même verre que la barre de conversation : translucide, flouté par
    // Hyprland (règle de couche `blur` sur « quickshell-aidock »), un liseré
    // clair en haut. Il sort de la barre des sessions, contre le bord gauche.
    PanelWindow { // qmllint disable uncreatable-type
        id: panel

        screen: dock.screen
        visible: dock.open || card.opacity > 0

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-aidock"
        // Ouvert, il prend le clavier pour de bon : en OnDemand, le compositeur
        // ne route les frappes vers une layer qu'une fois cliquée.
        WlrLayershell.keyboardFocus: dock.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Contre la barre des sessions, sur toute la hauteur : elle réserve
        // sa bande (exclusiveZone), le dock se pose juste après.
        anchors { left: true; top: true; bottom: true }
        margins { // qmllint disable unqualified unresolved-type
            left: 12
            top: 8
            bottom: 8
        }
        exclusiveZone: 0
        color: "transparent"

        implicitWidth: Math.min(520, Math.round((panel.screen ? panel.screen.width : 1280) * 0.36))

        Rectangle {
            id: card
            anchors.fill: parent
            radius: 22
            color: Qt.alpha(Theme.bgDeep, Theme.darkMode ? 0.93 : 0.94)
            border.width: 1
            border.color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.08)

            // Il sort de la barre en grandissant un peu, sur un ressort ; il y
            // rentre en se rétractant.
            opacity: dock.open ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            transform: [
                Scale {
                    origin.x: 0
                    origin.y: card.height / 2
                    xScale: dock.open ? 1 : 0.94
                    yScale: xScale
                    Behavior on xScale { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.002 } }
                },
                Translate {
                    x: dock.open ? 0 : -24
                    Behavior on x { SpringAnimation { spring: 3.5; damping: 0.32; epsilon: 0.1 } }
                }
            ]

            // Le reflet : un liseré clair en haut, qui s'éteint vite.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 1
                height: 60
                radius: card.radius - 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.darkMode ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.5) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                // ── En-tête ──────────────────────────────────────
                // La session regardée (choisie d'un point de la barre), ou
                // la vue ouverte.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 9

                    Rectangle {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        radius: 4
                        visible: dock.selected !== null && !dock.overlay
                        color: dock.selected ? dock.stateColor(dock.selected.state) : "transparent"
                    }

                    Text {
                        visible: dock.selected === null || dock.overlay
                        text: "✦"
                        font.pixelSize: 15
                        color: Theme.glow(0)
                    }

                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: dock.showKnowledge ? "Savoir"
                            : dock.showHistory ? "Historique"
                            : dock.selected ? dock.sessionLabel(dock.selected)
                            : dock.past ? dock.past.project + " — " + dock.past.title
                            : dock.toPilot ? "Pilote" : "Nouvelle session"
                        font.family: dock.uiFont
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: Theme.textPrimary
                    }

                    Text {
                        visible: dock.selected !== null && !dock.overlay
                        text: dock.selected ? dock.stateLabel(dock.selected) : ""
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        color: dock.selected ? dock.stateColor(dock.selected.state) : Theme.textDim
                    }

                    Text {
                        text: "alt+←→ · échap"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 9
                        color: Theme.textDim
                    }
                }

                // Les autres vues : lancer, relire, le savoir.
                Flow {
                    Layout.fillWidth: true
                    spacing: 6

                    Chip {
                        label: "+ nouvelle"
                        active: dock.composingNew && !dock.overlay
                        onActivated: dock.startNew()
                    }

                    Chip {
                        label: "⟲ historique"
                        active: dock.showHistory || dock.past !== null
                        onActivated: {
                            var on = !dock.showHistory;
                            dock.showKnowledge = false;
                            dock.showHistory = on;
                            if (on)
                                ClaudeSessions.ensureIndex();
                        }
                    }

                    Chip {
                        label: "◈ savoir" + (dock.toReview > 0 ? "  " + dock.toReview : "")
                        active: dock.showKnowledge
                        onActivated: {
                            var on = !dock.showKnowledge;
                            dock.showHistory = false;
                            dock.showKnowledge = on;
                            if (on) {
                                ClaudeLive.loadNotes();
                                composer.text = "";
                                composer.forceActiveFocus();
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Theme.dividerColor
                }

                // ── Corps ────────────────────────────────────────
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // Savoir : filtres, notes, aperçu.
                    ColumnLayout {
                        anchors.fill: parent
                        visible: dock.showKnowledge
                        spacing: 8

                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            Repeater {
                                model: [
                                    { key: "", label: "tout" },
                                    { key: "à-relire", label: "à relire" },
                                    { key: "recherche", label: "recherche" },
                                    { key: "projet", label: "projets" },
                                    { key: "skill", label: "skills" },
                                    { key: "lab", label: "lab" },
                                    { key: "journal", label: "journal" }
                                ]

                                Chip {
                                    required property var modelData
                                    readonly property int count: ClaudeLive.notes.filter(n =>
                                        modelData.key === "" ? true
                                        : modelData.key === "à-relire" ? n.statut === "à-relire"
                                        : n.kind === modelData.key).length
                                    visible: modelData.key === "" || count > 0
                                    label: modelData.label + "  " + count
                                    active: dock.noteFilter === modelData.key
                                    onActivated: dock.noteFilter = modelData.key
                                }
                            }
                        }

                        // Les notes en haut, la note ouverte en dessous : le
                        // panneau est trop étroit pour les mettre côte à côte.
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 8

                            ListView {
                                id: noteList
                                Layout.fillWidth: true
                                Layout.preferredHeight: 200
                                clip: true
                                spacing: 2
                                model: dock.shownNotes

                                delegate: Rectangle {
                                    id: noteRow
                                    required property var modelData
                                    width: noteList.width
                                    height: noteCol.implicitHeight + 10
                                    radius: 12
                                    color: dock.note && dock.note.path === noteRow.modelData.path
                                           ? Qt.alpha(Theme.glow(0), 0.22)
                                           : (noteMa.containsMouse ? Qt.alpha(Theme.glow(0), 0.1) : "transparent")

                                    Column {
                                        id: noteCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        spacing: 2

                                        Text {
                                            width: parent.width
                                            text: (noteRow.modelData.statut === "à-relire" ? "● " : "")
                                                  + noteRow.modelData.title
                                            elide: Text.ElideRight
                                            font.family: dock.uiFont
                                            font.pixelSize: 12
                                            color: Theme.textPrimary
                                        }
                                        Text {
                                            width: parent.width
                                            text: {
                                                var n = noteRow.modelData;
                                                var bits = [n.kind];
                                                if (n.projet)
                                                    bits.push(n.projet);
                                                if (n.sujets.length > 0)
                                                    bits.push(n.sujets.join(", "));
                                                if (n.revu || n.date)
                                                    bits.push(n.revu || n.date);
                                                return bits.join("  ·  ");
                                            }
                                            elide: Text.ElideRight
                                            font.family: "JetBrains Mono"
                                            font.pixelSize: 9
                                            color: Theme.textDim
                                        }
                                    }

                                    MouseArea {
                                        id: noteMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: dock.openNote(noteRow.modelData)
                                    }
                                }

                                Text {
                                    anchors.fill: parent
                                    visible: noteList.count === 0
                                    wrapMode: Text.Wrap
                                    text: ClaudeLive.notes.length === 0
                                          ? "Le coffre est vide pour l'instant. En fin de session, « ◈ Capitaliser » "
                                            + "y range ce qui mérite d'être gardé."
                                          : "Aucune note ne correspond."
                                    font.family: dock.uiFont
                                    font.pixelSize: 12
                                    color: Theme.textDim
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: Theme.dividerColor
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 8

                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: dock.note !== null
                                    spacing: 6

                                    Text {
                                        Layout.fillWidth: true
                                        text: dock.note ? dock.note.path : ""
                                        elide: Text.ElideMiddle
                                        font.family: "JetBrains Mono"
                                        font.pixelSize: 9
                                        color: Theme.textDim
                                    }
                                    ActionButton {
                                        visible: dock.note !== null && dock.note.statut === "à-relire"
                                        label: "Relu"
                                        primary: true
                                        tint: Theme.glow(0)
                                        onActivated: {
                                            var path = dock.note.path;
                                            ClaudeLive.markReviewed(path, function (ok) {
                                                if (ok && dock.note && dock.note.path === path)
                                                    dock.note = ClaudeLive.notes.find(n => n.path === path) || dock.note;
                                            });
                                        }
                                    }
                                    ActionButton {
                                        visible: dock.sessionOf(dock.note) !== null
                                        label: "Session"
                                        onActivated: dock.selectPast(dock.sessionOf(dock.note))
                                    }
                                    ActionButton {
                                        visible: dock.note !== null
                                        label: "Obsidian"
                                        onActivated: {
                                            ClaudeLive.openNote(dock.note.path);
                                            dock.closeRequested();
                                        }
                                    }
                                }

                                ScrollView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                                    TextEdit {
                                        width: parent.width
                                        readOnly: true
                                        selectByMouse: true
                                        wrapMode: TextEdit.Wrap
                                        textFormat: TextEdit.MarkdownText
                                        text: dock.note ? dock.noteText
                                              : "Choisis une note au-dessus — ou tape pour chercher, puis Entrée."
                                        font.family: dock.uiFont
                                        font.pixelSize: 13
                                        color: dock.note ? Theme.textBody : Theme.textDim
                                        selectionColor: Theme.glow(0)
                                        selectedTextColor: Theme.selectedTextColor
                                    }
                                }
                            }
                        }
                    }

                    // Historique
                    ListView {
                        id: history
                        anchors.fill: parent
                        visible: dock.showHistory
                        clip: true
                        spacing: 2
                        model: ClaudeSessions.liveSessions.slice(0, 60)

                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            width: history.width
                            height: 30
                            radius: 12
                            color: rowMa.containsMouse ? Qt.alpha(Theme.glow(0), 0.1) : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 12

                                Text {
                                    Layout.preferredWidth: 130
                                    text: row.modelData.project
                                    elide: Text.ElideRight
                                    font.family: dock.uiFont
                                    font.pixelSize: 12
                                    color: Theme.textPrimary
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: row.modelData.title
                                    elide: Text.ElideRight
                                    font.family: dock.uiFont
                                    font.pixelSize: 12
                                    color: Theme.textSecondary
                                }
                                Text {
                                    text: ClaudeSessions.ago(row.modelData.at)
                                    font.family: "JetBrains Mono"
                                    font.pixelSize: 10
                                    color: Theme.textDim
                                }
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dock.selectPast(row.modelData)
                            }
                        }
                    }

                    // Hors session : à qui parler — le pilote, ou une
                    // nouvelle session dans un projet.
                    ColumnLayout {
                        anchors.fill: parent
                        visible: dock.composingNew && !dock.overlay
                        spacing: 10

                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            Chip {
                                label: "✦ pilote"
                                active: dock.toPilot
                                onActivated: dock.targetIndex = -1
                            }

                            Repeater {
                                model: ClaudeLive.projects

                                Chip {
                                    required property var modelData
                                    required property int index
                                    label: modelData.kind === "recherche" ? "✎ recherche" : modelData.name
                                    active: dock.targetIndex === index
                                    onActivated: dock.targetIndex = index
                                }
                            }
                        }

                        // Pilote : ses échanges.
                        ListView {
                            id: pilotThread
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: dock.toPilot
                            clip: true
                            spacing: 6
                            model: ClaudeLive.pilotItems
                            boundsBehavior: Flickable.StopAtBounds
                            onCountChanged: Qt.callLater(pilotThread.positionViewAtEnd)

                            delegate: Item {
                                id: item
                                required property var modelData
                                width: pilotThread.width - 12
                                height: itemText.implicitHeight + (item.modelData.kind === "user" ? 12 : 0)

                                Rectangle {
                                    anchors.fill: parent
                                    visible: item.modelData.kind === "user"
                                    radius: 14
                                    color: Qt.alpha(Theme.glow(0), 0.1)
                                }

                                TextEdit {
                                    id: itemText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: item.modelData.kind === "user" ? 10 : 2
                                    anchors.rightMargin: item.modelData.kind === "user" ? 10 : 2
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: TextEdit.Wrap
                                    textFormat: item.modelData.kind === "reply" ? TextEdit.MarkdownText
                                                                               : TextEdit.PlainText
                                    text: item.modelData.kind === "action" ? "· " + item.modelData.text
                                        : item.modelData.kind === "error" ? "⚠ " + item.modelData.text
                                        : item.modelData.text
                                    font.family: item.modelData.kind === "action" ? "JetBrains Mono" : dock.uiFont
                                    font.pixelSize: item.modelData.kind === "action" ? 10 : 14
                                    color: item.modelData.kind === "action" ? Theme.accentMuted
                                         : item.modelData.kind === "error" ? Theme.colorDanger
                                         : item.modelData.kind === "user" ? Theme.textPrimary
                                         : Theme.textBody
                                    selectionColor: Theme.glow(0)
                                    selectedTextColor: Theme.selectedTextColor
                                }
                            }

                            footer: Text {
                                visible: ClaudeLive.pilotBusy
                                height: visible ? implicitHeight + 8 : 0
                                topPadding: 8
                                text: "…"
                                font.family: "JetBrains Mono"
                                font.pixelSize: 14
                                color: Theme.glow(0)
                            }

                            Text {
                                anchors.fill: parent
                                visible: pilotThread.count === 0
                                wrapMode: Text.Wrap
                                text: "Le pilote agit sur ton bureau : son, fenêtres, applications, "
                                      + "projets, notes. Une tâche de code ou de recherche, il la confie "
                                      + "à une session complète, qui apparaît en haut.\n\n"
                                      + "« baisse le son »   « ouvre zed sur karenine »   "
                                      + "« corrige le dock qui s'ouvre tout seul dans karenine »"
                                font.family: dock.uiFont
                                font.pixelSize: 12
                                color: Theme.textDim
                            }
                        }

                        // Session : où, et comment.
                        Text {
                            Layout.fillWidth: true
                            visible: !dock.toPilot
                            wrapMode: Text.Wrap
                            text: "Une session Claude Code complète, lancée directement. "
                                  + "Dans un dépôt, elle travaille par défaut dans une copie isolée : "
                                  + "ton code ne bouge pas tant que tu n'as pas fusionné."
                            font.family: dock.uiFont
                            font.pixelSize: 12
                            color: Theme.textSecondary
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            Chip {
                                visible: dock.target !== null && dock.target.kind === "projet"
                                label: (dock.isolate ? "☑" : "☐") + " copie isolée (worktree)"
                                active: dock.isolate
                                onActivated: dock.isolate = !dock.isolate
                            }

                            Chip {
                                visible: dock.toPilot
                                label: (dock.withClipboard ? "☑" : "☐") + " joindre le presse-papiers"
                                active: dock.withClipboard
                                onActivated: dock.withClipboard = !dock.withClipboard
                            }

                            Chip {
                                visible: dock.toPilot && pilotThread.count > 0
                                label: "↺ oublier"
                                onActivated: ClaudeLive.pilotReset()
                            }
                        }

                        Item {
                            Layout.fillHeight: true
                            visible: !dock.toPilot
                        }
                    }

                    // Conversation
                    ListView {
                        id: thread
                        anchors.fill: parent
                        visible: !dock.overlay && !dock.composingNew
                        clip: true
                        spacing: 8
                        model: ClaudeLive.messages
                        boundsBehavior: Flickable.StopAtBounds

                        property bool stick: true
                        onMovementEnded: thread.stick = thread.atYEnd
                        onCountChanged: if (thread.stick) Qt.callLater(thread.positionViewAtEnd)
                        onContentHeightChanged: if (thread.stick) Qt.callLater(thread.positionViewAtEnd)

                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        delegate: Item {
                            id: msg
                            required property string role
                            required property string text
                            width: thread.width - 12
                            height: body.implicitHeight + (msg.role === "user" ? 12 : 0)

                            Rectangle {
                                anchors.fill: parent
                                visible: msg.role === "user"
                                radius: 14
                                color: Qt.alpha(Theme.glow(0), 0.1)
                            }

                            TextEdit {
                                id: body
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: msg.role === "user" ? 10 : 2
                                anchors.rightMargin: msg.role === "user" ? 10 : 2
                                readOnly: true
                                selectByMouse: true
                                wrapMode: TextEdit.Wrap
                                textFormat: msg.role === "assistant" ? TextEdit.MarkdownText : TextEdit.PlainText
                                text: msg.role === "tool" ? "· " + msg.text : msg.text
                                font.family: msg.role === "tool" ? "JetBrains Mono" : dock.uiFont
                                font.pixelSize: msg.role === "tool" ? 10 : 14
                                color: msg.role === "tool" ? Theme.accentMuted
                                     : msg.role === "user" ? Theme.textPrimary
                                     : Theme.textBody
                                selectionColor: Theme.glow(0)
                                selectedTextColor: Theme.selectedTextColor
                            }
                        }

                        // Une session qui démarre n'a pas encore de transcript.
                        Text {
                            anchors.centerIn: parent
                            visible: thread.count === 0
                            text: dock.selected && dock.selected.state === "working"
                                  ? "Claude démarre…" : "Rien à afficher pour l'instant."
                            font.family: dock.uiFont
                            font.pixelSize: 12
                            color: Theme.textDim
                        }
                    }
                }

                // ── Le travail de la session ─────────────────────
                // Où elle travaille, puis ses actions, qui passent à la ligne.
                Text {
                    Layout.fillWidth: true
                    visible: !dock.overlay && dock.selected !== null
                    elide: Text.ElideRight
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Theme.textSecondary
                    text: {
                        var s = dock.selected;
                        if (!s)
                            return "";
                        if (!s.worktree)
                            return s.cwd.replace(/^\/home\/[^/]+/, "~")
                                   + (s.managed ? "" : "  ·  dans un terminal");
                        var r = dock.review;
                        if (!r)
                            return s.worktree.branch;
                        var add = 0, del = 0;
                        for (var i = 0; i < r.files.length; i++) {
                            add += r.files[i].added;
                            del += r.files[i].removed;
                        }
                        var bits = [s.worktree.branch];
                        bits.push(r.files.length === 0 ? "aucune modification en cours"
                                  : r.files.length + " fichier" + (r.files.length > 1 ? "s" : "")
                                    + "  +" + add + " −" + del);
                        if (r.ahead > 0)
                            bits.push(r.ahead + " commit" + (r.ahead > 1 ? "s" : "") + " à fusionner dans " + r.base);
                        return bits.join("  ·  ");
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    visible: !dock.overlay && dock.selected !== null
                    spacing: 6

                    // Le tour est fini : ranger dans le coffre ce qu'il a appris
                    // (commande /capitaliser, cf. la config NixOS).
                    ActionButton {
                        visible: dock.selected !== null && dock.selected.managed
                                 && dock.selected.state === "idle" && dock.selected.id !== "pilote"
                        label: "◈ Capitaliser"
                        tint: Theme.glow(0)
                        onActivated: ClaudeLive.send(dock.selected.id, "/capitaliser", dock.selected.cwd)
                    }
                    ActionButton {
                        visible: dock.selected !== null && dock.selected.managed && dock.selected.state !== "idle"
                        label: "Arrêter"
                        tint: Theme.colorDanger
                        onActivated: ClaudeLive.stop(dock.selectedId)
                    }
                    ActionButton {
                        label: "Zed"
                        onActivated: ClaudeLive.open(dock.selected.cwd, "zed", "")
                    }
                    ActionButton {
                        label: "Terminal"
                        onActivated: {
                            var s = dock.selected;
                            // Une session de terminal : sa fenêtre existe déjà.
                            if (s.managed)
                                ClaudeLive.open(s.cwd, "terminal", s.id);
                            else
                                ClaudeLive.focus(s.id);
                            dock.closeRequested();
                        }
                    }
                    ActionButton {
                        visible: dock.review !== null && dock.review.files.length > 0
                        label: "Commit"
                        tint: Theme.glow(0)
                        onActivated: ClaudeLive.worktree(dock.selected.cwd, "commit",
                                                         dock.selected.prompt, dock.selectedId,
                                                         function () { dock.refreshReview(); })
                    }
                    ActionButton {
                        visible: dock.review !== null && dock.review.ahead > 0 && dock.review.files.length === 0
                        label: "Fusionner"
                        primary: true
                        tint: Theme.glow(0)
                        onActivated: {
                            var id = dock.selectedId;
                            ClaudeLive.worktree(dock.selected.cwd, "merge", "", id, function (ok) {
                                if (ok && dock.selectedId === id)
                                    dock.review = null;
                            });
                        }
                    }
                    ActionButton {
                        visible: dock.review !== null
                        label: dock.confirmDiscard ? "Vraiment jeter ?" : "Jeter"
                        tint: Theme.colorDanger
                        primary: dock.confirmDiscard
                        onActivated: {
                            if (!dock.confirmDiscard) {
                                dock.confirmDiscard = true;
                                return;
                            }
                            dock.confirmDiscard = false;
                            var id = dock.selectedId;
                            ClaudeLive.worktree(dock.selected.cwd, "discard", "", id, function (ok) {
                                if (ok && dock.selectedId === id)
                                    dock.review = null;
                            });
                        }
                    }
                }

                // ── Saisie ───────────────────────────────────────
                // La capsule de la barre de conversation : ronde tant qu'elle
                // tient sur une ligne, le bouton ↑ qui éclot à droite.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(140, Math.max(44, composer.implicitHeight + 8))
                    radius: Math.min(height / 2, 22)
                    color: Qt.alpha(Theme.bgDeep, Theme.darkMode ? 0.62 : 0.7)
                    border.width: 1
                    border.color: composer.activeFocus ? Qt.alpha(Theme.glow(0), 0.6)
                                  : Theme.darkMode ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.08)
                    Behavior on border.color { ColorAnimation { duration: 160 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 9
                        spacing: 8

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: !dock.composingNew ? "›"
                                  : dock.toPilot ? "✦ ›"
                                  : dock.target
                                    ? (dock.target.kind === "recherche" ? "✎" : dock.target.name
                                       + (dock.isolate ? " ⎇" : "")) + " ›"
                                    : "›"
                            font.family: dock.uiFont
                            font.pixelSize: 13
                            color: Theme.glow(0)
                        }

                        ScrollView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                            TextArea {
                                id: composer
                                wrapMode: TextArea.Wrap
                                // Lecture seule plutôt que désactivé : le champ
                                // garde le focus, donc Échap et Alt+←/→.
                                readOnly: dock.inTerminal
                                font.weight: Font.Medium
                                placeholderText: {
                                    if (dock.showKnowledge)
                                        return "Chercher dans le savoir…  (⏎ ouvre la première note)";
                                    if (dock.composingNew && dock.toPilot)
                                        return ClaudeLive.pilotBusy
                                               ? "Le pilote travaille…"
                                               : "Demande au pilote : son, fenêtres, apps, notes, ou une tâche de code…";
                                    if (dock.composingNew)
                                        return "Demande à Claude…  (⏎ envoie, espace maintenu dicte, ⇧⏎ nouvelle ligne)";
                                    if (dock.past)
                                        return "Reprendre cette conversation…";
                                    if (dock.inTerminal)
                                        return "Session ouverte dans un terminal : réponds-y (bouton Terminal)";
                                    return "Répondre à Claude…";
                                }
                                placeholderTextColor: Qt.alpha(Theme.textPrimary, 0.42)
                                font.family: dock.uiFont
                                font.pixelSize: 14
                                selectionColor: Qt.alpha(Theme.glow(0), 0.45)
                                selectedTextColor: Theme.textPrimary
                                color: Theme.textPrimary
                                background: Item {}
                                topPadding: 10
                                bottomPadding: 10
                                leftPadding: 0
                                rightPadding: 0

                                Keys.onEscapePressed: dock.closeRequested()
                                Keys.onReturnPressed: (event) => {
                                    if (event.modifiers & Qt.ShiftModifier)
                                        insert(cursorPosition, "\n");
                                    else
                                        dock.submit();
                                }
                                Keys.onEnterPressed: dock.submit()
                                // Espace maintenu : dictée (dock.keyPressed).
                                Keys.onReleased: (event) => dock.keyReleased(event)
                                // Alt+← / Alt+→ : session précédente / suivante.
                                Keys.onPressed: (event) => {
                                    dock.keyPressed(event);
                                    if (event.accepted || !(event.modifiers & Qt.AltModifier))
                                        return;
                                    if (event.key === Qt.Key_Left) {
                                        dock.cycleSession(-1);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Right) {
                                        dock.cycleSession(1);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_N) {
                                        dock.startNew();
                                        event.accepted = true;
                                    }
                                }
                            }
                        }

                        // Le mot d'activation : « Karénine » allumé, le micro
                        // reste ouvert ; un clic l'éteint.
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            visible: !dock.overlay && !dock.inTerminal
                            text: ClaudeLive.voiceWake ? "◉ Karénine" : "○ Karénine"
                            font.family: dock.uiFont
                            font.pixelSize: 12
                            color: ClaudeLive.voiceWake
                                   ? Theme.glow(0)
                                   : (wakeMa.containsMouse ? Theme.textPrimary : Theme.textDim)

                            MouseArea {
                                id: wakeMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: ClaudeLive.voiceWakeToggle()
                            }
                        }

                        // Parler au pilote plutôt qu'écrire (comme Super+V).
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            visible: !dock.overlay && !dock.inTerminal
                            text: ClaudeLive.voicePhase === "idle" ? "🎙"
                                  : ClaudeLive.voicePhase === "listening" ? "● j'écoute" : "… transcription"
                            font.family: dock.uiFont
                            font.pixelSize: 13
                            color: ClaudeLive.voicePhase === "idle"
                                   ? (micMa.containsMouse ? Theme.glow(0) : Theme.textDim)
                                   : Theme.glow(0)

                            MouseArea {
                                id: micMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (ClaudeLive.voicePhase === "idle")
                                        dock.startDictation(false);
                                    else
                                        ClaudeLive.voiceToggle(false);
                                }
                            }
                        }

                        // Le bouton d'envoi, qui éclot quand il y a quelque
                        // chose à envoyer.
                        Rectangle {
                            id: sendBtn
                            readonly property bool on: composer.text.trim().length > 0
                                                       && !dock.showKnowledge && !dock.inTerminal
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            radius: 13
                            color: Theme.glow(0)
                            opacity: sendBtn.on ? 1 : 0
                            scale: sendBtn.on ? (sendMa.pressed ? 0.88 : 1) : 0.4
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                            Behavior on scale { SpringAnimation { spring: 5; damping: 0.28; epsilon: 0.002 } }

                            Text {
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -1
                                text: "↑"
                                font.family: dock.uiFont
                                font.pixelSize: 15
                                font.weight: Font.Bold
                                color: "#ffffff"
                            }

                            MouseArea {
                                id: sendMa
                                anchors.fill: parent
                                enabled: sendBtn.on
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dock.submit()
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: ClaudeLive.lastError.length > 0
                    text: "⚠ " + ClaudeLive.lastError
                    elide: Text.ElideRight
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Theme.colorDanger
                }
            }
        }
    }
}
