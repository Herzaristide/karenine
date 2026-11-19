pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Le modèle du pilote, dans les réglages (anna/src/claude/pilot.rs) : anna
// lui parle directement, avec l'API Anthropic Messages, soit à un modèle
// local servi par Ollama, soit à une API distante avec une clé.
//
//   ( ▣ Ollama            ) ( ☁ API Anthropic      )
//     un modèle local         un modèle distant, avec une clé
//   Adresse   [ http://localhost:11434            ]
//   Clé       [ ••••••••                 ] (Retirer)   (API seulement)
//   Modèle                                       (↻)
//   ( qwen3.5:9b ) ( gemma4:e4b ) ( qwen3.5:4b )
//   [ un autre modèle… ]
//   Réfléchir avant de répondre                 (◯ )
//
// Chaque choix s'applique tout de suite : anna l'enregistre
// (~/.config/anna/pilot.json, la clé à part dans pilot.key, lisible de
// l'utilisateur seul) et reprend la conversation à zéro.
ColumnLayout {
    id: assistant

    spacing: 8

    Component.onCompleted: Pilot.loadPilotConfig()

    readonly property var info: Pilot.pilotConfig
    readonly property var cfg: assistant.info ? assistant.info.config
                                              : ({ provider: "ollama", url: "", model: "", think: false })
    readonly property bool remote: assistant.cfg.provider === "anthropic"
    readonly property var models: assistant.info ? assistant.info.models || [] : []

    // Le réglage d'anna, avec `changes` par-dessus ; `key` comme
    // Pilot.configurePilot.
    function apply(changes, key) {
        Pilot.configurePilot(Object.assign({}, assistant.cfg, changes), key);
    }

    // Un champ des réglages ; Entrée l'applique.
    component Field: Rectangle {
        id: field
        property alias text: input.text
        property string placeholder: ""
        property bool secret: false
        readonly property bool editing: input.activeFocus
        signal accepted()

        Layout.fillWidth: true
        Layout.preferredHeight: 34
        radius: Theme.radiusSmall
        color: Qt.alpha(Theme.textPrimary, input.activeFocus ? 0.09 : 0.05)
        border.color: input.activeFocus ? Qt.alpha(Theme.glow(0), 0.5) : Theme.dividerColor
        border.width: 1

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textPrimary
            echoMode: field.secret ? TextInput.Password : TextInput.Normal
            selectByMouse: true
            activeFocusOnTab: true
            clip: true
            onAccepted: field.accepted()

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                visible: input.text === ""
                text: field.placeholder
                elide: Text.ElideRight
                font: input.font
                color: Theme.textDim
            }
        }
    }

    // Le titre d'un réglage, à gauche de son champ.
    component Label: Text {
        Layout.preferredWidth: 58
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.Medium
        color: Theme.textSecondary
        elide: Text.ElideRight
    }

    // ── Le fournisseur ───────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Repeater {
            model: [
                { key: "ollama", icon: "computer", title: I18n.tr("settings.assistant.ollama"),
                  sub: I18n.tr("settings.assistant.ollama.sub") },
                { key: "anthropic", icon: "server", title: I18n.tr("settings.assistant.anthropic"),
                  sub: I18n.tr("settings.assistant.anthropic.sub") }
            ]

            delegate: Rectangle {
                id: providerRow
                required property var modelData
                readonly property bool selected: assistant.cfg.provider === providerRow.modelData.key

                function choose() {
                    // Un autre fournisseur : son adresse par défaut, et un
                    // modèle à choisir dans sa liste.
                    if (!providerRow.selected)
                        assistant.apply({ provider: providerRow.modelData.key, url: "", model: "" });
                }

                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.preferredHeight: 46
                radius: Theme.radiusSmall
                color: providerRow.selected ? Theme.selectedFill
                                            : Qt.alpha(Theme.textPrimary, providerMa.containsMouse || activeFocus ? 0.09 : 0.05)
                border.color: providerRow.selected ? "transparent" : Theme.dividerColor
                border.width: 1
                Behavior on color { ColorAnimation { duration: 160 } }

                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        providerRow.choose();
                        event.accepted = true;
                    }
                }
                FocusRing { radius: providerRow.radius + gap }

                NixIcon {
                    id: providerIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    iconSize: 16
                    source: "../assets/icons/" + providerRow.modelData.icon + ".svg"
                    color: providerRow.selected ? Theme.accentColor : Theme.textSecondary
                }
                Column {
                    anchors.left: providerIcon.right
                    anchors.leftMargin: 10
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text {
                        width: parent.width
                        text: providerRow.modelData.title
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: Theme.textPrimary
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: providerRow.modelData.sub
                        font.family: "Inter"
                        font.pixelSize: 10
                        color: Theme.textSecondary
                        elide: Text.ElideRight
                    }
                }
                MouseArea {
                    id: providerMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: providerRow.choose()
                }
            }
        }
    }

    // ── L'adresse ────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 4
        spacing: 8
        Label { text: I18n.tr("settings.assistant.url") }
        Field {
            id: urlField
            placeholder: assistant.remote ? "https://api.anthropic.com" : "http://localhost:11434"
            onAccepted: assistant.apply({ url: urlField.text })
        }
    }

    // ── La clé (l'API seulement) ─────────────────────────────────
    // Jamais montrée : on en tape une nouvelle, ou on la retire.
    RowLayout {
        Layout.fillWidth: true
        visible: assistant.remote
        spacing: 8
        Label { text: I18n.tr("settings.assistant.key") }
        Field {
            id: keyField
            secret: true
            placeholder: assistant.info && assistant.info.has_key ? I18n.tr("settings.assistant.keySaved")
                                                                   : I18n.tr("settings.assistant.keyPlaceholder")
            onAccepted: {
                if (keyField.text.trim() === "")
                    return;
                assistant.apply({}, keyField.text.trim());
                keyField.text = "";
            }
        }
        GlassButton {
            visible: assistant.info !== null && assistant.info.has_key
            implicitHeight: 30
            text: I18n.tr("settings.assistant.removeKey")
            danger: true
            onClicked: assistant.apply({}, "")
        }
    }

    // ── Le modèle ────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 4
        spacing: 8
        Text {
            Layout.fillWidth: true
            text: I18n.tr("settings.assistant.model")
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.Medium
            color: Theme.textSecondary
        }
        // La liste relue (un modèle tout juste téléchargé).
        GlassButton {
            implicitHeight: 24
            icon: "../assets/icons/refresh.svg"
            opacity: Pilot.pilotConfigLoading ? 0.4 : 1
            onClicked: Pilot.loadPilotConfig()
        }
    }

    // Les modèles du fournisseur, en pastilles ; le choisi s'allume.
    Flow {
        Layout.fillWidth: true
        spacing: 6
        visible: assistant.models.length > 0

        Repeater {
            model: assistant.models

            delegate: Rectangle {
                id: chip
                required property string modelData
                readonly property bool selected: assistant.cfg.model === chip.modelData
                width: chipLabel.implicitWidth + 22
                height: 28
                radius: 14
                color: chip.selected ? Theme.selectedFill
                                     : Qt.alpha(Theme.textPrimary, chipMa.containsMouse || activeFocus ? 0.09 : 0.04)
                border.width: chip.selected ? 0 : 1
                border.color: Theme.dividerColor
                Behavior on color { ColorAnimation { duration: 140 } }

                activeFocusOnTab: true
                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        assistant.apply({ model: chip.modelData });
                        event.accepted = true;
                    }
                }
                FocusRing { radius: chip.radius + gap }

                Text {
                    id: chipLabel
                    anchors.centerIn: parent
                    text: chip.modelData
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.weight: chip.selected ? Font.DemiBold : Font.Medium
                    color: chip.selected ? Theme.textPrimary : Theme.textSecondary
                }
                MouseArea {
                    id: chipMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: assistant.apply({ model: chip.modelData })
                }
            }
        }
    }

    // Pas de liste : pourquoi (Ollama éteint, clé manquante ou refusée…).
    Text {
        Layout.fillWidth: true
        visible: assistant.info !== null && assistant.models.length === 0
        text: assistant.info && assistant.info.error
              ? I18n.tr("settings.assistant.unreachable", { error: assistant.info.error })
              : I18n.tr("settings.assistant.noModels")
        wrapMode: Text.Wrap
        font.family: "Inter"
        font.pixelSize: 10
        color: assistant.info && assistant.info.error ? Theme.colorDanger : Theme.textSecondary
    }

    // Un modèle hors de la liste, par son nom ; il dit aussi le modèle
    // choisi quand la liste ne le montre pas.
    Field {
        id: modelField
        placeholder: assistant.cfg.model !== "" && assistant.models.indexOf(assistant.cfg.model) < 0
                     ? assistant.cfg.model
                     : I18n.tr("settings.assistant.otherModel")
        onAccepted: {
            if (modelField.text.trim() === "")
                return;
            assistant.apply({ model: modelField.text.trim() });
            modelField.text = "";
        }
    }

    // ── Réfléchir ────────────────────────────────────────────────
    Rectangle {
        id: thinkRow
        Layout.fillWidth: true
        Layout.topMargin: 4
        Layout.preferredHeight: 46
        radius: Theme.radius
        color: Qt.alpha(Theme.textPrimary, thinkMa.containsMouse || activeFocus ? 0.09 : 0.05)
        Behavior on color { ColorAnimation { duration: 160 } }

        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                assistant.apply({ think: !assistant.cfg.think });
                event.accepted = true;
            }
        }
        FocusRing { radius: thinkRow.radius + gap }

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: thinkPill.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                text: I18n.tr("settings.assistant.think")
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.Medium
                color: Theme.textPrimary
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: I18n.tr("settings.assistant.think.sub")
                font.family: "Inter"
                font.pixelSize: 10
                color: Theme.textSecondary
                elide: Text.ElideRight
            }
        }

        Rectangle {
            id: thinkPill
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 44; height: 22; radius: 11
            color: assistant.cfg.think ? Theme.accentColor : Theme.accentDark
            Behavior on color { ColorAnimation { duration: 200 } }

            Rectangle {
                width: 16; height: 16; radius: 8
                anchors.verticalCenter: parent.verticalCenter
                x: assistant.cfg.think ? 24 : 4
                color: Theme.iconColor
                Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }
        }

        MouseArea {
            id: thinkMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: assistant.apply({ think: !assistant.cfg.think })
        }
    }

    // Un réglage refusé par anna.
    Text {
        Layout.fillWidth: true
        visible: Pilot.pilotConfigError !== ""
        text: Pilot.pilotConfigError
        wrapMode: Text.Wrap
        font.family: "Inter"
        font.pixelSize: 10
        color: Theme.colorDanger
    }

    // L'adresse suit celle d'anna, sauf pendant qu'on la tape.
    function syncUrl() {
        if (!urlField.editing)
            urlField.text = assistant.info ? assistant.cfg.url : "";
    }
    onCfgChanged: assistant.syncUrl()
}
