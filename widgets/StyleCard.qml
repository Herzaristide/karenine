pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Le volet « style » de la barre (la palette) : la couleur d'accent, parmi
// celles de Theme.presets ou n'importe quelle teinte de l'arc-en-ciel, et
// le thème, encre ou papier. anna applique tout à chaud, partout.
ColumnLayout {
    id: root

    // « Tous les réglages » : l'écran, la langue, la voix, la webcam.
    signal openSettings()

    spacing: 10

    // La couleur d'accent à une teinte donnée : saturation et luminosité ne
    // bougent pas, comme quand on la fait tourner aux flèches (SettingSource).
    function accentAt(h) {
        var c = Theme.accentColor;
        return Qt.hsva(h, Math.max(0.35, c.hsvSaturation), Math.max(0.35, c.hsvValue), 1);
    }

    component Heading: Text {
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.8
        font.capitalization: Font.AllUppercase
        color: Theme.textDim
    }

    Heading { text: I18n.tr("setting.accent") }

    Row {
        spacing: 10

        Repeater {
            model: Theme.presets

            Rectangle {
                id: swatch
                required property string modelData
                readonly property bool active: Theme.accentHex.toLowerCase() === swatch.modelData.toLowerCase()
                width: 28
                height: 28
                radius: 14
                color: swatch.modelData
                border.width: swatch.active ? 2 : 0
                border.color: Theme.bgDeep
                scale: swatchMa.pressed ? 0.9 : swatchMa.containsMouse ? 1.08 : 1
                Behavior on scale { NumberAnimation { duration: 120 } }

                // L'anneau autour de la teinte choisie.
                Rectangle {
                    visible: swatch.active
                    anchors.centerIn: parent
                    width: parent.width + 6
                    height: parent.height + 6
                    radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: swatch.modelData
                }
                MouseArea {
                    id: swatchMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Theme.setAccentColor(swatch.modelData)
                }
            }
        }
    }

    // N'importe quelle teinte : elle ne part à anna qu'au lâcher, chaque
    // changement d'accent rechargeant Hyprland.
    Item {
        id: hues
        Layout.fillWidth: true
        implicitHeight: 18
        property real dragValue: -1
        readonly property real hue: Theme.accentColor.hsvHue < 0 ? 0 : Theme.accentColor.hsvHue
        readonly property real shown: hues.dragValue >= 0 ? hues.dragValue : hues.hue

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 6
            radius: 3
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0 / 6; color: root.accentAt(0 / 6) }
                GradientStop { position: 1 / 6; color: root.accentAt(1 / 6) }
                GradientStop { position: 2 / 6; color: root.accentAt(2 / 6) }
                GradientStop { position: 3 / 6; color: root.accentAt(3 / 6) }
                GradientStop { position: 4 / 6; color: root.accentAt(4 / 6) }
                GradientStop { position: 5 / 6; color: root.accentAt(5 / 6) }
                GradientStop { position: 6 / 6; color: root.accentAt(0.999) }
            }
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: hues.shown * (hues.width - width)
            width: 14
            height: 14
            radius: 7
            color: root.accentAt(hues.shown)
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
                hues.dragValue = Math.max(0, Math.min(0.999, (mx - 7) / Math.max(1, hues.width - 14)));
            }
            onPressed: (mouse) => follow(mouse.x)
            onPositionChanged: (mouse) => follow(mouse.x)
            onReleased: {
                Theme.setAccentColor(root.accentAt(hues.dragValue).toString());
                hues.dragValue = -1;
            }
        }
    }

    Heading {
        Layout.topMargin: 4
        text: I18n.tr("settings.appearance")
    }

    // Encre ou papier, comme les onglets des widgets.
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 34
        radius: Theme.radiusSmall + 2
        color: Theme.bgElevated

        Row {
            anchors.fill: parent
            anchors.margins: 3
            spacing: 3

            Repeater {
                model: [{ dark: true, key: "settings.theme.dark" }, { dark: false, key: "settings.theme.light" }]

                Rectangle {
                    id: mode
                    required property var modelData
                    readonly property bool active: Theme.darkMode === mode.modelData.dark
                    width: (parent.width - 3) / 2
                    height: parent.height
                    radius: Theme.radiusSmall
                    color: mode.active ? Theme.bgDeep : modeMa.containsMouse ? Theme.hoverOverlay : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: I18n.tr(mode.modelData.key)
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: mode.active ? Theme.textPrimary : Theme.textSecondary
                    }
                    MouseArea {
                        id: modeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (!mode.active) Theme.toggleTheme()
                    }
                }
            }
        }
    }

    // Le reste des réglages, dans le panneau de droite.
    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 2
        implicitHeight: 34
        radius: Theme.radiusSmall
        color: allMa.containsMouse ? Theme.hoverOverlay : "transparent"

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            NixIcon {
                anchors.verticalCenter: parent.verticalCenter
                iconSize: 16
                source: "../assets/ui/settings.svg"
                color: Theme.textSecondary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("settings.all")
                font.family: "Inter"
                font.pixelSize: 13
                color: Theme.textPrimary
            }
        }
        MouseArea {
            id: allMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openSettings()
        }
    }
}
