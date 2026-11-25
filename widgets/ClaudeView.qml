pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"

// La vue Claude du panneau de droite : les sessions Claude Code, par
// urgence. Celles qui attendent une réponse d'abord, entourées de l'accent,
// avec ce qu'elles demandent ; puis celles qui travaillent, et à quoi ;
// puis celles qui sont ouvertes sans rien faire ; enfin les terminées, à
// reprendre : regroupées par jour. Celles
// d'avant aujourd'hui sont masquées tant qu'on ne les demande pas.
// En haut, un champ pour chercher (titre, projet, branche), « + » pour une
// nouvelle session dans le panneau et ›_ pour une nouvelle dans un terminal ;
// puis les projets, sur une ligne qui défile : un clic n'affiche que les sessions de ce projet
// (et les nouvelles s'y ouvrent), un second les rend toutes.
//
// Un clic sur une session ouvre sa conversation (ClaudeConversation), à la
// place de la liste : on la lit, et on y écrit comme dans Claude Desktop.
// Le terminal d'une session ouverte reste à un clic (l'icône ›_), comme la
// reprise d'une terminée dans un terminal.
//
//   ATTEND TA RÉPONSE                          1
//   ╭ ● Permission                    il y a 2 min ╮
//   │ gpoc  main                                    │
//   │ Ouverture de wan81_00001_.mp4 sur gary        │
//   │ ┊ Claude needs your permission to use Bash ┊  │
//   ╰───────────────────── (Aller au terminal) ────╯
Item {
    id: tab

    ClaudeConversation {
        anchors.fill: parent
        visible: ClaudeChat.open
    }

    Flickable {
        id: root

        anchors.fill: parent
        visible: !ClaudeChat.open
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Une nouvelle session : le choix du projet est ouvert, pour la lancer
        // dans le panneau ("panel") ou dans un terminal ("terminal").
        property string picking: ""

        function start(where, project) {
            root.picking = "";
            if (where === "terminal")
                ClaudeSessions.startInTerminal(root.folders[project]);
            else
                ClaudeChat.newSession(root.folders[project], project);
        }

        // Le projet choisi s'il y en a un, sinon on le demande.
        function askStart(where) {
            if (root.project !== "" && root.folders[root.project] !== undefined)
                root.start(where, root.project);
            else
                root.picking = root.picking === where ? "" : where;
        }
        // Le dossier de chaque projet, d'après ses sessions.
        readonly property var folders: {
            var f = {};
            ClaudeSessions.live.concat(ClaudeSessions.recent).forEach(s => {
                if (s.project !== "" && s.cwd !== "" && f[s.project] === undefined)
                    f[s.project] = s.cwd;
            });
            return f;
        }

        // Les filtres : le projet choisi ("" : tous) et le texte cherché.
        property string project: ""
        property string query: ""

        function matches(s) {
            if (root.project !== "" && s.project !== root.project)
                return false;
            var q = root.query.trim().toLowerCase();
            if (q === "")
                return true;
            return (s.title + " " + s.project + " " + s.branch).toLowerCase().indexOf(q) >= 0;
        }

        readonly property var live: ClaudeSessions.live.filter(s => root.matches(s))
        readonly property var recent: ClaudeSessions.recent.filter(s => root.matches(s))
        // Les épinglées, tout en haut, même anciennes : les ouvertes (par
        // état), puis les terminées, la dernière épinglée d'abord.
        readonly property var pinnedLive: root.live.filter(s => ClaudeSessions.isPinned(s))
        readonly property var pinnedRecent: root.recent.filter(s => ClaudeSessions.isPinned(s))
            .sort((a, b) => ClaudeSessions.pins.indexOf(a.id) - ClaudeSessions.pins.indexOf(b.id))
        readonly property int pinnedCount: root.pinnedLive.length + root.pinnedRecent.length
        // Le reste, chacun à sa place.
        readonly property var unpinnedLive: root.live.filter(s => !ClaudeSessions.isPinned(s))
        readonly property var unpinnedRecent: root.recent.filter(s => !ClaudeSessions.isPinned(s))
        readonly property var waiting: root.unpinnedLive.filter(s => s.state === "waiting")
        readonly property var busy: root.unpinnedLive.filter(s => s.state === "busy")
        readonly property var idle: root.unpinnedLive.filter(s => s.state === "idle" && (root.showOld || !root.isOld(s)))

        // Sans activité aujourd'hui (depuis minuit) : masquée, sauf demande ou recherche.
        // Celles qui attendent ou travaillent se voient toujours.
        readonly property int dayMs: 86400000
        property bool older: false
        readonly property bool showOld: root.older || root.query.trim() !== ""
        function isOld(s) {
            return root.tick >= 0 && s.updated > 0 && s.updated < root.midnight(Date.now());
        }
        readonly property int oldCount: root.unpinnedRecent.filter(s => root.isOld(s)).length
            + root.unpinnedLive.filter(s => s.state === "idle" && root.isOld(s)).length

        // Les projets des sessions : [{ name, rank, updated, active }]. Ceux où
        // une session attend (0), puis ceux où une est ouverte (1), par nom ;
        // puis les autres (2), le dernier touché d'abord.
        readonly property var projectList: {
            var by = {};
            ClaudeSessions.live.concat(ClaudeSessions.recent).forEach(s => {
                if (s.project === "")
                    return;
                var p = by[s.project] || (by[s.project] = { name: s.project, rank: 2, updated: 0, active: false });
                p.active = p.active || s.state === "waiting" || s.state === "busy";
                p.updated = Math.max(p.updated, s.updated);
                p.rank = Math.min(p.rank, s.state === "waiting" ? 0 : s.state === "ended" ? 2 : 1);
            });
            return Object.values(by).sort((a, b) => a.rank - b.rank
                || (a.rank < 2 ? 0 : b.updated - a.updated)
                || a.name.localeCompare(b.name));
        }
        // Les dossiers jetables, où l'on n'ouvre rien de nouveau.
        function temporary(dir) {
            return dir === "/tmp" || dir.startsWith("/tmp/") || dir.indexOf("/.config/Claude/scratch-workspaces/") >= 0;
        }
        // Où ouvrir une nouvelle session.
        readonly property var targets: root.projectList.map(p => p.name)
            .filter(n => root.folders[n] !== undefined && !root.temporary(root.folders[n]))
        // Les vrais projets, actifs depuis une semaine (ou avec une session qui
        // attend ou travaille) : ni le dossier personnel, ni un dossier qui en
        // range plusieurs autres (~/code). Leurs sessions restent dans « Tous ».
        readonly property var projects: root.targets.filter(n => {
            var dir = root.folders[n];
            var info = root.projectList.find(p => p.name === n);
            if (root.tick >= 0 && !info.active && Date.now() - info.updated > 7 * root.dayMs)
                return false;
            return dir !== Quickshell.env("HOME")
                && root.targets.filter(o => root.folders[o].startsWith(dir + "/")).length < 2;
        })

        // Le projet choisi n'a plus de session : on ne reste pas sur une
        // liste vide.
        onProjectsChanged: {
            if (root.project !== "" && root.projects.indexOf(root.project) < 0)
                root.project = "";
        }

        function midnight(ms) {
            var d = new Date(ms);
            return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        }

        // Les terminées, par jour : [{ label, today, items }], le plus récent
        // d'abord. Celles du jour gardent leur « il y a », les autres leur heure.
        readonly property var days: {
            var today = root.tick >= 0 ? root.midnight(Date.now()) : 0;
            var out = [];
            root.unpinnedRecent.filter(s => root.showOld || !root.isOld(s)).forEach(s => {
                var day = root.midnight(s.updated);
                var g = out.length > 0 && out[out.length - 1].day === day ? out[out.length - 1] : null;
                if (!g) {
                    var d = new Date(day);
                    var n = Math.round((today - day) / 86400000);
                    var label = n <= 0 ? I18n.tr("claude.today")
                              : n === 1 ? I18n.tr("claude.yesterday")
                              : I18n.locale.toString(d, d.getFullYear() === new Date().getFullYear()
                                                        ? "dddd d MMMM" : "dddd d MMMM yyyy");
                    g = { day: day, label: label, today: n <= 0, items: [] };
                    out.push(g);
                }
                g.items.push(s);
            });
            return out;
        }

        // « il y a 2 min », « il y a 3 h », « hier » ; rien sans date.
        function ago(ms) {
            if (!ms)
                return "";
            var s = Math.max(0, (Date.now() - ms) / 1000);
            if (s < 60)
                return I18n.tr("claude.now");
            if (s < 3600)
                return I18n.tr("claude.ago", { time: I18n.tr("time.minutes", { n: Math.round(s / 60) }) });
            if (s < 86400)
                return I18n.tr("claude.ago", { time: I18n.tr("time.hours", { n: Math.round(s / 3600) }) });
            return I18n.locale.toString(new Date(ms), "d MMM");
        }

        // L'heure avance : les « il y a » se recalculent.
        property int tick: 0
        Timer {
            interval: 30000
            running: root.visible
            repeat: true
            onTriggered: root.tick++
        }

        component Heading: RowLayout {
            id: heading
            property string text
            property int count: -1
            Layout.fillWidth: true
            Layout.topMargin: 6
            Text {
                text: heading.text
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
                color: Theme.textDim
            }
            Item { Layout.fillWidth: true }
            Text {
                visible: heading.count >= 0
                text: heading.count
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textDim
            }
        }

        // Une pastille de filtre.
        component Chip: Rectangle {
            id: chip
            property string label
            property bool active: false
            // Un point : une session y attend (0) ou y est ouverte (1).
            property int rank: 2
            signal clicked()
            implicitWidth: chipRow.implicitWidth + 18
            implicitHeight: 24
            radius: 12
            color: chip.active ? Qt.alpha(Theme.accentColor, 0.18)
                 : chipMa.containsMouse ? Theme.hoverOverlay : Qt.alpha(Theme.textPrimary, 0.06)
            Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: 6
                Rectangle {
                    visible: chip.rank < 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6
                    height: 6
                    radius: 3
                    color: chip.rank === 0 ? Theme.accentColor : Theme.colorCyan
                }
                Text {
                    text: chip.label
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    color: chip.active ? Theme.accentColor : Theme.textSecondary
                }
            }
            MouseArea {
                id: chipMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: chip.clicked()
            }
        }

        // Épingler une session (ou la désépingler) : visible au survol, ou
        // toujours, plein, une fois épinglée.
        component PinButton: Rectangle {
            id: pinBtn
            property var session
            // La ligne ou la carte est survolée.
            property bool shown: false
            readonly property bool pinned: ClaudeSessions.isPinned(pinBtn.session)
            readonly property bool hovered: pinMa.containsMouse
            implicitWidth: 24
            implicitHeight: 24
            radius: Theme.radiusSmall
            opacity: pinBtn.pinned || pinBtn.shown || pinBtn.hovered ? 1 : 0
            color: pinBtn.hovered ? Theme.selectedFill : "transparent"
            NixIcon {
                anchors.centerIn: parent
                iconSize: 14
                source: pinBtn.pinned ? "../assets/icons/pin-fill.svg" : "../assets/icons/pin.svg"
                color: pinBtn.pinned || pinBtn.hovered ? Theme.accentColor : Theme.textSecondary
            }
            MouseArea {
                id: pinMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ClaudeSessions.togglePin(pinBtn.session)
            }
        }

        // Une session terminée, sur une ligne : son titre, son projet, sa date
        // (« il y a 2 h » le jour même, l'heure sinon) ; un clic la reprend
        // dans un terminal.
        component RecentRow: Rectangle {
            id: recentRow
            required property var modelData
            property bool sameDay: true
            Layout.fillWidth: true
            implicitHeight: 38
            radius: Theme.radiusSmall
            color: recentMa.containsMouse ? Theme.hoverOverlay : "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 6
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: recentRow.modelData.title
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 13
                    color: Theme.textPrimary
                }
                Rectangle {
                    visible: root.project === ""
                    implicitWidth: projText.implicitWidth + 12
                    implicitHeight: 18
                    radius: 5
                    color: Theme.hoverOverlay
                    Text {
                        id: projText
                        anchors.centerIn: parent
                        text: recentRow.modelData.project
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                        color: Theme.textSecondary
                    }
                }
                Text {
                    text: root.tick < 0 ? ""
                        : recentRow.sameDay ? root.ago(recentRow.modelData.updated)
                        : I18n.locale.toString(new Date(recentRow.modelData.updated), "HH:mm")
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: Theme.textDim
                }
                // La place de l'épingle (posée par-dessus, plus bas).
                Item {
                    implicitWidth: 24
                    implicitHeight: 24
                }
                // La reprendre dans un terminal plutôt qu'ici.
                Rectangle {
                    implicitWidth: 24
                    implicitHeight: 24
                    radius: Theme.radiusSmall
                    color: termMa.containsMouse ? Theme.selectedFill : Theme.hoverOverlay
                    NixIcon {
                        anchors.centerIn: parent
                        iconSize: 14
                        source: "../assets/icons/terminal.svg"
                        color: termMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                    }
                }
            }

            MouseArea {
                id: recentMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ClaudeChat.openSession(recentRow.modelData)
            }
            // Au-dessus de la ligne : le bouton du terminal.
            MouseArea {
                id: termMa
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: 24
                height: 24
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ClaudeSessions.resume(recentRow.modelData)
            }
            PinButton {
                anchors.right: parent.right
                anchors.rightMargin: 6 + 24 + 8
                anchors.verticalCenter: parent.verticalCenter
                session: recentRow.modelData
                shown: recentMa.containsMouse || termMa.containsMouse
            }
        }

        // Une session ouverte : son état, son projet et sa branche, son titre,
        // ce qu'elle fait ou demande.
        component SessionCard: Rectangle {
            id: card
            required property var modelData
            readonly property bool isWaiting: card.modelData.state === "waiting"
            // Ce qu'on peut valider d'ici : les demandes d'une session du panneau.
            readonly property var asks: ClaudeSessions.asksOf(card.modelData)
            readonly property bool isBusy: card.modelData.state === "busy"

            Layout.fillWidth: true
            implicitHeight: cardCol.implicitHeight + 24
            radius: Theme.radius
            color: cardMa.containsMouse ? Qt.lighter(Theme.bgElevated, Theme.darkMode ? 1.12 : 0.98) : Theme.bgElevated
            border.width: card.isWaiting ? 1 : 0
            border.color: Qt.alpha(Theme.accentColor, 0.55)
            Behavior on color { ColorAnimation { duration: 140 } }

            MouseArea {
                id: cardMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ClaudeChat.openSession(card.modelData)
            }

            ColumnLayout {
                id: cardCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 7

                    Rectangle {
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 4
                        color: card.isWaiting ? Theme.accentColor : card.isBusy ? Theme.colorCyan : Theme.textDim
                        SequentialAnimation on opacity {
                            running: card.isWaiting && card.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
                        }
                    }
                    Text {
                        text: card.isWaiting ? I18n.tr("claude.waitingShort")
                            : card.isBusy ? I18n.tr("claude.busy") : I18n.tr("claude.idle")
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: card.isWaiting ? Theme.accentColor : card.isBusy ? Theme.colorCyan : Theme.textSecondary
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.tick >= 0 ? root.ago(card.modelData.updated) : ""
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textDim
                    }
                    PinButton {
                        implicitWidth: 22
                        implicitHeight: 22
                        session: card.modelData
                        shown: cardMa.containsMouse || cardTermMa.containsMouse
                    }
                    // Son terminal, au premier plan.
                    Rectangle {
                        visible: !card.modelData.driven
                        implicitWidth: 22
                        implicitHeight: 22
                        radius: Theme.radiusSmall
                        color: cardTermMa.containsMouse ? Theme.selectedFill : Theme.hoverOverlay
                        NixIcon {
                            anchors.centerIn: parent
                            iconSize: 13
                            source: "../assets/icons/terminal.svg"
                            color: cardTermMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                        }
                        MouseArea {
                            id: cardTermMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ClaudeSessions.focus(card.modelData)
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: card.modelData.project
                        font.family: "Inter"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        color: Theme.textPrimary
                    }
                    Rectangle {
                        visible: card.modelData.branch !== ""
                        Layout.maximumWidth: cardCol.width * 0.6
                        implicitWidth: branchText.implicitWidth + 12
                        implicitHeight: 18
                        radius: 5
                        color: Theme.hoverOverlay
                        Text {
                            id: branchText
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, parent.width - 12)
                            elide: Text.ElideMiddle
                            text: card.modelData.branch
                            font.family: "JetBrains Mono"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                        }
                    }
                    Item { Layout.fillWidth: true }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: card.modelData.title
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 13
                    color: Theme.textSecondary
                }

                // Ce qu'elle demande, ou ce qu'elle fait.
                Rectangle {
                    Layout.fillWidth: true
                    visible: lineText.text !== "" && card.asks.length === 0
                    implicitHeight: lineText.implicitHeight + 12
                    radius: Theme.radiusSmall
                    color: Theme.bgDeep
                    Text {
                        id: lineText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 9
                        anchors.rightMargin: 9
                        text: card.isWaiting ? card.modelData.ask : card.modelData.activity
                        elide: Text.ElideRight
                        font.family: card.isWaiting ? "Inter" : "JetBrains Mono"
                        font.pixelSize: card.isWaiting ? 12 : 11
                        color: card.isWaiting ? Theme.textPrimary : Theme.colorCyan
                    }
                }

                // Sa plus ancienne demande, à valider sans ouvrir la session.
                Repeater {
                    model: ScriptModel {
                        objectProp: "id"
                        values: card.asks.slice(0, 1)
                    }
                    ClaudeAsk {
                        required property var modelData
                        Layout.fillWidth: true
                        flat: true
                        request: modelData
                        count: card.asks.length
                        onAnswered: (action, values) => ClaudeSessions.answer(card.modelData, modelData.id, action, values)
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: card.isWaiting && card.asks.length === 0
                    Text {
                        Layout.fillWidth: true
                        text: card.modelData.driven ? I18n.tr("claude.chat.answerCard") : I18n.tr("claude.answerThere")
                        elide: Text.ElideRight
                        font.family: "Inter"
                        font.pixelSize: 12
                        color: Theme.textSecondary
                    }
                    Rectangle {
                        visible: !card.modelData.driven
                        implicitWidth: goText.implicitWidth + 20
                        implicitHeight: 28
                        radius: Theme.radiusSmall
                        color: goMa.containsMouse ? Qt.alpha(Theme.accentColor, 0.24) : Theme.selectedFill
                        Text {
                            id: goText
                            anchors.centerIn: parent
                            text: I18n.tr("claude.goTerminal")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                        }
                        MouseArea {
                            id: goMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ClaudeSessions.focus(card.modelData)
                        }
                    }
                }
            }
        }

        ColumnLayout {
            id: column
            width: root.width
            spacing: 8

            // Le champ ; à côté, « + » et ›_ pour une nouvelle session.
            RowLayout {
                visible: ClaudeSessions.live.length + ClaudeSessions.recent.length > 0
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 32
                    radius: Theme.radiusSmall
                    color: Theme.bgElevated
                    border.width: search.activeFocus ? 1 : 0
                    border.color: Qt.alpha(Theme.accentColor, 0.6)

                    TextInput {
                        id: search
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: clear.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true
                        font.family: "Inter"
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                        onTextChanged: root.query = search.text
                        Keys.onEscapePressed: (event) => {
                            if (search.text !== "")
                                search.text = "";
                            else
                                event.accepted = false;
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text.length === 0
                            text: I18n.tr("claude.search")
                            font: search.font
                            color: Theme.textDim
                        }
                    }
                    Text {
                        id: clear
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text !== ""
                        text: "×"
                        font.pixelSize: 14
                        color: clearMa.containsMouse ? Theme.textPrimary : Theme.textDim
                        MouseArea {
                            id: clearMa
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: search.text = ""
                        }
                    }
                }

                Rectangle {
                    implicitWidth: 32
                    implicitHeight: 32
                    radius: Theme.radiusSmall
                    color: root.picking === "panel" ? Theme.selectedFill : newMa.containsMouse ? Theme.hoverOverlay : Theme.bgElevated
                    Text {
                        anchors.centerIn: parent
                        text: root.picking === "panel" ? "×" : "+"
                        font.family: "Inter"
                        font.pixelSize: 18
                        color: root.picking === "panel" ? Theme.accentColor : Theme.textSecondary
                    }
                    MouseArea {
                        id: newMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.askStart("panel")
                    }
                }

                // Une nouvelle session, dans un terminal.
                Rectangle {
                    implicitWidth: 32
                    implicitHeight: 32
                    radius: Theme.radiusSmall
                    color: root.picking === "terminal" ? Theme.selectedFill : newTermMa.containsMouse ? Theme.hoverOverlay : Theme.bgElevated
                    NixIcon {
                        anchors.centerIn: parent
                        iconSize: 16
                        source: "../assets/icons/terminal.svg"
                        color: root.picking === "terminal" ? Theme.accentColor : Theme.textSecondary
                    }
                    MouseArea {
                        id: newTermMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.askStart("terminal")
                    }
                }
            }

            // Nouvelle session : dans quel projet ?
            Heading {
                visible: root.picking !== ""
                text: root.picking === "terminal" ? I18n.tr("claude.newInTerminal") : I18n.tr("claude.chat.newIn")
            }
            Flow {
                visible: root.picking !== ""
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: root.picking !== "" ? root.targets : []
                    Chip {
                        id: newChip
                        required property string modelData
                        label: newChip.modelData
                        onClicked: root.start(root.picking, newChip.modelData)
                    }
                }
            }

            // Les projets (dès qu'il y en a deux), sur une ligne ; la molette
            // la fait défiler quand elle dépasse.
            ListView {
                id: projectBar
                visible: root.projects.length > 1
                Layout.fillWidth: true
                implicitHeight: 24
                orientation: ListView.Horizontal
                spacing: 4
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                // Suivis par leur nom : la ligne reste en place quand une
                // session avance. "" : tous.
                model: ScriptModel { values: [""].concat(root.projects) }
                delegate: Chip {
                    id: projChip
                    required property string modelData
                    required property int index
                    readonly property var info: root.projectList.find(p => p.name === projChip.modelData)
                    label: projChip.modelData === "" ? I18n.tr("claude.allProjects") : projChip.modelData
                    rank: projChip.info ? projChip.info.rank : 2
                    active: root.project === projChip.modelData
                    onClicked: {
                        root.project = projChip.active ? "" : projChip.modelData;
                        projectBar.positionViewAtIndex(projChip.index, ListView.Contain);
                    }
                }

                WheelHandler {
                    enabled: projectBar.contentWidth > projectBar.width
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    orientation: Qt.Vertical
                    onWheel: (event) => {
                        var max = projectBar.originX + projectBar.contentWidth - projectBar.width;
                        projectBar.contentX = Math.max(projectBar.originX,
                            Math.min(max, projectBar.contentX - event.angleDelta.y / 2));
                    }
                }
            }

            // Rien d'ouvert, rien de récent.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: 40
                visible: ClaudeSessions.loaded && ClaudeSessions.live.length === 0 && ClaudeSessions.recent.length === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: I18n.tr("claude.empty")
                font.family: "Inter"
                font.pixelSize: 13
                color: Theme.textSecondary
            }
            // Des sessions, mais aucune pour ces filtres.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: 24
                visible: ClaudeSessions.live.length + ClaudeSessions.recent.length > 0
                         && root.live.length === 0 && root.recent.length === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: I18n.tr("claude.noMatch")
                font.family: "Inter"
                font.pixelSize: 13
                color: Theme.textSecondary
            }

            // Les épinglées, avant tout le reste.
            Heading {
                visible: root.pinnedCount > 0
                text: I18n.tr("claude.pinned")
                count: root.pinnedCount
            }
            Repeater {
                model: ScriptModel { objectProp: "id"; values: root.pinnedLive }
                SessionCard {}
            }
            ColumnLayout {
                visible: root.pinnedRecent.length > 0
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                    model: ScriptModel { objectProp: "id"; values: root.pinnedRecent }
                    // « il y a 2 h », ou sa date (« 3 nov ») passé un jour.
                    RecentRow {}
                }
            }

            Heading {
                visible: root.waiting.length > 0
                text: I18n.tr("claude.waiting")
                count: root.waiting.length
            }
            Repeater {
                model: ScriptModel { objectProp: "id"; values: root.waiting }
                SessionCard {}
            }

            Heading {
                visible: root.busy.length > 0
                text: I18n.tr("claude.working")
                count: root.busy.length
            }
            Repeater {
                model: ScriptModel { objectProp: "id"; values: root.busy }
                SessionCard {}
            }

            Heading {
                visible: root.idle.length > 0
                text: I18n.tr("claude.open")
                count: root.idle.length
            }
            Repeater {
                model: ScriptModel { objectProp: "id"; values: root.idle }
                SessionCard {}
            }

            // Les terminées, un groupe par jour.
            Repeater {
                model: root.days

                ColumnLayout {
                    id: dayGroup
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2

                    Heading {
                        text: dayGroup.modelData.label
                        count: dayGroup.modelData.items.length
                    }
                    Repeater {
                        model: dayGroup.modelData.items
                        RecentRow {
                            sameDay: dayGroup.modelData.today
                        }
                    }
                }
            }

            // Les plus anciennes, sur demande (une recherche les montre déjà).
            Text {
                visible: root.oldCount > 0 && root.query.trim() === ""
                Layout.leftMargin: 10
                Layout.topMargin: 6
                Layout.bottomMargin: 6
                text: root.older ? I18n.tr("claude.hideOlder") : I18n.tr("claude.showOlder", { n: root.oldCount })
                font.family: "Inter"
                font.pixelSize: 12
                color: olderMa.containsMouse ? Theme.accentColor : Theme.textDim
                MouseArea {
                    id: olderMa
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.older = !root.older
                }
            }
        }
    }
}
