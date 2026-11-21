pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import "../services"

// L'onglet « Réglages » du panneau de droite : un seul fil, par sections
// (SettingsSection), chacune une carte de lignes (SettingsRow).
//
//   APPARENCE    le thème, la couleur d'accent (teintes ou n'importe laquelle)
//   VOIX         le mot d'éveil, la langue parlée
//   ÉCRAN        celui qui porte l'interface
//   LANGUE       celle de l'interface
//   VIDÉO        la webcam (DeviceSettings), s'il y en a une
//   ASSISTANT    le modèle du pilote (AssistantSettings)
//   COMPTE       Google, pour l'agenda (GoogleAccount)
//
// Le son et le Wi-Fi se règlent dans leurs volets de la barre du bas. Tout
// s'applique tout de suite : anna l'enregistre.
Item {
    id: root

    // Gardé pour les appelants : l'onglet n'a pas d'en-tête.
    property bool showInternalHeader: false

    // ── Le clavier ────────────────────────────────────────────────
    // Tab passe d'un réglage à l'autre ; ce qui prend le clavier défile en
    // vue.
    readonly property Item keyboardItem: Window.activeFocusItem
    onKeyboardItemChanged: {
        var it = root.keyboardItem;
        var p = it;
        while (p && p !== flick.contentItem)
            p = p.parent;
        if (!p)
            return;
        var y = it.mapToItem(flick.contentItem, 0, 0).y;
        if (y < flick.contentY)
            flick.contentY = Math.max(0, y - 8);
        else if (y + it.height > flick.contentY + flick.height)
            flick.contentY = Math.min(flick.contentHeight - flick.height, y + it.height - flick.height + 8);
    }

    // La couleur d'accent à une teinte donnée : saturation et luminosité ne
    // bougent pas (plancher 0,35, qu'elle reste une couleur).
    function accentAt(h) {
        var c = Theme.accentColor;
        return Qt.hsva(h, Math.max(0.35, c.hsvSaturation), Math.max(0.35, c.hsvValue), 1);
    }

    // ‹ › : deux petits boutons pour passer d'un choix à l'autre.
    component Stepper: Row {
        id: stepper
        signal step(int dir)
        spacing: 2
        BarButton { size: 26; icon: "chevron-left.svg"; onClicked: stepper.step(-1) }
        BarButton { size: 26; icon: "chevron-right.svg"; onClicked: stepper.step(1) }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: col.implicitHeight + 24
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: col
            width: flick.width - 12
            spacing: 22

            // ── Apparence ────────────────────────────────────────
            SettingsSection {
                Layout.fillWidth: true
                title: I18n.tr("settings.appearance")

                SettingsRow {
                    icon: "theme.svg"
                    title: I18n.tr("setting.theme")
                    Segmented {
                        implicitWidth: 168
                        options: [{ label: I18n.tr("settings.theme.dark"), value: true },
                                  { label: I18n.tr("settings.theme.light"), value: false }]
                        current: Theme.darkMode
                        onPicked: Theme.toggleTheme()
                    }
                }

                SettingsRow {
                    icon: "palette.svg"
                    title: I18n.tr("setting.accent")
                    subtitle: Theme.accentHex.toUpperCase()
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("settings.reset")
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: resetMa.containsMouse ? Theme.textPrimary : Theme.textSecondary
                        Behavior on color { ColorAnimation { duration: 160 } }
                        MouseArea {
                            id: resetMa
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Theme.resetToDefaults()
                        }
                    }
                }

                // Les teintes, puis n'importe laquelle de l'arc-en-ciel.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: accentBox.implicitHeight + 18

                    ColumnLayout {
                        id: accentBox
                        x: 12
                        width: parent.width - 24
                        spacing: 14

                        Row {
                            spacing: 10
                            Repeater {
                                model: Theme.presets

                                Rectangle {
                                    id: swatch
                                    required property string modelData
                                    readonly property bool active: Theme.accentHex.toLowerCase() === swatch.modelData.toLowerCase()
                                    width: 26
                                    height: 26
                                    radius: 13
                                    color: swatch.modelData
                                    scale: swatchMa.pressed ? 0.88 : swatchMa.containsMouse ? 1.08 : 1
                                    Behavior on scale { SpringAnimation { spring: 5; damping: 0.35; epsilon: 0.002 } }

                                    // L'anneau autour de la teinte choisie.
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: parent.width + 8
                                        height: parent.height + 8
                                        radius: width / 2
                                        color: "transparent"
                                        border.width: 2
                                        border.color: swatch.modelData
                                        opacity: swatch.active ? 1 : 0
                                        scale: swatch.active ? 1 : 0.7
                                        Behavior on opacity { NumberAnimation { duration: 180 } }
                                        Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 2 } }
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

                        // N'importe quelle teinte : elle ne part à anna qu'au
                        // lâcher, chaque changement d'accent rechargeant Hyprland.
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
                                width: 16
                                height: 16
                                radius: 8
                                color: root.accentAt(hues.shown)
                                border.width: 3
                                border.color: Theme.bgDeep
                                scale: hueMa.pressed ? 1.2 : 1
                                Behavior on scale { SpringAnimation { spring: 5; damping: 0.35; epsilon: 0.002 } }
                            }
                            MouseArea {
                                id: hueMa
                                anchors.fill: parent
                                anchors.topMargin: -8
                                anchors.bottomMargin: -8
                                preventStealing: true
                                cursorShape: Qt.PointingHandCursor
                                function follow(mx) {
                                    hues.dragValue = Math.max(0, Math.min(0.999, (mx - 8) / Math.max(1, hues.width - 16)));
                                }
                                onPressed: (mouse) => follow(mouse.x)
                                onPositionChanged: (mouse) => follow(mouse.x)
                                onReleased: {
                                    Theme.setAccentColor(root.accentAt(hues.dragValue).toString());
                                    hues.dragValue = -1;
                                }
                            }
                        }
                    }
                }
            }

            // ── Voix ─────────────────────────────────────────────
            // Le mot d'éveil (anna/src/claude/wake.rs), et la langue des
            // réponses du pilote, à part de celle de l'interface.
            SettingsSection {
                Layout.fillWidth: true
                title: I18n.tr("settings.voice")

                SettingsRow {
                    icon: "mic.svg"
                    title: I18n.tr("settings.voice.wake", { word: Pilot.voiceWakeWord })
                    // Si le micro ou les modèles manquent, anna l'éteint et
                    // dit pourquoi.
                    subtitle: !Pilot.voiceWake && Pilot.voiceError ? Pilot.voiceError
                            : Pilot.voiceWake ? I18n.tr("settings.voice.listening") : I18n.tr("common.off")
                    clickable: true
                    onClicked: Pilot.voiceWakeToggle()
                    SettingsSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: Pilot.voiceWake
                        onToggled: Pilot.voiceWakeToggle()
                    }
                }

                SettingsRow {
                    id: voiceLang
                    readonly property int at: Math.max(0, I18n.voiceChoices.findIndex(c => c.code === I18n.voice))
                    function step(d) {
                        var n = I18n.voiceChoices.length;
                        if (n > 0)
                            I18n.setVoice(I18n.voiceChoices[(voiceLang.at + d + n) % n].code);
                    }
                    icon: "chat.svg"
                    title: I18n.tr("settings.voice.language")
                    subtitle: I18n.voiceChoices.length > 0 ? I18n.voiceChoices[voiceLang.at].name : ""
                    Keys.onLeftPressed: voiceLang.step(-1)
                    Keys.onRightPressed: voiceLang.step(1)
                    Stepper {
                        anchors.verticalCenter: parent.verticalCenter
                        onStep: (d) => voiceLang.step(d)
                    }
                }
            }

            // ── Écran ────────────────────────────────────────────
            // « Auto » en tête : la valeur de la config Nix, puis le premier
            // écran branché si elle ne correspond à rien. Le point : celui
            // qui porte l'interface en ce moment.
            SettingsSection {
                Layout.fillWidth: true
                title: I18n.tr("settings.screen")

                Repeater {
                    model: [null].concat(Quickshell.screens)

                    SettingsRow {
                        id: screenRow
                        required property var modelData
                        readonly property string key: screenRow.modelData ? Display.screenKey(screenRow.modelData) : ""
                        icon: "monitor.svg"
                        title: screenRow.modelData ? screenRow.modelData.model || screenRow.modelData.name
                                                   : I18n.tr("settings.screen.auto")
                        subtitle: (screenRow.modelData
                                   ? screenRow.modelData.name + "  ·  " + screenRow.modelData.width + "×" + screenRow.modelData.height
                                   : I18n.tr("settings.screen.default", { name: Display.defaultName || "—" }))
                                  + (screenRow.modelData !== null && Display.primary === screenRow.modelData ? "  ·  ●" : "")
                        clickable: true
                        selected: Display.preferred === screenRow.key
                        onClicked: Display.setPreferred(screenRow.key)
                    }
                }
            }

            // ── Langue ───────────────────────────────────────────
            // Une ligne par fichier de i18n/ : une langue ajoutée là apparaît
            // ici d'elle-même.
            SettingsSection {
                Layout.fillWidth: true
                title: I18n.tr("settings.language")

                Repeater {
                    model: I18n.available

                    SettingsRow {
                        id: langRow
                        required property var modelData
                        icon: "globe.svg"
                        title: langRow.modelData.name
                        clickable: true
                        selected: I18n.lang === langRow.modelData.code
                        onClicked: I18n.setLang(langRow.modelData.code)
                    }
                }
            }

            // ── Vidéo ────────────────────────────────────────────
            DeviceSettings {
                Layout.fillWidth: true
            }

            // ── Assistant ────────────────────────────────────────
            SettingsSection {
                Layout.fillWidth: true
                title: I18n.tr("settings.assistant")

                Item {
                    Layout.fillWidth: true
                    implicitHeight: assistant.implicitHeight + 24
                    AssistantSettings {
                        id: assistant
                        x: 12
                        y: 12
                        width: parent.width - 24
                    }
                }
            }

            // ── Compte ───────────────────────────────────────────
            // Google : l'onglet Agenda y lit les agendas et les tâches.
            SettingsSection {
                Layout.fillWidth: true
                title: I18n.tr("settings.account")

                Item {
                    Layout.fillWidth: true
                    implicitHeight: account.implicitHeight + 24
                    GoogleAccount {
                        id: account
                        x: 12
                        y: 12
                        width: parent.width - 24
                    }
                }
            }
        }
    }
}
