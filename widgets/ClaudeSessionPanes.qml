pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Les volets d'une session Claude Code, à côté de sa conversation
// (ClaudeConversation) — ce que Claude Desktop montre sur le côté — tirés de
// ClaudeChat.summary (anna/src/claude/summary.rs) :
//
//   changes  chaque fichier modifié ou créé, +/− ; un clic déplie son diff ;
//   outputs  ce qu’elle a produit à regarder ou réutiliser : médias, documents,
//            artifacts publiés (anna/src/claude/outputs.rs) ; un clic ouvre ;
//   jobs     la liste de tâches de Claude, puis ses sous-agents, commandes de
//            fond et tâches qui se rapportent : leur état, ce qu'ils ont
//            rendu ; un sous-agent s'ouvre comme une conversation.
//
// Le contexte, l'usage du forfait et le coût sont dans le popup de l'anneau,
// sous le champ (ClaudeConversation).
Flickable {
    id: root

    property string pane: "changes"

    readonly property var sum: ClaudeChat.summary
    readonly property string mono: "JetBrains Mono"

    contentHeight: column.implicitHeight + 8
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    // « 12,3 k », « 1,2 M ».
    function tokens(n) {
        if (n >= 1000000)
            return (n / 1000000).toLocaleString(I18n.locale, "f", 2) + " M";
        if (n >= 1000)
            return (n / 1000).toLocaleString(I18n.locale, "f", 1) + " k";
        return String(n);
    }

    function size(n) {
        if (n >= 1048576)
            return (n / 1048576).toLocaleString(I18n.locale, "f", 1) + " Mo";
        if (n >= 1024)
            return Math.round(n / 1024) + " ko";
        return n + " o";
    }

    function duration(ms) {
        var s = Math.round(ms / 1000);
        return s >= 60 ? Math.floor(s / 60) + " min " + (s % 60) + " s" : s + " s";
    }

    function base(path) {
        return path.substring(path.lastIndexOf("/") + 1);
    }

    function folder(path) {
        var i = path.lastIndexOf("/");
        return i > 0 ? path.substring(0, i) : "";
    }

    function statusColor(st) {
        return st === "running" ? Theme.colorCyan
             : st === "failed" || st === "killed" ? Theme.colorDanger
             : st === "completed" ? Theme.colorSuccess : Theme.textDim;
    }

    function statusText(st) {
        switch (st) {
        case "running": return I18n.tr("claude.pane.statusRunning");
        case "completed": return I18n.tr("claude.pane.statusCompleted");
        case "failed": return I18n.tr("claude.pane.statusFailed");
        case "killed":
        case "stopped": return I18n.tr("claude.pane.statusStopped");
        default: return st;
        }
    }

    function kindText(kind) {
        switch (kind) {
        case "agent": return I18n.tr("claude.pane.kindAgent");
        case "background": return I18n.tr("claude.pane.kindBackground");
        default: return I18n.tr("claude.pane.kindTask");
        }
    }

    component Heading: RowLayout {
        id: heading
        property string text
        property string count: ""
        Layout.fillWidth: true
        Layout.topMargin: 8
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
            text: heading.count
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textDim
        }
    }

    component Empty: Text {
        Layout.fillWidth: true
        Layout.topMargin: 30
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        font.family: "Inter"
        font.pixelSize: 13
        color: Theme.textSecondary
    }

    // Un diff : les morceaux `structuredPatch`.
    component Diff: Column {
        id: diffView
        property var hunks: []
        spacing: 0
        Repeater {
            model: diffView.hunks.slice(0, 60)
            Column {
                id: hunk
                required property var modelData
                required property int index
                width: diffView.width
                Text {
                    visible: hunk.index > 0
                    text: "…"
                    font.family: root.mono
                    font.pixelSize: 11
                    color: Theme.textDim
                }
                Repeater {
                    model: (hunk.modelData.lines || []).slice(0, 300)
                    Text {
                        required property string modelData
                        width: diffView.width
                        text: modelData
                        wrapMode: Text.WrapAnywhere
                        font.family: root.mono
                        font.pixelSize: 11
                        color: modelData.charAt(0) === "+" ? Theme.colorSuccess
                             : modelData.charAt(0) === "-" ? Theme.colorDanger : Theme.textDim
                    }
                }
            }
        }
    }

    ColumnLayout {
        id: column
        width: root.width
        spacing: 6

        // ── Les changements ──────────────────────────────────────────
        ColumnLayout {
            visible: root.pane === "changes"
            Layout.fillWidth: true
            spacing: 4

            Empty {
                visible: root.sum.changes.length === 0
                text: I18n.tr("claude.pane.noChanges")
            }
            RowLayout {
                visible: root.sum.changes.length > 0
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: I18n.tr("claude.pane.filesChanged", { n: root.sum.changes.length })
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: Theme.textSecondary
                }
                Text {
                    text: "+" + root.sum.changes.reduce((a, c) => a + c.added, 0)
                    font.family: root.mono
                    font.pixelSize: 11
                    color: Theme.colorSuccess
                }
                Text {
                    text: "−" + root.sum.changes.reduce((a, c) => a + c.removed, 0)
                    font.family: root.mono
                    font.pixelSize: 11
                    color: Theme.colorDanger
                }
            }

            Repeater {
                model: root.sum.changes
                Column {
                    id: change
                    required property var modelData
                    property bool expanded: false
                    property var hunks: []
                    Layout.fillWidth: true
                    spacing: 4

                    Rectangle {
                        width: change.width
                        height: 30
                        radius: Theme.radiusSmall
                        color: changeMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            spacing: 6
                            Text {
                                text: change.expanded ? "▾" : "▸"
                                font.pixelSize: 10
                                color: Theme.textDim
                            }
                            Text {
                                text: root.base(change.modelData.path)
                                font.family: root.mono
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: Theme.textPrimary
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.folder(change.modelData.path)
                                elide: Text.ElideLeft
                                font.family: root.mono
                                font.pixelSize: 10
                                color: Theme.textDim
                            }
                            Rectangle {
                                visible: change.modelData.created
                                implicitWidth: newText.implicitWidth + 10
                                implicitHeight: 16
                                radius: 4
                                color: Qt.alpha(Theme.colorSuccess, 0.16)
                                Text {
                                    id: newText
                                    anchors.centerIn: parent
                                    text: I18n.tr("claude.pane.new")
                                    font.family: "Inter"
                                    font.pixelSize: 9
                                    color: Theme.colorSuccess
                                }
                            }
                            Text {
                                text: "+" + change.modelData.added
                                font.family: root.mono
                                font.pixelSize: 11
                                color: Theme.colorSuccess
                            }
                            Text {
                                text: "−" + change.modelData.removed
                                font.family: root.mono
                                font.pixelSize: 11
                                color: Theme.colorDanger
                            }
                        }
                        MouseArea {
                            id: changeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                change.expanded = !change.expanded;
                                if (change.expanded)
                                    ClaudeChat.diff(change.modelData.path, (h) => change.hunks = h);
                            }
                        }
                    }

                    Rectangle {
                        visible: change.expanded
                        width: change.width
                        height: diffCol.implicitHeight + 16
                        radius: Theme.radiusSmall
                        color: Theme.bgDeep
                        Column {
                            id: diffCol
                            x: 10
                            y: 8
                            width: parent.width - 20
                            spacing: 6
                            Diff {
                                width: parent.width
                                hunks: change.expanded ? change.hunks : []
                            }
                            Text {
                                text: I18n.tr("claude.pane.openFile")
                                font.family: "Inter"
                                font.pixelSize: 11
                                color: openMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                                MouseArea {
                                    id: openMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ClaudeChat.openPath(change.modelData.path)
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Les sorties : des tuiles qui vont à la ligne ─────────────
        //   ╭────────╮ ╭────────╮ ╭────────╮
        //   │ aperçu │ │   ▤    │ │   🌐   │
        //   │ nom.png│ │ doc.pdf│ │ Article│
        //   │ 2,1 Mo │ │ 80 ko  │ │ publié │
        //   ╰────────╯ ╰────────╯ ╰────────╯
        ColumnLayout {
            visible: root.pane === "outputs"
            Layout.fillWidth: true
            spacing: 6

            Empty {
                visible: root.sum.outputs.length === 0
                text: I18n.tr("claude.pane.noOutputs")
            }
            Flow {
                id: outFlow
                Layout.fillWidth: true
                spacing: 8
                // Autant de colonnes que la largeur en tient (au moins 120 px).
                readonly property int columns: Math.max(1, Math.floor((outFlow.width + spacing) / (120 + spacing)))
                readonly property real tileW: (outFlow.width - (columns - 1) * spacing) / columns
                Repeater {
                    model: root.sum.outputs
                    Rectangle {
                        id: out
                        required property var modelData
                        readonly property bool artifact: out.modelData.url !== ""
                        readonly property bool image: /\.(png|jpe?g|webp|gif|svg|bmp)$/i.test(out.modelData.path)
                        width: outFlow.tileW
                        height: outCol.implicitHeight + 12
                        radius: Theme.radiusSmall
                        color: outMa.containsMouse ? Theme.hoverOverlay : Theme.bgElevated
                        opacity: out.modelData.exists || out.artifact ? 1 : 0.5

                        FontMetrics {
                            id: nameMetrics
                            font.family: "Inter"
                            font.pixelSize: 12
                        }
                        Column {
                            id: outCol
                            x: 6
                            y: 6
                            width: parent.width - 12
                            spacing: 6
                            // L'aperçu d'une image, sinon son icône.
                            Rectangle {
                                width: parent.width
                                height: Math.round(width * 0.66)
                                radius: 6
                                color: Theme.bgDeep
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    visible: out.image && out.modelData.exists
                                    source: visible ? "file://" + encodeURI(out.modelData.path).replace(/#/g, "%23").replace(/\?/g, "%3F") : ""
                                    sourceSize.width: 320
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                                NixIcon {
                                    anchors.centerIn: parent
                                    visible: !(out.image && out.modelData.exists)
                                    iconSize: 22
                                    source: out.artifact ? "../assets/icons/public.svg" : "../assets/icons/file.svg"
                                    color: Theme.textSecondary
                                }
                            }
                            Text {
                                width: parent.width
                                // Un nom de fichier se coupe après - _ . plutôt qu'au hasard.
                                text: (out.artifact ? out.modelData.title || I18n.tr("claude.pane.artifact") : root.base(out.modelData.path))
                                    .replace(/([-_.])/g, "$1\u200b")
                                textFormat: Text.PlainText
                                // Deux lignes réservées : les tuiles d'un rang s'alignent.
                                height: Math.ceil(nameMetrics.lineSpacing * 2) + 1
                                verticalAlignment: Text.AlignTop
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: Theme.textPrimary
                            }
                            RowLayout {
                                width: parent.width
                                spacing: 4
                                Text {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 22
                                    verticalAlignment: Text.AlignVCenter
                                    text: out.artifact ? I18n.tr("claude.pane.artifact")
                                        : out.modelData.exists ? root.size(out.modelData.size) : I18n.tr("claude.pane.gone")
                                    elide: Text.ElideRight
                                    font.family: "Inter"
                                    font.pixelSize: 10
                                    color: Theme.textDim
                                }
                                // Son dossier.
                                Rectangle {
                                    visible: !out.artifact
                                    implicitWidth: 22
                                    implicitHeight: 22
                                    radius: Theme.radiusSmall
                                    color: dirMa.containsMouse ? Theme.selectedFill : "transparent"
                                    NixIcon {
                                        anchors.centerIn: parent
                                        iconSize: 13
                                        source: "../assets/icons/folder.svg"
                                        color: dirMa.containsMouse ? Theme.accentColor : Theme.textDim
                                    }
                                    MouseArea {
                                        id: dirMa
                                        anchors.fill: parent
                                        z: 1
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: ClaudeChat.openFolder(out.modelData.path)
                                    }
                                }
                            }
                        }
                        MouseArea {
                            id: outMa
                            anchors.fill: parent
                            z: -1
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (out.artifact)
                                    Qt.openUrlExternally(out.modelData.url);
                                else if (out.modelData.exists)
                                    ClaudeChat.openPath(out.modelData.path);
                            }
                        }
                    }
                }
            }
        }

        // ── Les tâches ───────────────────────────────────────────────
        ColumnLayout {
            visible: root.pane === "jobs"
            Layout.fillWidth: true
            spacing: 6

            Empty {
                visible: root.sum.jobs.length === 0 && root.sum.todos.length === 0
                text: I18n.tr("claude.pane.noJobs")
            }

            // La liste de tâches de Claude.
            Heading {
                visible: root.sum.todos.length > 0
                text: I18n.tr("claude.pane.todos")
                count: root.sum.todos.filter(t => t.status === "completed").length + " / " + root.sum.todos.length
            }
            Repeater {
                model: root.sum.todos
                RowLayout {
                    id: todo
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: todo.modelData.status === "completed" ? "☑" : todo.modelData.status === "in_progress" ? "◐" : "☐"
                        font.pixelSize: 13
                        color: todo.modelData.status === "completed" ? Theme.colorSuccess
                             : todo.modelData.status === "in_progress" ? Theme.colorCyan : Theme.textDim
                    }
                    Text {
                        Layout.fillWidth: true
                        text: todo.modelData.subject
                        wrapMode: Text.Wrap
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.strikeout: todo.modelData.status === "completed"
                        color: todo.modelData.status === "completed" ? Theme.textDim : Theme.textPrimary
                    }
                }
            }

            // Les sous-agents, commandes de fond et tâches.
            Heading {
                visible: root.sum.jobs.length > 0
                text: I18n.tr("claude.pane.jobs")
                count: root.sum.jobs.filter(j => j.status === "running").length > 0
                       ? I18n.tr("claude.pane.running", { n: root.sum.jobs.filter(j => j.status === "running").length })
                       : String(root.sum.jobs.length)
            }
            Repeater {
                model: root.sum.jobs
                Rectangle {
                    id: job
                    required property var modelData
                    property bool expanded: false
                    property string output: ""
                    readonly property bool running: job.modelData.status === "running"
                    Layout.fillWidth: true
                    implicitHeight: jobCol.implicitHeight + 20
                    radius: Theme.radius
                    color: Theme.bgElevated
                    border.width: job.running ? 1 : 0
                    border.color: Qt.alpha(Theme.colorCyan, 0.4)

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: job.expanded = !job.expanded
                    }

                    ColumnLayout {
                        id: jobCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 10
                        spacing: 5

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 7
                            Rectangle {
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: root.statusColor(job.modelData.status)
                                SequentialAnimation on opacity {
                                    running: job.running && job.visible
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.35; duration: 800 }
                                    NumberAnimation { to: 1; duration: 800 }
                                }
                            }
                            Text {
                                text: root.kindText(job.modelData.kind)
                                font.family: "Inter"
                                font.pixelSize: 11
                                font.weight: Font.Medium
                                color: Theme.textSecondary
                            }
                            Text {
                                visible: job.modelData.detail !== "" && job.modelData.kind === "agent"
                                text: job.modelData.detail
                                font.family: root.mono
                                font.pixelSize: 10
                                color: Theme.textDim
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.statusText(job.modelData.status)
                                font.family: "Inter"
                                font.pixelSize: 11
                                color: root.statusColor(job.modelData.status)
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: job.modelData.title || job.modelData.key
                            wrapMode: Text.Wrap
                            maximumLineCount: job.expanded ? 6 : 2
                            elide: Text.ElideRight
                            font.family: "Inter"
                            font.pixelSize: 13
                            color: Theme.textPrimary
                        }
                        // Ce que le sous-agent a fait.
                        Text {
                            visible: job.modelData.tool_uses > 0 || job.modelData.tokens > 0
                            text: [job.modelData.tool_uses > 0 ? I18n.tr("claude.pane.toolUses", { n: job.modelData.tool_uses }) : "",
                                   job.modelData.tokens > 0 ? root.tokens(job.modelData.tokens) + " tokens" : "",
                                   job.modelData.duration_ms > 0 ? root.duration(job.modelData.duration_ms) : ""]
                                  .filter(x => x !== "").join(" · ")
                            font.family: "Inter"
                            font.pixelSize: 11
                            color: Theme.textDim
                        }

                        // Déplié : la commande, le rapport, la sortie.
                        Text {
                            visible: job.expanded && job.modelData.kind === "background" && job.modelData.detail !== ""
                            Layout.fillWidth: true
                            text: "$ " + job.modelData.detail
                            wrapMode: Text.WrapAnywhere
                            font.family: root.mono
                            font.pixelSize: 11
                            color: Theme.colorCyan
                        }
                        Rectangle {
                            visible: job.expanded && (job.modelData.report !== "" || job.output !== "")
                            Layout.fillWidth: true
                            implicitHeight: reportText.implicitHeight + 16
                            radius: Theme.radiusSmall
                            color: Theme.bgDeep
                            MarkdownText {
                                id: reportText
                                x: 8
                                y: 8
                                width: parent.width - 16
                                links: job.output === ""
                                markdown: job.output !== "" ? job.output.split("\n").slice(-200).join("\n") : job.modelData.report
                                font.family: job.output !== "" ? root.mono : "Inter"
                                font.pixelSize: job.output !== "" ? 11 : 12
                                color: Theme.textSecondary
                            }
                        }
                        RowLayout {
                            visible: job.expanded || job.modelData.agent !== ""
                            Layout.fillWidth: true
                            spacing: 14
                            Text {
                                visible: job.modelData.agent !== ""
                                text: I18n.tr("claude.pane.openAgent")
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: agentMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                                MouseArea {
                                    id: agentMa
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ClaudeChat.openAgent(job.modelData.agent, job.modelData.title)
                                }
                            }
                            Text {
                                visible: job.expanded && job.modelData.output_file !== ""
                                text: I18n.tr("claude.pane.showOutput")
                                font.family: "Inter"
                                font.pixelSize: 12
                                color: outputMa.containsMouse ? Theme.accentColor : Theme.textSecondary
                                MouseArea {
                                    id: outputMa
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: ClaudeChat.fetchOutput(job.modelData.output_file, (t) => job.output = t || " ")
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }
                }
            }
        }
    }
}
