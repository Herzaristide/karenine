pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../services"

// Les demandes qu'anna relaie (services/Prompts.qml) : la passphrase d'une
// clé SSH, un mot de passe git ou sudo, une confirmation, un avis (« touche
// ta clé de sécurité »)… La plus ancienne s'affiche, les suivantes attendent.
//
// Comme PolkitPrompt : le panneau voile l'écran et prend le clavier tant
// qu'une demande est ouverte. Entrée valide (le bouton principal), Échap ou
// un clic sur le voile annule. Les valeurs tapées partent vers anna et sont
// effacées des champs aussitôt.
PanelWindow { // qmllint disable uncreatable-type
    id: host

    // La demande affichée. Elle ne change que si la première de la file
    // change : anna renvoie toute la file à chaque arrivée, et ce qui est en
    // train d'être tapé ne doit pas s'effacer pour autant.
    property var prompt: null
    readonly property bool active: host.prompt !== null

    Connections {
        target: Prompts
        function onCurrentChanged() {
            var cur = Prompts.current;
            if ((cur ? cur.id : "") !== (host.prompt ? host.prompt.id : ""))
                host.prompt = cur;
        }
    }
    Component.onCompleted: host.prompt = Prompts.current

    // Les valeurs des champs de la demande affichée : { clé: valeur }.
    property var values: ({})

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "karenine-prompt"
    WlrLayershell.keyboardFocus: host.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: host.active || card.opacity > 0

    // Le bouton d'Entrée : le principal, sinon le seul.
    readonly property var primaryAction: {
        var acts = host.prompt ? host.prompt.actions : [];
        for (var i = 0; i < acts.length; i++)
            if (acts[i].primary)
                return acts[i];
        return acts.length === 1 ? acts[0] : null;
    }

    function answer(action) {
        if (!host.prompt)
            return;
        Prompts.reply(host.prompt.id, action, host.values);
        host.values = {};
    }

    function cancel() {
        if (host.prompt)
            Prompts.cancel(host.prompt.id);
        host.values = {};
    }

    function accept() {
        if (host.primaryAction)
            host.answer(host.primaryAction.id);
    }

    function setValue(key, value) {
        var v = Object.assign({}, host.values);
        v[key] = value;
        host.values = v;
    }

    // Une nouvelle demande : ses valeurs initiales, et le clavier sur son
    // premier champ (sinon sur le bouton principal).
    onPromptChanged: {
        var v = {};
        if (host.prompt)
            for (var i = 0; i < host.prompt.fields.length; i++)
                v[host.prompt.fields[i].key] = host.prompt.fields[i].value || "";
        host.values = v;
        Qt.callLater(host.focusFirst);
    }

    function focusFirst() {
        if (!host.active)
            return;
        for (var i = 0; i < fieldRepeater.count; i++) {
            var item = fieldRepeater.itemAt(i);
            // Accès par nom : l'élément est un Loader du Repeater.
            if (item && item["takesFocus"]) { // qmllint disable missing-property
                item["takeFocus"](); // qmllint disable missing-property
                return;
            }
        }
        card.forceActiveFocus();
    }

    // Le temps qui reste, affiché dans les trente dernières secondes.
    property double now: Date.now()
    Timer {
        interval: 1000
        repeat: true
        running: host.active
        triggeredOnStart: true
        onTriggered: host.now = Date.now()
    }
    readonly property int secondsLeft: host.prompt ? Math.max(0, Math.round((host.prompt.deadline - host.now) / 1000)) : 0

    // Le voile : un clic à côté annule.
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(Theme.bgDeep, 0.55)
        opacity: card.opacity
        MouseArea {
            anchors.fill: parent
            onClicked: host.cancel()
        }
    }

    // Une demande avec des vignettes (partager l'écran) : une carte large.
    readonly property bool hasTiles: {
        var fs = host.prompt ? host.prompt.fields : [];
        for (var i = 0; i < fs.length; i++)
            if (fs[i].kind === "choice" && (fs[i].options || []).some((o) => !!o.preview))
                return true;
        return false;
    }

    PromptCard {
        id: card
        anchors.centerIn: parent
        width: host.hasTiles ? Math.min(host.width - 80, 880) : 420
        shown: host.active
        title: host.prompt ? host.prompt.title : ""
        source: host.prompt ? host.prompt.source : ""
        text: host.prompt ? host.prompt.text : ""
        detail: host.prompt ? host.prompt.detail : ""
        message: {
            if (!host.prompt)
                return "";
            if (host.prompt.kind === "notice")
                return I18n.tr("prompt.waiting");
            return host.secondsLeft <= 30 ? I18n.tr("prompt.timeLeft").replace("{s}", host.secondsLeft) : "";
        }
        onCancelled: host.cancel()
        Keys.onReturnPressed: host.accept()
        Keys.onEnterPressed: host.accept()

        Repeater {
            id: fieldRepeater
            model: host.prompt ? host.prompt.fields : []

            delegate: Loader {
                id: fieldLoader
                required property var modelData
                Layout.fillWidth: true
                readonly property bool takesFocus: fieldLoader.modelData.kind === "password" || fieldLoader.modelData.kind === "text"
                function takeFocus() {
                    var input = fieldLoader.item ? fieldLoader.item["input"] : null; // qmllint disable missing-property
                    if (input)
                        input.forceActiveFocus();
                }
                sourceComponent: fieldLoader.modelData.kind === "check" ? checkField
                               : fieldLoader.modelData.kind === "choice" && host.hasTiles ? tilesField
                               : fieldLoader.modelData.kind === "choice" ? choiceField
                               : textField
                onLoaded: fieldLoader.item["field"] = fieldLoader.modelData
            }
        }

        buttons: [
            PromptButton {
                label: I18n.tr("common.cancel")
                onClicked: host.cancel()
            },
            Repeater {
                model: host.prompt ? host.prompt.actions : []
                delegate: PromptButton {
                    required property var modelData
                    label: modelData.label
                    primary: modelData.primary
                    danger: modelData.danger
                    onClicked: host.answer(modelData.id)
                }
            }
        ]
    }

    // ── Les champs ───────────────────────────────────────────────────
    Component {
        id: textField
        Rectangle {
            id: box
            property var field: null
            property alias input: input
            implicitHeight: 42
            radius: 8
            color: Theme.bgInput
            border.width: 2
            border.color: input.activeFocus ? Theme.accentColor : Theme.dividerColor
            Behavior on border.color { ColorAnimation { duration: 150 } }

            TextInput {
                id: input
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                verticalAlignment: TextInput.AlignVCenter
                echoMode: box.field && box.field.kind === "password" ? TextInput.Password : TextInput.Normal
                passwordCharacter: "•"
                color: Theme.textPrimary
                selectionColor: Theme.accentColor
                selectedTextColor: Theme.selectedTextColor
                font.family: "JetBrains Mono"
                font.pixelSize: 14
                text: box.field ? box.field.value || "" : ""
                onTextChanged: if (box.field) host.setValue(box.field.key, input.text)
                onAccepted: host.accept()
                Keys.onEscapePressed: host.cancel()

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: input.text === ""
                    text: box.field && box.field.label ? box.field.label
                        : box.field && box.field.kind === "password" ? I18n.tr("auth.password") : ""
                    color: Theme.placeholderColor
                    font: input.font
                }
            }
            // Effacé dès la réponse partie.
            Connections {
                target: host
                function onPromptChanged() { input.text = ""; }
            }
        }
    }

    Component {
        id: checkField
        Rectangle {
            id: check
            property var field: null
            readonly property bool on: check.field ? host.values[check.field.key] === "true" : false
            implicitHeight: 32
            color: "transparent"
            activeFocusOnTab: true
            Keys.onSpacePressed: check.toggle()
            function toggle() {
                if (check.field)
                    host.setValue(check.field.key, check.on ? "false" : "true");
            }
            RowLayout {
                anchors.fill: parent
                spacing: 10
                Rectangle {
                    implicitWidth: 18
                    implicitHeight: 18
                    radius: 4
                    color: check.on ? Theme.accentColor : "transparent"
                    border.width: check.activeFocus ? 2 : 1
                    border.color: check.on ? Theme.accentColor : Theme.dividerColor
                    Text {
                        anchors.centerIn: parent
                        visible: check.on
                        text: "✓"
                        color: Theme.bgDeep
                        font.pixelSize: 12
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: check.field ? check.field.label : ""
                    color: Theme.textPrimary
                    font.family: "Inter"
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: check.toggle()
            }
        }
    }

    // Les vignettes, défilantes au-delà des deux tiers de l'écran. Un double
    // clic, ou Entrée sur une vignette, la choisit et valide.
    Component {
        id: tilesField
        Flickable {
            id: flick
            property var field: null
            implicitHeight: Math.min(tilesBox.implicitHeight, host.height * 0.6)
            contentHeight: tilesBox.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ChoiceTiles {
                id: tilesBox
                width: flick.width
                options: flick.field ? flick.field.options : []
                value: flick.field ? host.values[flick.field.key] || "" : ""
                onPicked: (id) => host.setValue(flick.field.key, id)
                onActivated: (id) => {
                    host.setValue(flick.field.key, id);
                    host.accept();
                }
            }
        }
    }

    Component {
        id: choiceField
        ColumnLayout {
            id: choice
            property var field: null
            spacing: 6
            Text {
                visible: text !== ""
                text: choice.field ? choice.field.label : ""
                color: Theme.textSecondary
                font.family: "Inter"
                font.pixelSize: 11
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: choice.field ? choice.field.options : []
                    delegate: Rectangle {
                        id: chip
                        required property var modelData
                        readonly property bool picked: choice.field !== null && host.values[choice.field.key] === chip.modelData.id
                        implicitWidth: chipText.implicitWidth + 20
                        implicitHeight: 28
                        radius: Theme.radiusSmall
                        color: chip.picked ? Theme.accentColor : (chipMa.containsMouse ? Theme.hoverOverlay : "transparent")
                        border.width: chip.activeFocus ? 2 : 1
                        border.color: chip.picked ? Theme.accentColor : Theme.dividerColor
                        activeFocusOnTab: true
                        Keys.onSpacePressed: host.setValue(choice.field.key, chip.modelData.id)
                        Text {
                            id: chipText
                            anchors.centerIn: parent
                            text: chip.modelData.label
                            color: chip.picked ? Theme.bgDeep : Theme.textPrimary
                            font.family: "Inter"
                            font.pixelSize: 12
                        }
                        MouseArea {
                            id: chipMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: host.setValue(choice.field.key, chip.modelData.id)
                        }
                    }
                }
            }
        }
    }
}
