pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../auth"
import "../services"

// Visuel du greeter : même fond et même carte que le lockscreen, avec le
// choix de l'utilisateur ouvert, et en pied la session lancée et les boutons
// d'alimentation.
//
// Purement présentation : l'échange avec greetd vit dans greeter.qml.
Item {
    id: surface

    required property string userName
    required property string sessionName
    required property string message
    required property bool messageIsError
    required property bool busy
    property string prompt: "Mot de passe…"
    property bool echoInput: false

    signal submitted(user: string, secret: string)

    function clearPassword(): void {
        card.clearPassword();
    }

    function focusPassword(): void {
        card.focusPassword();
    }

    AuthBackdrop {
        seeThrough: true
        anchors.fill: parent
    }

    AuthCard {
        id: card

        anchors.centerIn: parent

        userName: surface.userName
        userEditable: true
        subtitle: "Ouvrir une session"
        message: surface.message
        messageIsError: surface.messageIsError
        busy: surface.busy
        prompt: surface.prompt
        echoInput: surface.echoInput

        onSubmitted: (user, secret) => surface.submitted(user, secret)

        CardRule {}

        // ── Pied : session à gauche, alimentation à droite ────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                Layout.fillWidth: true
                text: surface.sessionName.toUpperCase()
                color: Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 1.5
                elide: Text.ElideRight
            }

            PowerButton {
                label: "Redémarrer"
                onActivated: power.run(["systemctl", "reboot"])
            }

            PowerButton {
                label: "Éteindre"
                danger: true
                onActivated: power.run(["systemctl", "poweroff"])
            }
        }
    }

    // logind accepte reboot/poweroff depuis la session active du greeter
    // (polkit `allow_active`), sans authentification.
    Process {
        id: power

        function run(cmd: list<string>): void {
            power.command = cmd;
            power.running = true;
        }
    }

    component PowerButton: Rectangle {
        id: button

        required property string label
        property bool danger: false

        signal activated

        readonly property bool lit: mouse.containsMouse || button.activeFocus
        readonly property color tone: button.danger ? Theme.colorDanger : Theme.accentColor

        implicitWidth: caption.implicitWidth + 22
        implicitHeight: 28
        radius: 8
        color: button.lit ? Qt.alpha(button.tone, 0.18) : "transparent"
        border.width: 1
        border.color: button.lit ? Qt.alpha(button.tone, 0.6) : Theme.dividerColor

        Behavior on color { ColorAnimation { duration: 120 } }

        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                button.activated();
                event.accepted = true;
            }
        }

        Text {
            id: caption
            anchors.centerIn: parent
            text: button.label
            color: button.lit ? button.tone : Theme.textSecondary
            font.family: "JetBrains Mono"
            font.pixelSize: 11
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.activated()
        }
    }
}
