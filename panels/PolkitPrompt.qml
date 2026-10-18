pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Polkit
import "../services"

// L'agent polkit de la session : quand une application demande une action
// système (monter un disque, gérer un service, `pkexec`…), polkit nous
// envoie la demande et c'est ce panneau qui réclame le mot de passe.
//
//   ╭──────────────────────────────────────╮
//   │ Authentification requise             │
//   │ <ce que l'application veut faire>    │
//   │ ┌──────────────────────────────────┐ │
//   │ │ Mot de passe…                    │ │
//   │ └──────────────────────────────────┘ │
//   │                 Annuler  Autoriser   │
//   ╰──────────────────────────────────────╯
//
// Le panneau voile l'écran et prend le clavier tant que la demande est
// ouverte ; Échap ou un clic sur le voile l'annule. Un mauvais mot de passe
// secoue le champ et polkit redemande. Le mot de passe va directement à
// polkit (AuthFlow.submit), rien n'en est gardé.
//
// Un seul agent par session : si un autre (hyprpolkitagent, polkit-gnome…)
// est lancé, l'un des deux échoue à s'enregistrer.
PanelWindow { // qmllint disable uncreatable-type
    id: prompt

    PolkitAgent {
        id: agent
    }

    readonly property var flow: agent.flow // qmllint disable unresolved-type
    readonly property bool active: agent.isActive && prompt.flow !== null

    // Le dernier mot de passe a été refusé : le champ se secoue.
    property bool failed: false

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-polkit"
    WlrLayershell.keyboardFocus: prompt.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: prompt.active || card.opacity > 0

    function submit() {
        if (!prompt.flow || !prompt.flow.isResponseRequired || field.text === "")
            return;
        prompt.failed = false;
        prompt.flow.submit(field.text);
        field.text = "";
    }

    function cancel() {
        if (prompt.flow)
            prompt.flow.cancelAuthenticationRequest();
        field.text = "";
    }

    Connections {
        target: prompt.flow
        function onAuthenticationFailed() {
            prompt.failed = true;
            shake.start();
        }
        function onIsResponseRequiredChanged() {
            if (prompt.flow.isResponseRequired)
                field.forceActiveFocus();
        }
    }

    onActiveChanged: {
        prompt.failed = false;
        field.text = "";
        if (prompt.active)
            field.forceActiveFocus();
    }

    // Le voile : un clic à côté annule.
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(Theme.bgDeep, 0.55)
        opacity: card.opacity
        MouseArea {
            anchors.fill: parent
            onClicked: prompt.cancel()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: 420
        implicitHeight: col.implicitHeight + 40
        radius: 16
        color: Theme.bgDeep
        border.width: 1
        border.color: prompt.failed ? Theme.colorDanger : Theme.dividerColor

        opacity: prompt.active ? 1 : 0
        scale: prompt.active ? 1 : 0.96
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        // Les clics sur la carte ne vont pas au voile.
        MouseArea { anchors.fill: parent }

        Keys.onEscapePressed: prompt.cancel()

        ColumnLayout {
            id: col
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 20
            spacing: 10

            Text {
                text: I18n.tr("polkit.title")
                font.family: "Inter"
                font.pixelSize: 15
                font.weight: Font.DemiBold
                color: Theme.textPrimary
            }

            // Ce que l'application demande, dans ses mots.
            Text {
                Layout.fillWidth: true
                text: prompt.flow ? prompt.flow.message : ""
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textSecondary
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: prompt.flow ? prompt.flow.actionId : ""
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Theme.textDim
                elide: Text.ElideMiddle
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 4
                implicitHeight: 42
                radius: 8
                color: Theme.bgInput
                border.width: 2
                border.color: prompt.failed ? Theme.colorDanger
                            : field.activeFocus ? Theme.accentColor : Theme.dividerColor
                Behavior on border.color { ColorAnimation { duration: 150 } }

                transform: Translate { id: shakeX }
                SequentialAnimation {
                    id: shake
                    loops: 2
                    NumberAnimation { target: shakeX; property: "x"; to: 8; duration: 45 }
                    NumberAnimation { target: shakeX; property: "x"; to: -8; duration: 45 }
                    NumberAnimation { target: shakeX; property: "x"; to: 0; duration: 45 }
                }

                TextInput {
                    id: field
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    // polkit dit si la réponse peut s'afficher (rarement).
                    echoMode: prompt.flow && prompt.flow.responseVisible ? TextInput.Normal : TextInput.Password
                    passwordCharacter: "•"
                    enabled: prompt.flow !== null && prompt.flow.isResponseRequired
                    color: Theme.textPrimary
                    selectionColor: Theme.accentColor
                    selectedTextColor: Theme.selectedTextColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 14
                    onAccepted: prompt.submit()
                    Keys.onEscapePressed: prompt.cancel()

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        // L'invite de PAM (« Password: »), sinon la nôtre.
                        text: {
                            var p = prompt.flow ? prompt.flow.inputPrompt.trim().replace(/:$/, "") : "";
                            return p === "" || p === "Password" ? I18n.tr("auth.password") : p + "…";
                        }
                        color: Theme.placeholderColor
                        font: field.font
                    }
                }

                // polkit vérifie.
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: prompt.flow !== null && !prompt.flow.isResponseRequired
                    text: "…"
                    color: Theme.accentColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 14
                }
            }

            // Le retour de polkit (« Mot de passe incorrect »…).
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: prompt.flow ? prompt.flow.supplementaryMessage : ""
                color: prompt.flow && prompt.flow.supplementaryIsError ? Theme.colorDanger : Theme.textDim
                font.family: "Inter"
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                Layout.topMargin: 4
                spacing: 8

                Button {
                    label: I18n.tr("common.cancel")
                    onClicked: prompt.cancel()
                }
                Button {
                    label: I18n.tr("permission.allow")
                    primary: true
                    onClicked: prompt.submit()
                }
            }
        }
    }

    component Button: Rectangle {
        id: btn
        property string label
        property bool primary: false
        readonly property bool hovered: btnMa.containsMouse || btn.activeFocus
        signal clicked()

        implicitWidth: btnText.implicitWidth + 28
        implicitHeight: 32
        radius: 10
        color: btn.primary ? Theme.accentColor : (btn.hovered ? Theme.hoverOverlay : "transparent")
        border.width: btn.primary ? 0 : 1
        border.color: Theme.dividerColor
        opacity: btnMa.pressed ? 0.8 : 1

        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                btn.clicked();
                event.accepted = true;
            }
        }

        Text {
            id: btnText
            anchors.centerIn: parent
            text: btn.label
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: btn.primary ? Theme.bgDeep : Theme.textPrimary
        }
        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }
}
