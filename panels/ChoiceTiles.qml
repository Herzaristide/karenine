pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "../services"

// Un choix en vignettes, par groupe : les écrans et les fenêtres à partager,
// chacun avec son aperçu en direct (ScreencopyView), puis les autres options
// (un espace de travail, une zone) en simples pastilles.
//
// Une option : { id, label, sub, group, preview }, `preview` valant
// { screen: "DP-1" } ou { window: "<adresse Hyprland, hex>" }.
ColumnLayout {
    id: tiles

    property var options: []
    property string value: ""
    signal picked(string id)
    signal activated(string id)

    spacing: 10

    // Les groupes, dans l'ordre de leur première option.
    readonly property var groups: {
        var seen = [];
        for (var i = 0; i < tiles.options.length; i++) {
            var g = tiles.options[i].group || "";
            if (seen.indexOf(g) < 0)
                seen.push(g);
        }
        return seen;
    }

    function inGroup(g) {
        return tiles.options.filter((o) => (o.group || "") === g);
    }

    // Ce que la vignette capture : l'écran, ou la fenêtre par son adresse.
    function source(preview) {
        if (!preview)
            return null;
        if (preview.screen) {
            var screens = Quickshell.screens;
            for (var i = 0; i < screens.length; i++)
                if (screens[i].name === preview.screen)
                    return screens[i];
            return null;
        }
        if (preview.window && preview.window !== "0") {
            var tops = Hyprland.toplevels.values;
            for (var j = 0; j < tops.length; j++)
                if (String(tops[j].address).replace(/^0x/, "").toLowerCase() === preview.window)
                    return tops[j].wayland;
        }
        return null;
    }

    Repeater {
        model: tiles.groups
        delegate: ColumnLayout {
            id: group
            required property string modelData
            Layout.fillWidth: true
            spacing: 6

            Text {
                visible: group.modelData !== ""
                text: group.modelData
                color: Theme.textDim
                font.family: "Inter"
                font.pixelSize: 11
                font.weight: Font.Medium
            }

            Flow {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: tiles.inGroup(group.modelData)
                    delegate: Rectangle {
                        id: tile
                        required property var modelData
                        readonly property bool picked: tiles.value === tile.modelData.id
                        readonly property bool big: !!tile.modelData.preview
                        readonly property var capture: tile.big ? tiles.source(tile.modelData.preview) : null

                        width: tile.big ? 200 : chipLabel.implicitWidth + 24
                        height: tile.big ? 150 : 30
                        radius: Theme.radiusSmall
                        color: tile.picked && !tile.big ? Theme.accentColor
                             : tileMa.containsMouse ? Theme.hoverOverlay : Theme.bgInput
                        border.width: tile.picked || tile.activeFocus ? 2 : 1
                        border.color: tile.picked ? Theme.accentColor : tile.activeFocus ? Theme.textPrimary : Theme.dividerColor

                        activeFocusOnTab: true
                        Keys.onSpacePressed: tiles.picked(tile.modelData.id)
                        Keys.onReturnPressed: tiles.activated(tile.modelData.id)
                        Keys.onEnterPressed: tiles.activated(tile.modelData.id)

                        // L'aperçu, réduit à la taille de la vignette.
                        Rectangle {
                            id: shot
                            visible: tile.big
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 6
                            height: 100
                            radius: 4
                            color: Theme.bgDeep
                            clip: true

                            ScreencopyView {
                                anchors.fill: parent
                                captureSource: tile.capture
                                live: tile.capture !== null && tiles.visible
                                constraintSize: Qt.size(shot.width * 2, shot.height * 2)
                            }
                        }

                        Column {
                            visible: tile.big
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 8
                            Text {
                                width: parent.width
                                text: tile.modelData.label
                                color: Theme.textPrimary
                                font.family: "Inter"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: tile.modelData.sub || ""
                                color: Theme.textDim
                                font.family: "JetBrains Mono"
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }

                        Text {
                            id: chipLabel
                            visible: !tile.big
                            anchors.centerIn: parent
                            text: tile.modelData.label
                            color: tile.picked ? Theme.bgDeep : Theme.textPrimary
                            font.family: "Inter"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            id: tileMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tiles.picked(tile.modelData.id)
                            onDoubleClicked: tiles.activated(tile.modelData.id)
                        }
                    }
                }
            }
        }
    }
}
