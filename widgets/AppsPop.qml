pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"

// Le volet du flocon, dans la barre du bas : les outils de karenine (les
// onglets du panneau, les tâches), puis les applications installées, par
// ordre alphabétique, avec un champ pour les filtrer. Un clic ouvre, et le
// volet se referme (`launched`).
//
//   OUTILS
//   [▣ Musique] [▣ Fichiers] [▣ Système] [▣ Agenda] …
//   APPLICATIONS                                   [ Filtrer…   ]
//   ◻ Blender   ◻ Chromium   ◻ GIMP   ◻ Kitty
//   ◻ …
ColumnLayout {
    id: root

    signal launched()

    spacing: 8

    // Les outils : un onglet du panneau, ou une action.
    readonly property var tools: [
        { icon: "music.svg", label: I18n.tr("widget.music"), tab: "music" },
        { icon: "folder.svg", label: I18n.tr("widget.explorer"), tab: "files" },
        { icon: "monitor.svg", label: I18n.tr("widget.stats"), tab: "system" },
        { icon: "calendar.svg", label: I18n.tr("widget.agenda"), tab: "agenda" },
        { icon: "tasks.svg", label: I18n.tr("apps.tasks"), tab: "" },
        { icon: "sparkles.svg", label: I18n.tr("widget.claude"), tab: "claude" },
        { icon: "settings.svg", label: I18n.tr("widget.settings"), tab: "settings" }
    ]

    property string filter: ""

    // Les applications montrées, par nom ; celles qui correspondent au filtre.
    readonly property var apps: {
        var q = root.filter.trim().toLowerCase();
        return DesktopEntries.applications.values
            .filter((e) => e && !e.noDisplay)
            .filter((e) => q === "" || [e.name, e.genericName, (e.keywords || []).join(" ")]
                .join(" ").toLowerCase().indexOf(q) >= 0)
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    function openTool(t) {
        if (t.tab === "")
            Widgets.showTasks();
        else
            Widgets.show(t.tab);
        root.launched();
    }

    function openApp(e) {
        e.execute();
        root.launched();
    }

    component Heading: Text {
        font.family: "Inter"
        font.pixelSize: 10
        font.weight: Font.DemiBold
        font.letterSpacing: 0.8
        font.capitalization: Font.AllUppercase
        color: Theme.textDim
    }

    Heading {
        text: I18n.tr("apps.tools")
    }
    Flow {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: root.tools
            Rectangle {
                id: tool
                required property var modelData
                width: toolRow.implicitWidth + 18
                height: 30
                radius: Theme.radiusSmall
                color: toolMa.containsMouse ? Theme.hoverOverlay : Qt.alpha(Theme.textPrimary, 0.06)
                Row {
                    id: toolRow
                    anchors.centerIn: parent
                    spacing: 7
                    NixIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        iconSize: 15
                        source: "../assets/ui/" + tool.modelData.icon
                        color: toolMa.containsMouse ? Theme.accentColor : Theme.iconColor
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: tool.modelData.label
                        font.family: "Inter"
                        font.pixelSize: 12
                        color: Theme.textPrimary
                    }
                }
                MouseArea {
                    id: toolMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openTool(tool.modelData)
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 4
        Heading {
            Layout.fillWidth: true
            text: I18n.tr("apps.apps")
        }
        Rectangle {
            implicitWidth: 150
            implicitHeight: 26
            radius: Theme.radiusSmall
            color: Qt.alpha(Theme.textPrimary, 0.06)
            border.width: filterInput.activeFocus ? 1 : 0
            border.color: Qt.alpha(Theme.accentColor, 0.6)
            TextInput {
                id: filterInput
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                onTextChanged: root.filter = filterInput.text
                // Entrée : la première application.
                Keys.onReturnPressed: if (root.apps.length > 0) root.openApp(root.apps[0])
                Keys.onEnterPressed: if (root.apps.length > 0) root.openApp(root.apps[0])
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: filterInput.text === ""
                    text: I18n.tr("apps.filter")
                    font: filterInput.font
                    color: Theme.textDim
                }
            }
        }
    }

    // Les applications, en grille ; elle défile au-delà de quatre rangées.
    GridView {
        id: grid
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(contentHeight, 4 * cellHeight)
        cellWidth: Math.floor(width / 4)
        cellHeight: 78
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.apps
        delegate: Item {
            id: app
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight
            Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: Theme.radiusSmall
                color: appMa.containsMouse ? Theme.hoverOverlay : "transparent"
            }
            Column {
                anchors.centerIn: parent
                width: parent.width - 8
                spacing: 6
                Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 32
                    height: 32
                    sourceSize.width: 64
                    sourceSize.height: 64
                    source: Theme.icon(app.modelData.icon, true) || Theme.icon("application-x-executable", true)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: app.modelData.name
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 11
                    color: Theme.textPrimary
                }
            }
            MouseArea {
                id: appMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openApp(app.modelData)
            }
        }
    }

    Text {
        visible: root.apps.length === 0
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: I18n.tr("apps.none")
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textDim
    }
}
