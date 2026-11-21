pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// La vue Claude du panneau de droite : les sessions Claude Code, par
// urgence. Celles qui attendent une réponse d'abord, entourées de l'accent,
// avec ce qu'elles demandent ; puis celles qui travaillent, et à quoi ;
// puis celles qui sont ouvertes sans rien faire ; enfin les terminées, à
// reprendre : celles du jour, puis les autres regroupées par jour.
// En haut, de quoi filtrer : un champ (titre, projet, branche) et le projet. Un clic sur une session ouverte amène son
// terminal au premier plan : on y répond, le panneau n'écrit jamais dans
// une session.
//
//   ATTEND TA RÉPONSE                          1
//   ╭ ● Permission                    il y a 2 min ╮
//   │ gpoc  main                                    │
//   │ Ouverture de wan81_00001_.mp4 sur gary        │
//   │ ┊ Claude needs your permission to use Bash ┊  │
//   ╰───────────────────── (Aller au terminal) ────╯
Flickable {
    id: root

    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

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
    readonly property var waiting: root.live.filter(s => s.state === "waiting")
    readonly property var busy: root.live.filter(s => s.state === "busy")
    readonly property var idle: root.live.filter(s => s.state === "idle")
    readonly property var recent: ClaudeSessions.recent.filter(s => root.matches(s))

    // Les projets des sessions, le plus fréquent d'abord.
    readonly property var projects: {
        var n = {};
        ClaudeSessions.live.concat(ClaudeSessions.recent).forEach(s => {
            if (s.project !== "")
                n[s.project] = (n[s.project] || 0) + 1;
        });
        return Object.keys(n).sort((a, b) => n[b] - n[a] || a.localeCompare(b));
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
        root.recent.forEach(s => {
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
        signal clicked()
        implicitWidth: chipText.implicitWidth + 18
        implicitHeight: 24
        radius: 12
        color: chip.active ? Qt.alpha(Theme.accentColor, 0.18)
             : chipMa.containsMouse ? Theme.hoverOverlay : Qt.alpha(Theme.textPrimary, 0.06)
        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.Medium
            color: chip.active ? Theme.accentColor : Theme.textSecondary
        }
        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
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
            NixIcon {
                iconSize: 15
                source: "../assets/ui/reboot.svg"
                color: recentMa.containsMouse ? Theme.accentColor : Theme.textSecondary
            }
        }

        MouseArea {
            id: recentMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ClaudeSessions.resume(recentRow.modelData)
        }
    }

    // Une session ouverte : son état, son projet et sa branche, son titre,
    // ce qu'elle fait ou demande.
    component SessionCard: Rectangle {
        id: card
        required property var modelData
        readonly property bool isWaiting: card.modelData.state === "waiting"
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
            onClicked: ClaudeSessions.focus(card.modelData)
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
                visible: lineText.text !== ""
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

            RowLayout {
                Layout.fillWidth: true
                visible: card.isWaiting
                Text {
                    text: I18n.tr("claude.answerThere")
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: Theme.textSecondary
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    implicitWidth: goText.implicitWidth + 20
                    implicitHeight: 28
                    radius: Theme.radiusSmall
                    color: Theme.selectedFill
                    Text {
                        id: goText
                        anchors.centerIn: parent
                        text: I18n.tr("claude.goTerminal")
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                    }
                }
            }
        }
    }

    ColumnLayout {
        id: column
        width: root.width
        spacing: 8

        // Les filtres : le champ, puis les projets (dès qu'il y en a deux).
        Rectangle {
            visible: ClaudeSessions.live.length + ClaudeSessions.recent.length > 0
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

        Flow {
            visible: root.projects.length > 1
            Layout.fillWidth: true
            spacing: 4

            Chip {
                label: I18n.tr("claude.allProjects")
                active: root.project === ""
                onClicked: root.project = ""
            }
            Repeater {
                model: root.projects
                Chip {
                    id: projChip
                    required property string modelData
                    label: projChip.modelData
                    active: root.project === projChip.modelData
                    onClicked: root.project = root.project === projChip.modelData ? "" : projChip.modelData
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

        Heading {
            visible: root.waiting.length > 0
            text: I18n.tr("claude.waiting")
            count: root.waiting.length
        }
        Repeater {
            model: root.waiting
            SessionCard {}
        }

        Heading {
            visible: root.busy.length > 0
            text: I18n.tr("claude.working")
            count: root.busy.length
        }
        Repeater {
            model: root.busy
            SessionCard {}
        }

        Heading {
            visible: root.idle.length > 0
            text: I18n.tr("claude.open")
            count: root.idle.length
        }
        Repeater {
            model: root.idle
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
    }
}
