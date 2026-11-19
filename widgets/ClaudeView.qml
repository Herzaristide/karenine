pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// La vue Claude du panneau de droite : les sessions Claude Code, par
// urgence. Celles qui attendent une réponse d'abord, entourées de l'accent,
// avec ce qu'elles demandent ; puis celles qui travaillent, et à quoi ;
// puis celles qui sont ouvertes sans rien faire ; enfin les dernières
// terminées, à reprendre. Un clic sur une session ouverte amène son
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

    readonly property var waiting: ClaudeSessions.live.filter(s => s.state === "waiting")
    readonly property var busy: ClaudeSessions.live.filter(s => s.state === "busy")
    readonly property var idle: ClaudeSessions.live.filter(s => s.state === "idle")

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

        Heading {
            visible: ClaudeSessions.recent.length > 0
            text: I18n.tr("claude.recent")
        }
        Repeater {
            model: ClaudeSessions.recent

            // Une session terminée, sur une ligne : son titre, son projet, sa
            // date ; un clic la reprend dans un terminal.
            Rectangle {
                id: recentRow
                required property var modelData
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
                        text: root.tick >= 0 ? root.ago(recentRow.modelData.updated) : ""
                        font.family: "Inter"
                        font.pixelSize: 11
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
                    onClicked: {
                        ClaudeSessions.resume(recentRow.modelData);
                        Widgets.panelOpen = false;
                    }
                }
            }
        }
    }
}
