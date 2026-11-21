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

    PromptCard {
        id: card
        anchors.centerIn: parent
        shown: prompt.active
        failed: prompt.failed
        title: I18n.tr("polkit.title")
        // Ce que l'application demande, dans ses mots.
        text: prompt.flow ? prompt.flow.message : ""
        detail: prompt.flow ? prompt.flow.actionId : ""
        // Le retour de polkit (« Mot de passe incorrect »…).
        message: prompt.flow ? prompt.flow.supplementaryMessage : ""
        messageIsError: prompt.flow !== null && prompt.flow.supplementaryIsError
        onCancelled: prompt.cancel()

        Rectangle {
            Layout.fillWidth: true
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

        buttons: [
            PromptButton {
                label: I18n.tr("common.cancel")
                onClicked: prompt.cancel()
            },
            PromptButton {
                label: I18n.tr("permission.allow")
                primary: true
                onClicked: prompt.submit()
            }
        ]
    }
}
