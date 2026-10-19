pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "../services"

// L'onglet « Notes » : un mur de cartes, à la Keep, gardé sur ce PC
// seulement (anna/src/notes.rs, dans ~/.local/share/anna/notes). Une note
// s'écrit dans la barre : on la tape, puis « Créer une note » parmi les
// résultats (services/NoteSource.qml, qui y met aussi les notes trouvées).
// Ici, on colle du texte ou une image (une capture, une image copiée du
// navigateur ou de l'Explorer).
//
//   ╭──────────────────────────────────────────────────────────────╮
//   │ Ctrl+V : colle du texte ou une image               (Coller) │
//   │ ╭──────────╮ ╭──────────╮ ╭──────────╮ ╭──────────╮          │
//   │ │ texte  📌│ │  image   │ │ texte    │ │ texte    │  colonnes │
//   │ │          │ │          │ ╰──────────╯ │          │  qui      │
//   │ ╰──────────╯ │ légende  │ ╭──────────╮ ╰──────────╯  défilent │
//   │              ╰──────────╯ │ …        │                         │
//   ╰──────────────────────────────────────────────────────────────╯
//
// Chaque capture d'écran y arrive d'elle-même (le daemon la range,
// notes.rs::watch_screenshots).
//
// Ctrl+V, hors d'une carte en cours d'édition, fait une note du
// presse-papiers. Un clic sur une carte l'édite (Échap ou un clic ailleurs
// enregistre ; vider une note de texte la supprime). Au survol, en haut à
// droite, ses outils : épingler, la recopier dans le presse-papiers, l'ouvrir
// dans Claude Code (dans un terminal, la note pour premier message), la
// supprimer. Un double clic sur une image l'ouvre.
FocusScope {
    id: root

    // Les notes, triées par anna : épinglées d'abord, puis les plus récentes.
    property var notes: []
    property bool loaded: false
    // La note en cours d'édition.
    property string editingId: ""
    // Le retour de la dernière action (une erreur, « Copié »), effacé seul.
    property string feedback: ""

    readonly property int gap: 10
    readonly property int minCardW: 190
    readonly property int cols: Math.max(1, Math.floor((wall.width + root.gap) / (root.minCardW + root.gap)))
    readonly property real cardW: (wall.width - (root.cols - 1) * root.gap) / root.cols

    Component.onCompleted: root.act(["list"])

    // Une note ajoutée ailleurs (une capture d'écran, que le daemon range ici
    // lui-même) : la liste est relue.
    FileView {
        path: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share")
              + "/anna/notes/notes.json"
        watchChanges: true
        printErrors: false
        onFileChanged: root.act(["list"])
    }

    // ── Les actions ──────────────────────────────────────────────
    // Une à la fois, par anna ; les suivantes attendent. Chaque changement
    // relit la liste derrière lui.
    property var queue: []

    function act(args, done) {
        var q = root.queue.slice();
        q.push({ args: ["anna", "notes"].concat(args), done: done || "" });
        if (args[0] !== "list")
            q.push({ args: ["anna", "notes", "list"], done: "" });
        root.queue = q;
        root.next();
    }

    function next() {
        if (proc.running || root.queue.length === 0)
            return;
        var job = root.queue[0];
        root.queue = root.queue.slice(1);
        proc.done = job.done;
        proc.command = job.args;
        proc.running = true;
    }

    Process {
        id: proc
        property string done: ""
        stdout: StdioCollector { id: out }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(out.text);
                if (r.notes !== undefined) {
                    root.notes = r.notes;
                    root.loaded = true;
                } else {
                    root.say(r.ok ? proc.done : (r.error || I18n.tr("common.failedSentence")));
                }
            } catch (e) {
                root.say(I18n.tr("anna.noAnswer"));
            }
            root.next();
        }
    }

    function say(text) {
        root.feedback = text;
        if (text)
            feedbackTimer.restart();
    }

    Timer {
        id: feedbackTimer
        interval: 3500
        onTriggered: root.feedback = ""
    }

    // Une note confiée à Claude Code : `claude` dans le terminal du système,
    // depuis le dossier personnel (une note n'appartient à aucun dépôt), la
    // note pour premier message. Une image passe par son chemin, que Claude
    // Code lit.
    function openInClaude(note) {
        var prompt = note.image === "" ? note.text
                   : (note.text !== "" ? note.text + "\n\n" : "") + "Image : " + note.image;
        DefaultApps.runInTerminal(Quickshell.env("HOME"), ["claude", prompt]);
    }

    function paste() {
        root.act(["paste"]);
    }

    // Ctrl+V sur le mur : une note du presse-papiers.
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
            root.paste();
            event.accepted = true;
        }
    }

    // Un clic dans le vide reprend le clavier (et enregistre la note éditée).
    MouseArea {
        anchors.fill: parent
        onClicked: {
            root.editingId = "";
            root.forceActiveFocus();
        }
    }

    // ── En haut : coller ─────────────────────────────────────────
    // Une note s'écrit dans la barre (« Créer une note » parmi les
    // résultats, services/NoteSource.qml) ; ici, on colle.
    Item {
        id: field
        width: root.width
        height: 32

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.right: pasteBtn.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.feedback !== "" ? root.feedback : I18n.tr("memo.hint")
            font.family: "Inter"
            font.pixelSize: 11
            color: root.feedback !== "" ? Theme.textSecondary : Theme.textDim
            elide: Text.ElideRight
        }

        GlassButton {
            id: pasteBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 28
            fontSize: 11
            accent: true
            text: I18n.tr("memo.paste")
            onClicked: root.paste()
        }
    }

    // ── Le mur ───────────────────────────────────────────────────
    Flickable {
        id: wall
        anchors.top: field.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentHeight: columns.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Les cartes se rangent en colonnes, l'une après l'autre : la
        // première note en haut à gauche, la suivante à côté.
        Row {
            id: columns
            spacing: root.gap

            Repeater {
                model: root.cols

                Column {
                    id: column
                    required property int index
                    width: root.cardW
                    spacing: root.gap

                    Repeater {
                        model: root.notes.filter((n, i) => i % root.cols === column.index)
                        delegate: NoteCard { width: root.cardW }
                    }
                }
            }
        }
    }

    // Rien encore.
    Text {
        anchors.centerIn: wall
        width: Math.min(parent.width - 40, 520)
        visible: root.loaded && root.notes.length === 0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: I18n.tr("memo.none")
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }

    // ── Une carte ────────────────────────────────────────────────
    component NoteCard: Rectangle {
        id: card
        required property var modelData
        readonly property var note: card.modelData
        readonly property bool editing: root.editingId === card.note.id
        readonly property bool hasImage: card.note.image !== ""
        readonly property bool hovered: hover.hovered || card.editing

        height: body.height + 12
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, 0.05)
        border.width: 1
        border.color: card.editing ? Qt.alpha(Theme.glow(0), 0.5)
                    : Qt.alpha(Theme.textPrimary, card.hovered ? 0.16 : 0.08)
        clip: true

        HoverHandler { id: hover }

        // Un clic : l'édition (texte, ou légende de l'image).
        MouseArea {
            anchors.fill: parent
            cursorShape: card.editing ? Qt.IBeamCursor : Qt.PointingHandCursor
            onClicked: root.editingId = card.note.id
        }

        Column {
            id: body
            x: 6
            y: 6
            width: card.width - 12
            spacing: 6

            Image {
                id: picture
                visible: card.hasImage
                width: body.width
                height: card.hasImage
                        ? (status === Image.Ready && implicitWidth > 0
                           ? Math.min(260, width * implicitHeight / implicitWidth) : 90)
                        : 0
                source: card.hasImage ? "file://" + card.note.image : ""
                sourceSize.width: 600
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true

                // Un double clic l'ouvre dans la visionneuse.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.editingId = card.note.id
                    onDoubleClicked: Quickshell.execDetached(["xdg-open", card.note.image])
                }
            }

            // Le texte, lu ; ou édité.
            Text {
                visible: !card.editing && card.note.text !== ""
                x: 6
                width: body.width - 12
                topPadding: card.hasImage ? 0 : 6
                // L'épingle reste en haut à droite : le texte ne passe pas dessous.
                rightPadding: card.note.pinned && !card.hasImage ? 22 : 0
                text: card.note.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: 14
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 12
                lineHeight: 1.15
                color: Theme.textPrimary
            }

            TextEdit {
                id: editor
                visible: card.editing
                x: 6
                width: body.width - 12
                topPadding: card.hasImage ? 0 : 6
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                selectByMouse: true
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.glow(0), 0.4)

                Text {
                    visible: editor.text === "" && card.hasImage
                    text: I18n.tr("memo.caption")
                    font: editor.font
                    topPadding: editor.topPadding
                    color: Theme.textDim
                }

                // Ouvert : le texte de la note, le curseur à la fin.
                onVisibleChanged: {
                    if (visible) {
                        editor.text = card.note.text;
                        editor.cursorPosition = editor.length;
                        editor.forceActiveFocus();
                    }
                }
                // Quitté (clic ailleurs, Échap) : enregistré s'il a changé.
                onActiveFocusChanged: {
                    if (!activeFocus && editor.visible) {
                        if (editor.text !== card.note.text)
                            root.act(["edit", card.note.id, editor.text]);
                        if (root.editingId === card.note.id)
                            root.editingId = "";
                    }
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

        // ── Ses outils, en haut à droite, au survol ──────────────
        // Par-dessus la carte, sur une pastille : ils ne lui prennent pas de
        // place. Épinglée, l'épingle seule y reste.
        Rectangle {
            anchors.fill: tools
            anchors.margins: -2
            radius: Theme.radiusSmall
            color: Theme.bgElevated
            opacity: card.hovered ? tools.opacity : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }

        Row {
            id: tools
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.top: parent.top
            anchors.topMargin: 8
            height: 22
            spacing: 2
            opacity: card.hovered || card.note.pinned ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }

            ToolIcon {
                visible: card.hovered || card.note.pinned
                icon: "pin.svg"
                active: card.note.pinned
                onClicked: root.act(["pin", card.note.id])
            }
            ToolIcon {
                visible: card.hovered
                icon: "copy.svg"
                onClicked: root.act(["copy", card.note.id], I18n.tr("memo.copied"))
            }
            ToolIcon {
                visible: card.hovered
                icon: "terminal.svg"
                onClicked: root.openInClaude(card.note)
            }
            ToolIcon {
                visible: card.hovered
                icon: "trash.svg"
                danger: true
                onClicked: {
                    if (root.editingId === card.note.id)
                        root.editingId = "";
                    root.act(["delete", card.note.id]);
                }
            }
        }
    }

    // Un petit bouton rond, une icône de assets/icons dedans, teintée comme
    // celles des onglets : l'accent quand elle est active (une note
    // épinglée), le rouge au survol pour supprimer.
    component ToolIcon: Rectangle {
        id: tool
        property string icon: ""
        property bool active: false
        property bool danger: false
        signal clicked()

        width: 22
        height: 22
        radius: 6
        color: toolMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.12) : "transparent"

        Image {
            id: toolImg
            anchors.centerIn: parent
            width: 14
            height: 14
            source: "../assets/icons/" + tool.icon
            sourceSize.width: 42
            sourceSize.height: 42
            visible: false
        }
        MultiEffect {
            anchors.fill: toolImg
            source: toolImg
            colorization: 1.0
            colorizationColor: tool.danger && toolMa.containsMouse ? Theme.colorDanger
                             : tool.active ? Theme.glow(0.05)
                             : Theme.iconColor
            opacity: tool.active || toolMa.containsMouse ? 1 : 0.7
            Behavior on colorizationColor { ColorAnimation { duration: 160 } }
        }
        MouseArea {
            id: toolMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tool.clicked()
        }
    }
}
