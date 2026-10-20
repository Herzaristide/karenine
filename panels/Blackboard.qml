pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

// Le fond d'écran : un tableau noir, sous toutes les fenêtres (la couche
// Background du layer-shell). Il porte les notes qu'on y a posées, en
// cartes, et les traits de craie autour (services/Board.qml). Chaque écran
// a le sien : ce qu'on y écrit reste sur cet écran.
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │  ╭──────────────╮               ╭──╮                          │
//   │  │ Acheter du   │               ╰──╯  ← un trait de craie     │
//   │  │ pain      📌 │      ╭──────────────╮                       │
//   │  ╰──────────────╯      │ RDV jeudi    │                       │
//   │                        ╰──────────────╯                       │
//   └──────────────────────────────────────────────────────────────┘
//
// Là où le bureau se voit, on y écrit :
//   - un clic dans le vide : une carte s'ouvre à cet endroit, on tape
//     (Échap, Ctrl+Entrée ou un clic ailleurs la pose ; vide, elle
//     disparaît) ;
//   - glisser : un trait de craie (Maj : la craie de couleur, l'accent) ;
//   - clic droit et glisser : le chiffon, qui efface les traits touchés ;
//   - une carte : un clic l'édite (la vider supprime la note), glisser la
//     déplace, un clic droit la retire du tableau (elle reste une note) ;
//   - une carte de l'onglet Notes, glissée ici, s'y pose (ou s'y déplace) ;
//     du texte glissé d'une autre application devient une note ;
//   - Ctrl+Z défait, Ctrl+Maj+Z ou Ctrl+Y refait.
//
// L'ardoise est l'encre d'Ajar (Theme.bgDeep), les cartes le panneau
// (Theme.bgElevated) avec le filet de l'onglet Notes, la craie le texte et la
// craie de couleur l'accent : le tableau suit le thème et `anna set` à
// chaud, comme le reste du shell.
PanelWindow { // qmllint disable uncreatable-type
    id: slate

    // L'écran de ce tableau (sa clé, cf. Display.screenKey), et s'il porte
    // l'interface : celui-là garde aussi ce qui a été posé avant qu'il y ait
    // un tableau par écran.
    readonly property string key: Display.screenKey(slate.screen)
    readonly property bool primary: slate.screen === Display.primary

    // Ce qui est à ce tableau-ci.
    readonly property var notes: Board.on(Board.notes, slate.key, slate.primary)
    readonly property var strokes: Board.on(Board.strokes, slate.key, slate.primary)

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "quickshell-blackboard"
    // Le clavier au clic seulement : il revient aux fenêtres dès qu'on
    // clique dans l'une d'elles.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }
    color: Theme.bgDeep

    // La marge que garde une carte du bord de l'écran.
    readonly property int margin: 24
    readonly property int cardWidth: 240
    readonly property int cardPadding: 14
    readonly property int fontSize: 14
    readonly property real chalkWidth: 3
    readonly property real eraserRadius: 16
    readonly property real inkAlpha: 0.85

    // Le trait en cours (pixels), et ceux qui attendent qu'anna les écrive :
    // dessinés à part pour que rien ne clignote entre le geste et le fichier.
    property var livePoints: []
    property string liveInk: "chalk"
    property var pending: []
    // Les traits que le chiffon vient d'emporter, cachés en attendant.
    property var erasing: []

    // La note qu'on édite, et celle qu'on compose (un clic dans le vide).
    property string editingId: ""
    property bool composing: false
    property real composeX: 0
    property real composeY: 0

    // Le fichier a suivi : ce qui attendait y est.
    Connections {
        target: Board
        function onStrokesChanged() {
            slate.pending = [];
            slate.erasing = [];
        }
    }

    function inkColor(ink) {
        return Qt.alpha(ink === "accent" ? Theme.accentColor : Theme.textPrimary, slate.inkAlpha);
    }

    function paintStroke(ctx, pts, ink, width) {
        if (pts.length === 0)
            return;
        ctx.strokeStyle = slate.inkColor(ink);
        ctx.fillStyle = ctx.strokeStyle;
        ctx.lineWidth = width;
        if (pts.length === 1) {
            // Un point : un rond de la largeur du trait.
            ctx.beginPath();
            ctx.arc(pts[0][0], pts[0][1], width / 2, 0, 2 * Math.PI);
            ctx.fill();
            return;
        }
        ctx.beginPath();
        ctx.moveTo(pts[0][0], pts[0][1]);
        for (var j = 1; j < pts.length; j++)
            ctx.lineTo(pts[j][0], pts[j][1]);
        ctx.stroke();
    }

    // Une carte tient dans l'écran, à `margin` du bord.
    function clampX(x, w) {
        return Math.max(slate.margin, Math.min(x, slate.width - w - slate.margin));
    }
    function clampY(y, h) {
        return Math.max(slate.margin, Math.min(y, slate.height - h - slate.margin));
    }

    // Tout ce qui a le clavier passe par ici.
    FocusScope {
        id: root
        anchors.fill: parent
        focus: true

        Keys.onPressed: (event) => {
            var ctrl = event.modifiers & Qt.ControlModifier;
            var shift = event.modifiers & Qt.ShiftModifier;
            if (ctrl && event.key === Qt.Key_Z) {
                if (shift)
                    Board.redo();
                else
                    Board.undo();
                event.accepted = true;
            } else if (ctrl && event.key === Qt.Key_Y) {
                Board.redo();
                event.accepted = true;
            }
        }

        // ── Le quadrillage ───────────────────────────────────────
        // Du papier millimétré à peine visible : une case de `cell`, une
        // ligne un peu plus marquée toutes les quatre. Sur chaque écran, pour
        // que l'ardoise soit la même partout. Les lignes tombent sur des
        // pixels entiers (le +0,5) : nettes, sans flou d'anticrénelage.
        Canvas {
            id: grid
            anchors.fill: parent
            readonly property int cell: 48
            property color ink: Theme.textPrimary
            onInkChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.lineWidth = 1;
                var lines = function (major) {
                    ctx.strokeStyle = Qt.alpha(ink, major ? 0.06 : 0.03);
                    ctx.beginPath();
                    for (var i = 0, x = 0; x <= width; i++, x += cell) {
                        if ((i % 4 === 0) === major) {
                            ctx.moveTo(x + 0.5, 0);
                            ctx.lineTo(x + 0.5, height);
                        }
                    }
                    for (var j = 0, y = 0; y <= height; j++, y += cell) {
                        if ((j % 4 === 0) === major) {
                            ctx.moveTo(0, y + 0.5);
                            ctx.lineTo(width, y + 0.5);
                        }
                    }
                    ctx.stroke();
                };
                lines(false);
                lines(true);
            }
        }

        // ── L'heure ──────────────────────────────────────────────
        // En haut à gauche, calée sur le quadrillage. Sous la craie et les
        // cartes : on écrit par-dessus comme sur le reste du tableau.
        BoardClock {
            x: grid.cell * 2
            y: grid.cell * 2
            size: Math.round(slate.height * 0.19)
        }

        // ── Les traits de craie ──────────────────────────────────
        Canvas {
            id: chalk
            anchors.fill: parent
            // Redessiné quand les traits, la taille ou les couleurs changent.
            property var strokes: slate.strokes
            property var hidden: slate.erasing
            property color chalkColor: Theme.textPrimary
            property color accentColor: Theme.accentColor
            onStrokesChanged: requestPaint()
            onHiddenChanged: requestPaint()
            onChalkColorChanged: requestPaint()
            onAccentColorChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                for (var i = 0; i < strokes.length; i++) {
                    var s = strokes[i];
                    if (hidden.indexOf(s.id) >= 0)
                        continue;
                    var pts = (s.points || []).map(p => [p[0] * width, p[1] * height]);
                    slate.paintStroke(ctx, pts, s.ink, s.width || slate.chalkWidth);
                }
            }
        }

        // Le trait en cours et ceux qui attendent : redessinés à chaque
        // mouvement, sans toucher aux autres.
        Canvas {
            id: live
            anchors.fill: parent
            property var points: slate.livePoints
            property var waiting: slate.pending
            onPointsChanged: requestPaint()
            onWaitingChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                for (var i = 0; i < waiting.length; i++)
                    slate.paintStroke(ctx, waiting[i].points, waiting[i].ink, slate.chalkWidth);
                slate.paintStroke(ctx, points, slate.liveInk, slate.chalkWidth);
            }
        }

        // ── Le vide : écrire, dessiner, effacer ──────────────────
        MouseArea {
            id: surface
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: pressedButtons & Qt.RightButton ? Qt.OpenHandCursor : Qt.CrossCursor

            property real startX: 0
            property real startY: 0
            property bool moved: false
            // Ce clic pose la note qu'on écrivait : il n'en ouvre pas d'autre.
            property bool finishing: false

            onPressed: (m) => {
                finishing = slate.composing || slate.editingId !== "";
                root.forceActiveFocus();
                startX = m.x;
                startY = m.y;
                moved = false;
                if (m.button === Qt.RightButton) {
                    slate.wipe(m.x, m.y);
                } else {
                    slate.liveInk = (m.modifiers & Qt.ShiftModifier) ? "accent" : "chalk";
                    slate.livePoints = [[m.x, m.y]];
                }
            }

            onPositionChanged: (m) => {
                if (!moved && Math.hypot(m.x - startX, m.y - startY) > 4)
                    moved = true;
                if (pressedButtons & Qt.RightButton) {
                    slate.wipe(m.x, m.y);
                    return;
                }
                var last = slate.livePoints[slate.livePoints.length - 1];
                if (last && Math.hypot(m.x - last[0], m.y - last[1]) >= 1.5)
                    slate.livePoints = slate.livePoints.concat([[m.x, m.y]]);
            }

            onReleased: (m) => {
                if (m.button === Qt.RightButton) {
                    Board.erase(slate.erasing);
                    return;
                }
                var pts = slate.livePoints;
                slate.livePoints = [];
                if (!moved) {
                    if (!finishing)
                        slate.compose(startX, startY);
                    return;
                }
                var simple = Chalk.simplify(pts, 1.2);
                slate.pending = slate.pending.concat([{ points: simple, ink: slate.liveInk }]);
                Board.draw({
                    ink: slate.liveInk,
                    width: slate.chalkWidth,
                    points: simple.map(p => [Chalk.fraction(p[0] / slate.width),
                                             Chalk.fraction(p[1] / slate.height)]),
                    screen: slate.key
                });
            }
        }

        // ── Ce qu'on y dépose ────────────────────────────────────
        // Une carte de l'onglet Notes (son id, cf. widgets/NotesWidget.qml),
        // ou du texte d'une autre application. La carte se pose sous le
        // curseur, son coin haut gauche un peu au-dessus à gauche, comme on
        // la tenait.
        DropArea {
            anchors.fill: parent
            keys: ["application/x-karenine-note", "text/plain"]

            onDropped: (drop) => {
                var x = slate.clampX(drop.x - 24, slate.cardWidth) / slate.width;
                var y = slate.clampY(drop.y - 16, 60) / slate.height;
                var id = drop.formats.indexOf("application/x-karenine-note") >= 0
                         ? drop.getDataAsString("application/x-karenine-note") : "";
                if (id !== "")
                    Board.placeFromTab(id, x, y, slate.key);
                else if (drop.hasText && drop.text.trim() !== "")
                    Board.addNote(drop.text.trim(), x, y, slate.key);
                else
                    return;
                drop.accept(Qt.CopyAction);
            }
        }

        // ── Les cartes posées ────────────────────────────────────
        Repeater {
            model: slate.notes

            delegate: Card {
                id: placed
                required property var modelData

                note: modelData
                editing: slate.editingId === modelData.id

                // Pendant qu'on la glisse, elle suit la souris ; sinon sa place.
                property bool dragging: false
                property real dragX: 0
                property real dragY: 0

                x: dragging ? dragX : slate.clampX(modelData.board.x * slate.width, width)
                y: dragging ? dragY : slate.clampY(modelData.board.y * slate.height, height)
                z: dragging || editing ? 2 : 1

                onFinished: (text) => {
                    slate.editingId = "";
                    Board.editNote(placed.modelData, text);
                }

                // Cliquer, glisser, retirer. Pendant l'édition, le texte
                // garde la souris (sélection, curseur).
                MouseArea {
                    anchors.fill: parent
                    enabled: !placed.editing
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: placed.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    onContainsMouseChanged: placed.hovered = containsMouse

                    property real offsetX: 0
                    property real offsetY: 0
                    property real startX: 0
                    property real startY: 0

                    onPressed: (m) => {
                        root.forceActiveFocus();
                        var p = mapToItem(slate.contentItem, m.x, m.y);
                        startX = p.x;
                        startY = p.y;
                        offsetX = p.x - placed.x;
                        offsetY = p.y - placed.y;
                    }

                    onPositionChanged: (m) => {
                        if (!(pressedButtons & Qt.LeftButton))
                            return;
                        var p = mapToItem(slate.contentItem, m.x, m.y);
                        if (!placed.dragging && Math.hypot(p.x - startX, p.y - startY) > 4) {
                            placed.dragX = placed.x;
                            placed.dragY = placed.y;
                            placed.dragging = true;
                        }
                        if (placed.dragging) {
                            placed.dragX = slate.clampX(p.x - offsetX, placed.width);
                            placed.dragY = slate.clampY(p.y - offsetY, placed.height);
                        }
                    }

                    onReleased: (m) => {
                        if (m.button === Qt.RightButton) {
                            Board.unplace(placed.modelData);
                            return;
                        }
                        if (placed.dragging) {
                            // Gardée où on la lâche jusqu'à ce que le fichier
                            // suive (la carte est alors recréée).
                            Board.move(placed.modelData, placed.dragX / slate.width, placed.dragY / slate.height);
                            return;
                        }
                        slate.editingId = placed.modelData.id;
                        placed.edit(mapToItem(placed.editor, m.x, m.y));
                    }
                }
            }
        }

        // ── La carte qu'on compose ───────────────────────────────
        Card {
            id: composer
            visible: slate.composing
            note: ({ id: "", text: "", image: "", pinned: false })
            editing: slate.composing
            x: slate.clampX(slate.composeX, width)
            y: slate.clampY(slate.composeY, height)
            z: 3

            onFinished: (text) => {
                slate.composing = false;
                if (text !== "")
                    Board.addNote(text, composer.x / slate.width, composer.y / slate.height, slate.key);
            }
        }

        // Ce qu'anna a refusé, discrètement, en bas à gauche.
        Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: slate.margin
            visible: Board.feedback !== ""
            text: Board.feedback
            font.family: "Inter"
            font.pixelSize: 13
            color: Theme.textDim
        }
    }

    // Une note commence là où l'on clique : la carte s'ouvre sous le
    // curseur, le texte à l'endroit du clic.
    function compose(x, y) {
        slate.composeX = x - slate.cardPadding;
        slate.composeY = y - slate.cardPadding - slate.fontSize * 0.6;
        slate.composing = true;
        composer.edit(null);
    }

    // Le chiffon : les traits sous lui disparaissent, en attendant qu'anna
    // les efface pour de bon au relâcher.
    function wipe(x, y) {
        var hit = Chalk.strokesNear(slate.strokes, [x, y], slate.eraserRadius, slate.width, slate.height);
        var fresh = hit.filter(id => slate.erasing.indexOf(id) < 0);
        if (fresh.length > 0)
            slate.erasing = slate.erasing.concat(fresh);
    }

    // ── Une carte ────────────────────────────────────────────────
    // Celle de l'onglet Notes, à l'échelle du bureau : le panneau, le filet
    // (l'accent pendant l'édition), l'image rognée au-dessus du texte,
    // l'épingle en haut à droite.
    component Card: Rectangle {
        id: card

        property var note
        property bool editing: false
        property bool hovered: false
        readonly property bool hasImage: (card.note.image || "") !== ""
        readonly property alias editor: editor

        // Le texte final, nettoyé, quand on quitte l'édition.
        signal finished(string text)

        width: slate.cardWidth
        height: body.height + 2 * slate.cardPadding
        radius: Theme.radius
        color: Theme.bgElevated
        border.width: 1
        border.color: card.editing ? Qt.alpha(Theme.accentColor, 0.5)
                    : Qt.alpha(Theme.textPrimary, card.hovered ? 0.16 : 0.08)
        clip: true

        // Ouvre l'édition, le curseur sous `at` (un point de l'éditeur), ou
        // à la fin.
        function edit(at) {
            editor.text = card.note.text || "";
            editor.forceActiveFocus();
            editor.cursorPosition = at ? editor.positionAt(at.x, at.y) : editor.length;
        }

        Column {
            id: body
            x: slate.cardPadding
            y: slate.cardPadding
            width: card.width - 2 * slate.cardPadding
            spacing: 10

            Image {
                visible: card.hasImage
                width: body.width
                height: card.hasImage
                        ? (status === Image.Ready && implicitWidth > 0
                           ? Math.min(300, width * implicitHeight / implicitWidth) : 120)
                        : 0
                source: card.hasImage ? "file://" + card.note.image : ""
                sourceSize.width: 600
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
            }

            Text {
                visible: !card.editing && (card.note.text || "") !== ""
                width: body.width
                // L'épingle reste en haut à droite : le texte ne passe pas dessous.
                rightPadding: card.note.pinned && !card.hasImage ? 20 : 0
                text: card.note.text || ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.family: "Inter"
                font.pixelSize: slate.fontSize
                lineHeight: 1.2
                color: Theme.textPrimary
            }

            TextEdit {
                id: editor
                visible: card.editing
                width: body.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                selectByMouse: true
                font.family: "Inter"
                font.pixelSize: slate.fontSize
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.accentColor, 0.4)

                // Quitté (clic ailleurs, Échap, Ctrl+Entrée) : rendu à qui
                // l'a ouvert, qui l'enregistre s'il a changé.
                onActiveFocusChanged: {
                    if (!activeFocus && card.editing)
                        card.finished(editor.text.trim());
                }
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape
                        || ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && (event.modifiers & Qt.ControlModifier))) {
                        root.forceActiveFocus();
                        event.accepted = true;
                    }
                }
            }
        }

        NixIcon {
            visible: card.note.pinned === true
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: slate.cardPadding - 2
            iconSize: 16
            source: "../assets/icons/pin.svg"
            color: Theme.accentColor
        }
    }
}
