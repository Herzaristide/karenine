pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Champ de saisie de la carte d'authentification : mot de passe masqué par
// défaut, flèche d'envoi à droite, points animés pendant que PAM réfléchit,
// et une secousse sur échec (`shake()`).
Rectangle {
    id: field

    property bool busy: false
    property bool error: false
    // Une invite PAM peut demander une réponse en clair (code 2FA…).
    property bool echo: false
    property string placeholder: I18n.tr("auth.password")
    // Où renvoyer Maj+Tab (le champ utilisateur du greeter).
    property Item backtabTarget: null

    readonly property alias text: input.text

    signal submitted(text: string)

    function clear(): void {
        input.text = "";
    }

    function focusInput(): void {
        input.forceActiveFocus();
    }

    function shake(): void {
        shakeAnim.restart();
    }

    function submit(): void {
        if (!field.busy && input.text.length > 0)
            field.submitted(input.text);
    }

    implicitHeight: 48
    radius: 10
    color: Theme.bgInput
    border.width: 1.5
    border.color: field.error ? Theme.colorDanger : (input.activeFocus ? Theme.accentColor : Theme.dividerColor)

    Behavior on border.color {
        ColorAnimation { duration: 150 }
    }

    transform: Translate { id: shakeTransform }

    SequentialAnimation {
        id: shakeAnim
        loops: 2
        NumberAnimation { target: shakeTransform; property: "x"; to: 8; duration: 45 }
        NumberAnimation { target: shakeTransform; property: "x"; to: -8; duration: 45 }
        NumberAnimation { target: shakeTransform; property: "x"; to: 0; duration: 45 }
    }

    TextInput {
        id: input

        anchors.left: parent.left
        anchors.right: sendButton.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: 16
        anchors.rightMargin: 8

        verticalAlignment: TextInput.AlignVCenter
        echoMode: field.echo ? TextInput.Normal : TextInput.Password
        passwordCharacter: "•"
        enabled: !field.busy
        clip: true

        color: Theme.textPrimary
        selectionColor: Theme.accentColor
        selectedTextColor: Theme.selectedTextColor
        font.family: "JetBrains Mono"
        font.pixelSize: 15

        onAccepted: field.submit()
        Keys.onBacktabPressed: {
            if (field.backtabTarget)
                field.backtabTarget.forceActiveFocus();
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: field.placeholder
            elide: Text.ElideRight
            color: Theme.placeholderColor
            font: input.font
            visible: input.text.length === 0 && !field.busy
        }
    }

    // Envoi au clic, ou points animés pendant l'authentification.
    Rectangle {
        id: sendButton

        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 32
        height: 32
        radius: 8

        readonly property bool armed: input.text.length > 0 && !field.busy

        color: sendButton.armed ? Qt.alpha(Theme.accentColor, sendMouse.containsMouse ? 0.32 : 0.20) : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
            anchors.centerIn: parent
            visible: !field.busy
            text: "→"
            color: sendButton.armed ? Theme.accentColor : Theme.textDim
            font.family: "JetBrains Mono"
            font.pixelSize: 16
        }

        Row {
            anchors.centerIn: parent
            spacing: 4
            visible: field.busy

            Repeater {
                model: 3

                Rectangle {
                    id: dot

                    required property int index

                    width: 5
                    height: 5
                    radius: 2.5
                    color: Theme.accentColor
                    opacity: 0.25

                    SequentialAnimation on opacity {
                        running: field.busy
                        loops: Animation.Infinite
                        PauseAnimation { duration: dot.index * 140 }
                        NumberAnimation { to: 1; duration: 260 }
                        NumberAnimation { to: 0.25; duration: 260 }
                        PauseAnimation { duration: (2 - dot.index) * 140 }
                    }
                }
            }
        }

        MouseArea {
            id: sendMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: sendButton.armed ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: field.submit()
        }
    }
}
