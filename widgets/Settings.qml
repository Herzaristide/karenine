pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import "../services"

Item {
    id: root

    property bool rainbowActive: false
    property real rainbowHue: 0.0

    // Set to false when rendered inside SettingsWindow (which provides its own title bar)
    property bool showInternalHeader: true

    // ── Rainbow cycling timer ─────────────────────────────────────
    Timer {
        id: rainbowTimer
        interval: 100
        repeat: true
        running: root.rainbowActive
        onTriggered: {
            root.rainbowHue = (root.rainbowHue + 0.025) % 1.0
            colorPicker.pickerH = root.rainbowHue
            fieldCanvas.requestPaint()
            colorPicker.updateAccent()
        }
    }

    // ── Le clavier ────────────────────────────────────────────────
    // Tab passe d'un réglage à l'autre ; Entrée ou Espace actionne, les
    // flèches règlent les sélecteurs de couleur. Les colonnes dépassent la
    // hauteur du widget : ce qui prend le clavier défile en vue.
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

    // Entrée ou Espace : `action()`. Pour les réglages faits
    // d'un rectangle et d'une MouseArea.
    function activates(event, action) {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            action();
            event.accepted = true;
        }
    }

    // Les flèches sur un sélecteur : ← → pour `dx`, ↑ ↓ pour `dy`, un pas
    // de 2 % (Maj : 10 %). Faux pour les autres touches.
    function arrows(event, move) {
        var s = event.modifiers & Qt.ShiftModifier ? 0.1 : 0.02;
        var k = event.key;
        if (k === Qt.Key_Left) move(-s, 0);
        else if (k === Qt.Key_Right) move(s, 0);
        else if (k === Qt.Key_Up) move(0, s);
        else if (k === Qt.Key_Down) move(0, -s);
        else return false;
        event.accepted = true;
        return true;
    }

    // ── UI ────────────────────────────────────────────────────────
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: mainCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        // En largeur, dans la capsule de la barre : une colonne par section
        // (périphériques, écran, apparence ; palette commentée).
        RowLayout {
            id: mainCol
            width: parent.width
            spacing: 18

            // Les périphériques : son, webcam, luminosité.
            DeviceSettings {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: 0

                // ── Header ───────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 8
                    spacing: 8
                    visible: root.showInternalHeader

                    Text {
                        text: I18n.tr("settings.title")
                        font.family: "Inter"
                        font.pixelSize: 14
                        font.weight: Font.Bold
                        color: Theme.textPrimary
                        Layout.fillWidth: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.accentDark
                    Layout.bottomMargin: 16
                    visible: root.showInternalHeader
                }

                // ── ÉCRAN section ──────────────────────────────────
                // Où s'affichent la barre et les panneaux.
                Text {
                    Layout.bottomMargin: 10
                    text: I18n.tr("settings.screen")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.letterSpacing: 0
                    color: Theme.accentMuted
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 12
                    spacing: 6

                    // « Auto » en tête : la valeur de la config Nix, puis le
                    // premier écran branché si elle ne correspond à rien.
                    Repeater {
                        model: [null].concat(Quickshell.screens)

                        delegate: Rectangle {
                            id: screenRow

                            required property var modelData
                            readonly property string key: modelData ? Display.screenKey(modelData) : ""
                            readonly property bool selected: Display.preferred === key
                            readonly property bool shown: modelData !== null && Display.primary === modelData

                            // Deux lignes, comme les périphériques : le nom, puis
                            // la sortie et la définition. Choisi : la teinte des
                            // onglets.
                            Layout.fillWidth: true
                            Layout.preferredHeight: 46
                            radius: Theme.radiusSmall
                            color: selected ? Theme.selectedFill
                                            : Qt.alpha(Theme.textPrimary, rowMa.containsMouse || activeFocus ? 0.09 : 0.05)
                            border.color: selected ? "transparent" : Theme.dividerColor
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: 160 } }

                            activeFocusOnTab: true
                            Keys.onPressed: (event) => root.activates(event, () => Display.setPreferred(screenRow.key))
                            FocusRing { radius: screenRow.radius + gap }

                            Column {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.right: shownDot.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                Text {
                                    width: parent.width
                                    text: screenRow.modelData ? screenRow.modelData.model || screenRow.modelData.name
                                                              : I18n.tr("settings.screen.auto")
                                    font.family: "Inter"
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    color: Theme.textPrimary
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: screenRow.modelData
                                          ? screenRow.modelData.name + "  ·  " + screenRow.modelData.width
                                            + "×" + screenRow.modelData.height
                                          : I18n.tr("settings.screen.default", { name: Display.defaultName || "—" })
                                    font.family: "Inter"
                                    font.pixelSize: 10
                                    color: Theme.textSecondary
                                    elide: Text.ElideRight
                                }
                            }

                            // L'écran qui porte l'interface en ce moment : en
                            // « Auto », c'est la seule façon de savoir lequel.
                            Rectangle {
                                id: shownDot
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: Theme.glow(0)
                                opacity: screenRow.shown ? 1.0 : 0.0
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Display.setPreferred(screenRow.key)
                            }
                        }
                    }
                }

                // ── ACCORDEUR section ──────────────────────────────
                // Le la de référence du Tuner, gardé d'une session à l'autre.
                Text {
                    Layout.topMargin: 6
                    Layout.bottomMargin: 10
                    text: I18n.tr("settings.tuner")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.letterSpacing: 0
                    color: Theme.accentMuted
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    Layout.bottomMargin: 18
                    radius: Theme.radius
                    color: Qt.alpha(Theme.textPrimary, 0.05)

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            text: I18n.tr("settings.tuner.reference")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                        }
                        Text {
                            text: Tuning.refFreq === 440 ? I18n.tr("settings.tuner.standard") : I18n.tr("settings.tuner.standardIs")
                            font.family: "Inter"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                        }
                    }

                    RowLayout {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        GlassButton {
                            implicitWidth: 28
                            implicitHeight: 28
                            fontSize: 14
                            text: "−"
                            onClicked: Tuning.setRefFreq(Tuning.refFreq - 1)
                        }
                        TextInput {
                            id: refInput
                            Layout.preferredWidth: 30
                            text: Tuning.refFreq.toFixed(0)
                            font.family: "Inter"
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            color: Theme.textPrimary
                            horizontalAlignment: TextInput.AlignHCenter
                            selectByMouse: true
                            inputMethodHints: Qt.ImhDigitsOnly
                            validator: IntValidator { bottom: Tuning.minFreq; top: Tuning.maxFreq }
                            // ↑ ↓ : un hertz de plus ou de moins.
                            activeFocusOnTab: true
                            Keys.onUpPressed: refInput.nudge(1)
                            Keys.onDownPressed: refInput.nudge(-1)
                            function nudge(d) {
                                Tuning.setRefFreq(Tuning.refFreq + d);
                                text = Tuning.refFreq.toFixed(0);
                            }
                            FocusRing { radius: 6; anchors.leftMargin: -4; anchors.rightMargin: -4 }
                            onEditingFinished: {
                                Tuning.setRefFreq(parseInt(text));
                                text = Tuning.refFreq.toFixed(0);
                            }
                            Connections {
                                target: Tuning
                                function onRefFreqChanged() {
                                    if (!refInput.activeFocus)
                                        refInput.text = Tuning.refFreq.toFixed(0);
                                }
                            }
                        }
                        Text {
                            text: "Hz"
                            font.family: "Inter"
                            font.pixelSize: 11
                            color: Theme.textSecondary
                        }
                        GlassButton {
                            implicitWidth: 28
                            implicitHeight: 28
                            fontSize: 14
                            text: "+"
                            onClicked: Tuning.setRefFreq(Tuning.refFreq + 1)
                        }
                    }
                }

                // ── VOIX section ───────────────────────────────────
                // Le mot d'éveil « Karénine » (anna/src/claude/wake.rs) :
                // anna le garde d'un redémarrage à l'autre.
                Text {
                    Layout.bottomMargin: 10
                    text: I18n.tr("settings.voice")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.letterSpacing: 0
                    color: Theme.accentMuted
                }

                Rectangle {
                    id: wakeRow
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    Layout.bottomMargin: 18
                    radius: Theme.radius
                    color: Qt.alpha(Theme.textPrimary, wakeMa.containsMouse || activeFocus ? 0.09 : 0.05)
                    Behavior on color { ColorAnimation { duration: 160 } }

                    activeFocusOnTab: true
                    Keys.onPressed: (event) => root.activates(event, () => Pilot.voiceWakeToggle())
                    FocusRing { radius: wakeRow.radius + gap }

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: wakePill.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            text: I18n.tr("settings.voice.wake")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                        // Si le micro ou les modèles manquent, anna l'éteint
                        // et dit pourquoi.
                        Text {
                            width: parent.width
                            text: !Pilot.voiceWake && Pilot.voiceError
                                  ? Pilot.voiceError
                                  : Pilot.voiceWake ? I18n.tr("settings.voice.listening") : I18n.tr("common.off")
                            font.family: "Inter"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                            elide: Text.ElideRight
                        }
                    }

                    Rectangle {
                        id: wakePill
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 44; height: 22; radius: 11
                        color: Pilot.voiceWake ? Theme.accentColor : Theme.accentDark
                        Behavior on color { ColorAnimation { duration: 200 } }

                        Rectangle {
                            width: 16; height: 16; radius: 8
                            anchors.verticalCenter: parent.verticalCenter
                            x: Pilot.voiceWake ? 24 : 4
                            color: Theme.iconColor
                            Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        }
                    }

                    MouseArea {
                        id: wakeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Pilot.voiceWakeToggle()
                    }
                }

                // La langue parlée (whisper, réponses du pilote) : à part de
                // celle de l'interface. ‹ › passent d'un choix à l'autre.
                Rectangle {
                    id: voiceLangRow
                    readonly property int at: Math.max(0, I18n.voiceChoices.findIndex(c => c.code === I18n.voice))

                    function step(d) {
                        var n = I18n.voiceChoices.length;
                        I18n.setVoice(I18n.voiceChoices[(voiceLangRow.at + d + n) % n].code);
                    }

                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    Layout.topMargin: -10
                    Layout.bottomMargin: 18
                    radius: Theme.radius
                    color: Qt.alpha(Theme.textPrimary, activeFocus ? 0.09 : 0.05)

                    activeFocusOnTab: true
                    Keys.onLeftPressed: voiceLangRow.step(-1)
                    Keys.onRightPressed: voiceLangRow.step(1)
                    Keys.onPressed: (event) => root.activates(event, () => voiceLangRow.step(1))
                    FocusRing { radius: voiceLangRow.radius + gap }

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: voiceLangButtons.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            text: I18n.tr("settings.voice.language")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: I18n.voiceChoices.length > 0 ? I18n.voiceChoices[voiceLangRow.at].name : ""
                            font.family: "Inter"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: voiceLangButtons
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "‹"; onClicked: voiceLangRow.step(-1) }
                        GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "›"; onClicked: voiceLangRow.step(1) }
                    }
                }

                // Les réponses du pilote lues à voix haute (anna/src/claude/
                // speech.rs) : jamais, aux demandes dites seulement, ou
                // toujours. anna s'en souvient.
                Rectangle {
                    id: speechRow
                    readonly property var modes: ["off", "voice", "always"]
                    readonly property var names: [I18n.tr("settings.voice.speech.off"),
                                                  I18n.tr("settings.voice.speech.voice"),
                                                  I18n.tr("settings.voice.speech.always")]
                    readonly property int at: Math.max(0, modes.indexOf(Pilot.speechMode))

                    function step(d) {
                        var n = modes.length;
                        Pilot.speechSetMode(modes[(speechRow.at + d + n) % n]);
                    }

                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    Layout.topMargin: -10
                    Layout.bottomMargin: 18
                    radius: Theme.radius
                    color: Qt.alpha(Theme.textPrimary, activeFocus ? 0.09 : 0.05)

                    activeFocusOnTab: true
                    Keys.onLeftPressed: speechRow.step(-1)
                    Keys.onRightPressed: speechRow.step(1)
                    Keys.onPressed: (event) => root.activates(event, () => speechRow.step(1))
                    FocusRing { radius: speechRow.radius + gap }

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: speechButtons.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            text: I18n.tr("settings.voice.speech")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: speechRow.names[speechRow.at]
                            font.family: "Inter"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: speechButtons
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "‹"; onClicked: speechRow.step(-1) }
                        GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "›"; onClicked: speechRow.step(1) }
                    }
                }

                // La voix Piper qui lit : une par fichier installé (et par
                // locuteur pour les voix qui en ont plusieurs).
                Rectangle {
                    id: speakerRow
                    readonly property int at: Math.max(0, Pilot.speechVoices.findIndex(v => v.id === Pilot.speechVoice))
                    readonly property bool usable: Pilot.speechVoices.length > 0 && Pilot.speechMode !== "off"

                    function step(d) {
                        var n = Pilot.speechVoices.length;
                        if (n > 0)
                            Pilot.speechSetVoice(Pilot.speechVoices[(speakerRow.at + d + n) % n].id);
                    }

                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    Layout.topMargin: -10
                    Layout.bottomMargin: 18
                    radius: Theme.radius
                    color: Qt.alpha(Theme.textPrimary, activeFocus ? 0.09 : 0.05)
                    opacity: usable ? 1 : 0.5
                    Behavior on opacity { NumberAnimation { duration: 160 } }

                    activeFocusOnTab: usable
                    Keys.onLeftPressed: speakerRow.step(-1)
                    Keys.onRightPressed: speakerRow.step(1)
                    Keys.onPressed: (event) => root.activates(event, () => speakerRow.step(1))
                    FocusRing { radius: speakerRow.radius + gap }

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: speakerButtons.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            text: I18n.tr("settings.voice.speaker")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                        // Une voix qui ne peut pas lire dit pourquoi.
                        Text {
                            width: parent.width
                            text: Pilot.speechError
                                  ? Pilot.speechError
                                  : Pilot.speechVoices.length > 0
                                    ? Pilot.speechVoices[speakerRow.at].name
                                    : I18n.tr("settings.voice.speaker.none")
                            font.family: "Inter"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: speakerButtons
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        visible: Pilot.speechVoices.length > 1
                        GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "‹"; onClicked: speakerRow.step(-1) }
                        GlassButton { implicitWidth: 24; implicitHeight: 24; fontSize: 13; text: "›"; onClicked: speakerRow.step(1) }
                    }
                }

                // ── LANGUE section ─────────────────────────────────
                // Une ligne par fichier de i18n/ : une langue ajoutée là
                // apparaît ici d'elle-même.
                Text {
                    Layout.bottomMargin: 10
                    text: I18n.tr("settings.language")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.letterSpacing: 0
                    color: Theme.accentMuted
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 18
                    spacing: 6

                    Repeater {
                        model: I18n.available

                        delegate: Rectangle {
                            id: langRow

                            required property var modelData
                            readonly property bool selected: I18n.lang === modelData.code

                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: Theme.radiusSmall
                            color: selected ? Theme.selectedFill
                                            : Qt.alpha(Theme.textPrimary, langMa.containsMouse || activeFocus ? 0.09 : 0.05)
                            border.color: selected ? "transparent" : Theme.dividerColor
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: 160 } }

                            activeFocusOnTab: true
                            Keys.onPressed: (event) => root.activates(event, () => I18n.setLang(langRow.modelData.code))
                            FocusRing { radius: langRow.radius + gap }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.right: langCode.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                text: langRow.modelData.name
                                font.family: "Inter"
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: Theme.textPrimary
                                elide: Text.ElideRight
                            }

                            Text {
                                id: langCode
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: langRow.modelData.code
                                font.family: "Inter"
                                font.pixelSize: 10
                                color: Theme.textSecondary
                            }

                            MouseArea {
                                id: langMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: I18n.setLang(langRow.modelData.code)
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: 0

                // ── APPARENCE section ──────────────────────────────
                Text {
                    Layout.bottomMargin: 10
                    text: I18n.tr("settings.appearance")
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.letterSpacing: 0
                    color: Theme.accentMuted
                }

                // ── Dark / Light mode toggle ───────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 12
                    spacing: 8

                    // Toggle pill
                    Rectangle {
                        id: themePill
                        Layout.preferredWidth: 44; Layout.preferredHeight: 22; radius: 11
                        color: Theme.darkMode ? Theme.accentDark : Theme.accentColor
                        Behavior on color { ColorAnimation { duration: 200 } }

                        activeFocusOnTab: true
                        Keys.onPressed: (event) => root.activates(event, () => Theme.toggleTheme())
                        FocusRing {}

                        // Knob
                        Rectangle {
                            width: 16; height: 16; radius: 8
                            anchors.verticalCenter: parent.verticalCenter
                            x: Theme.darkMode ? 24 : 4
                            color: Theme.iconColor
                            Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Theme.toggleTheme()
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: Theme.darkMode ? I18n.tr("settings.theme.dark") : I18n.tr("settings.theme.light")
                        font.family: "Inter"
                        font.pixelSize: 11
                        color: Theme.textSecondary
                    }
                }

                // Color preview chip + hex input
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 8
                    spacing: 8

                    Rectangle {
                        Layout.preferredWidth: 24; Layout.preferredHeight: 24; radius: 5
                        color: Theme.accentColor
                        border.color: Theme.dividerColor
                        border.width: 1
                    }

                    TextField {
                        id: hexField
                        Layout.fillWidth: true
                        text: Theme.accentColor.toString().toUpperCase()
                        font.family: "Inter"
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        leftPadding: 8; rightPadding: 8
                        selectByMouse: true
                        background: Rectangle {
                            color: Theme.bgInput
                            radius: 6
                            border.color: Theme.accentDark
                            border.width: 1
                        }
                        Connections {
                            target: Theme
                            function onAccentColorChanged() {
                                if (!hexField.activeFocus)
                                    hexField.text = Theme.accentColor.toString().toUpperCase()
                            }
                        }
                        onEditingFinished: {
                            var t = text.trim()
                            if (!t.startsWith("#")) t = "#" + t
                            if (/^#[0-9a-fA-F]{6}$/.test(t) || /^#[0-9a-fA-F]{3}$/.test(t)) {
                                colorPicker.initFromColor(Qt.color(t))
                                Theme.setAccentColor(t.toLowerCase())
                            } else {
                                text = Theme.accentColor.toString().toUpperCase()
                            }
                        }
                    }
                }

                // ── Color picker ─────────────────────────────────────
                Item {
                    id: colorPicker
                    Layout.fillWidth: true
                    Layout.preferredHeight: 144  // 120 field + 8 gap + 14 hue + 2 padding
                    Layout.bottomMargin: 16

                    // Internal HSV state (0.0 – 1.0 each)
                    property real pickerH: 0.667
                    property real pickerS: 0.5
                    property real pickerV: 0.56

                    Component.onCompleted: initFromColor(Theme.accentColor)

                    function initFromColor(c) {
                        var hsv = rgbToHsv(c.r, c.g, c.b)
                        pickerH = hsv.h
                        pickerS = hsv.s
                        pickerV = hsv.v
                    }

                    function rgbToHsv(r, g, b) {
                        var max = Math.max(r, g, b), min = Math.min(r, g, b)
                        var delta = max - min
                        var h = 0, s = 0, v = max
                        if (max > 0) s = delta / max
                        if (delta > 0) {
                            if (max === r)      h = ((g - b) / delta) % 6
                            else if (max === g) h = (b - r) / delta + 2
                            else               h = (r - g) / delta + 4
                            h /= 6
                            if (h < 0) h += 1
                        }
                        return { h: h, s: s, v: v }
                    }

                    function hsvToHex(h, s, v) {
                        var i = Math.floor(h * 6), f = h * 6 - i
                        var p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
                        var r, g, b
                        switch (i % 6) {
                            case 0: r = v; g = t; b = p; break
                            case 1: r = q; g = v; b = p; break
                            case 2: r = p; g = v; b = t; break
                            case 3: r = p; g = q; b = v; break
                            case 4: r = t; g = p; b = v; break
                            case 5: r = v; g = p; b = q; break
                        }
                        function x2h(n) { var s = Math.round(n * 255).toString(16); return s.length === 1 ? "0"+s : s }
                        return "#" + x2h(r) + x2h(g) + x2h(b)
                    }

                    function updateAccent() {
                        Theme.setAccentColor(hsvToHex(pickerH, pickerS, pickerV))
                    }

                    // Re-sync HSV when accent.hex is loaded (or changed externally),
                    // but not while the user is actively dragging the picker.
                    property bool userInteracting: false
                    Connections {
                        target: Theme
                        function onAccentColorChanged() {
                            if (!colorPicker.userInteracting)
                                colorPicker.initFromColor(Theme.accentColor)
                        }
                    }

                    // ── Saturation / brightness field ─────────────────
                    Canvas {
                        id: fieldCanvas
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 120

                        Connections {
                            target: colorPicker
                            function onPickerHChanged() { fieldCanvas.requestPaint() }
                        }

                        // ← → : la saturation ; ↑ ↓ : la luminosité.
                        activeFocusOnTab: true
                        Keys.onPressed: (event) => root.arrows(event, (dx, dy) => {
                            colorPicker.userInteracting = true
                            colorPicker.pickerS = Math.max(0, Math.min(1, colorPicker.pickerS + dx))
                            colorPicker.pickerV = Math.max(0, Math.min(1, colorPicker.pickerV + dy))
                            colorPicker.updateAccent()
                            colorPicker.userInteracting = false
                        })
                        FocusRing { radius: 6 }

                        onPaint: {
                            var ctx = getContext("2d"), w = width, h = height
                            // Base: pure hue at full saturation + value
                            ctx.fillStyle = colorPicker.hsvToHex(colorPicker.pickerH, 1.0, 1.0)
                            ctx.fillRect(0, 0, w, h)
                            // White → transparent (left = white, right = saturated)
                            var wg = ctx.createLinearGradient(0, 0, w, 0)
                            wg.addColorStop(0.0, "rgba(255,255,255,1)")
                            wg.addColorStop(1.0, "rgba(255,255,255,0)")
                            ctx.fillStyle = wg; ctx.fillRect(0, 0, w, h)
                            // Transparent → black (top = bright, bottom = dark)
                            var bg = ctx.createLinearGradient(0, 0, 0, h)
                            bg.addColorStop(0.0, "rgba(0,0,0,0)")
                            bg.addColorStop(1.0, "rgba(0,0,0,1)")
                            ctx.fillStyle = bg; ctx.fillRect(0, 0, w, h)
                        }

                        // Crosshair cursor
                        Rectangle {
                            x: colorPicker.pickerS * fieldCanvas.width  - width  / 2
                            y: (1 - colorPicker.pickerV) * fieldCanvas.height - height / 2
                            width: 14; height: 14; radius: 7
                            color: "transparent"
                            border.color: Theme.iconColor; border.width: 2
                            antialiasing: true
                            Rectangle {
                                anchors.centerIn: parent
                                width: 6; height: 6; radius: 3
                                color: "transparent"
                                border.color: Qt.rgba(0, 0, 0, 0.55); border.width: 1
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.CrossCursor
                            function pick(mouse) {
                                colorPicker.pickerS = Math.max(0, Math.min(1, mouse.x / width))
                                colorPicker.pickerV = Math.max(0, Math.min(1, 1 - mouse.y / height))
                                colorPicker.updateAccent()
                            }
                            onPressed:         (mouse) => { colorPicker.userInteracting = true; pick(mouse) }
                            onReleased:        colorPicker.userInteracting = false
                            onPositionChanged: (mouse) => { if (pressed) pick(mouse) }
                        }
                    }

                    // ── Hue strip ─────────────────────────────────────
                    Item {
                        id: hueRow
                        anchors.top: fieldCanvas.bottom
                        anchors.topMargin: 8
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 14

                        // ← → (ou ↑ ↓) : la teinte.
                        activeFocusOnTab: true
                        Keys.onPressed: (event) => root.arrows(event, (dx, dy) => {
                            colorPicker.userInteracting = true
                            colorPicker.pickerH = Math.max(0, Math.min(0.9999, colorPicker.pickerH + dx + dy))
                            fieldCanvas.requestPaint()
                            colorPicker.updateAccent()
                            colorPicker.userInteracting = false
                        })
                        FocusRing { radius: 6 }

                        Canvas {
                            id: hueCanvas
                            anchors.fill: parent
                            onPaint: {
                                var ctx = getContext("2d")
                                var grad = ctx.createLinearGradient(0, 0, width, 0)
                                for (var i = 0; i <= 12; i++) {
                                    var stop = i / 12
                                    grad.addColorStop(stop, "hsl(" + Math.round(stop * 360) + ",100%,50%)")
                                }
                                var r = 4
                                ctx.beginPath()
                                ctx.moveTo(r, 0); ctx.lineTo(width - r, 0)
                                ctx.arcTo(width, 0,      width,      r,          r)
                                ctx.lineTo(width, height - r)
                                ctx.arcTo(width, height, width - r,  height,     r)
                                ctx.lineTo(r, height)
                                ctx.arcTo(0, height,     0,          height - r, r)
                                ctx.lineTo(0, r)
                                ctx.arcTo(0, 0,          r,          0,          r)
                                ctx.closePath()
                                ctx.fillStyle = grad; ctx.fill()
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                function pick(mouse) {
                                    colorPicker.pickerH = Math.max(0, Math.min(0.9999, mouse.x / width))
                                    fieldCanvas.requestPaint()
                                    colorPicker.updateAccent()
                                }
                                onPressed:         (mouse) => { colorPicker.userInteracting = true; pick(mouse) }
                                onReleased:        colorPicker.userInteracting = false
                                onPositionChanged: (mouse) => { if (pressed) pick(mouse) }
                            }
                        }

                        // Thumb indicator
                        Rectangle {
                            x: colorPicker.pickerH * hueRow.width - width / 2
                            y: -2
                            width: 5; height: hueRow.height + 4; radius: 2.5
                            color: Theme.iconColor
                            border.color: Qt.rgba(0, 0, 0, 0.45); border.width: 1
                            antialiasing: true
                        }
                    }
                }

                // ── Rainbow + Reset row ───────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 16
                    spacing: 8

                // ── Rainbow cycling button ─────────────────────────
                Item {
                    id: rainbowBtn
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32

                    function toggle() {
                        if (!root.rainbowActive) {
                            // Start from current hue so it doesn't jump
                            root.rainbowHue = colorPicker.pickerH
                        }
                        root.rainbowActive = !root.rainbowActive
                    }

                    activeFocusOnTab: true
                    Keys.onPressed: (event) => root.activates(event, rainbowBtn.toggle)
                    FocusRing { radius: Theme.radiusSmall + gap }

                    // Rainbow gradient background
                    Canvas {
                        id: rainbowBtnBg
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            var grad = ctx.createLinearGradient(0, 0, width, 0)
                            for (var i = 0; i <= 12; i++) {
                                grad.addColorStop(i / 12, "hsl(" + Math.round(i / 12 * 360) + ",90%,55%)")
                            }
                            var r = 8
                            ctx.beginPath()
                            ctx.moveTo(r, 0); ctx.lineTo(width - r, 0)
                            ctx.arcTo(width, 0,      width,      r,          r)
                            ctx.lineTo(width, height - r)
                            ctx.arcTo(width, height, width - r,  height,     r)
                            ctx.lineTo(r, height)
                            ctx.arcTo(0, height,     0,          height - r, r)
                            ctx.lineTo(0, r)
                            ctx.arcTo(0, 0,          r,          0,          r)
                            ctx.closePath()
                            ctx.fillStyle = grad
                            ctx.fill()
                        }
                    }

                    // Dimming overlay — lighter when active
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusSmall
                        color: Theme.bgDeep
                        opacity: root.rainbowActive ? 0.10 : 0.50
                        Behavior on opacity { NumberAnimation { duration: 250 } }
                    }

                    // Active border glow
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusSmall
                        color: "transparent"
                        border.color: Theme.iconColor
                        border.width: 1
                        opacity: root.rainbowActive ? 0.8 : 0.0
                        Behavior on opacity { NumberAnimation { duration: 250 } }
                    }

                    // Icon + label
                    Row {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: root.rainbowActive ? I18n.tr("common.stop") : I18n.tr("settings.rainbow")
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            color: Theme.iconColor
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: rainbowBtn.toggle()
                    }
                }

                // ── Reset to default button ───────────────────────
                Item {
                    id: resetBtn
                    Layout.preferredWidth: 78
                    Layout.preferredHeight: 32

                    function reset() {
                        root.rainbowActive = false
                        Theme.resetToDefaults()
                    }

                    activeFocusOnTab: true
                    Keys.onPressed: (event) => root.activates(event, resetBtn.reset)
                    FocusRing { radius: Theme.radiusSmall + gap }

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusSmall
                        color: Qt.alpha(Theme.textPrimary, 0.1)
                        border.color: Theme.dividerColor
                        border.width: 1
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 5
                        NixIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            iconSize: 12
                            source: "../assets/icons/reset.svg"
                            color: Theme.textSecondary
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.tr("settings.reset")
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            color: Theme.textSecondary
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: resetBtn.reset()
                    }
                }

                } // end RowLayout

                Item { Layout.preferredHeight: 8 }
            }

            // La palette base16, désactivée le temps de décider si on la garde,
            // est retirée du fichier : elle vit dans l'historique (commit 5654a85,
            // widgets/Settings.qml), avec son état en tête de fichier.
        }
    }

}
