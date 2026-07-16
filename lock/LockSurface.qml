pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Visuel du lockscreen. Purement présentation : l'authentification vit dans
// lock.qml, cette surface se contente d'émettre `submitted(password)` et
// d'afficher l'état que le parent lui repasse.
Item {
    id: surface

    // Pilotés par lock.qml
    required property string message
    required property bool messageIsError
    required property bool busy
    required property string userName

    // Le bandeau musique/stats n'est monté que sur l'écran primaire :
    // WlSessionLock instancie une surface par moniteur, et chaque LockStats
    // ouvrirait sinon son propre abonnement au socket anna.
    required property bool showWidgets

    signal submitted(password: string)

    // Vidé par lock.qml après chaque tentative.
    function clearPassword(): void {
        passwordInput.text = "";
    }

    function focusPassword(): void {
        passwordInput.forceActiveFocus();
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bgDeep
    }

    // ── Bloc central : horloge, salutation, mot de passe ──────────────────
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 28

        LockClock {
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Bonjour, " + surface.userName + "."
            color: Theme.textSecondary
            font.family: "JetBrains Mono"
            font.pixelSize: 16
        }

        // Champ mot de passe
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 340
            Layout.preferredHeight: 52

            radius: 8
            color: Theme.bgInput
            border.width: 2
            border.color: surface.messageIsError ? Theme.colorDanger : (passwordInput.activeFocus ? Theme.accentColor : Theme.dividerColor)

            Behavior on border.color {
                ColorAnimation {
                    duration: 150
                }
            }

            // Secousse sur échec d'authentification.
            SequentialAnimation {
                id: shake
                loops: 2
                NumberAnimation {
                    target: shakeTransform
                    property: "x"
                    to: 8
                    duration: 45
                }
                NumberAnimation {
                    target: shakeTransform
                    property: "x"
                    to: -8
                    duration: 45
                }
                NumberAnimation {
                    target: shakeTransform
                    property: "x"
                    to: 0
                    duration: 45
                }
            }

            transform: Translate {
                id: shakeTransform
            }

            Connections {
                target: surface
                function onMessageIsErrorChanged(): void {
                    if (surface.messageIsError)
                        shake.start();
                }
            }

            TextInput {
                id: passwordInput

                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16

                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                passwordCharacter: "•"
                enabled: !surface.busy

                color: Theme.textPrimary
                selectionColor: Theme.accentColor
                selectedTextColor: Theme.selectedTextColor
                font.family: "JetBrains Mono"
                font.pixelSize: 15

                onAccepted: {
                    if (!surface.busy && text.length > 0)
                        surface.submitted(text);
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Mot de passe…"
                    color: Theme.placeholderColor
                    font: passwordInput.font
                    visible: passwordInput.text.length === 0 && !surface.busy
                }
            }

            // Indicateur d'authentification en cours.
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: "…"
                color: Theme.accentColor
                font.family: "JetBrains Mono"
                font.pixelSize: 15
                visible: surface.busy
            }
        }

        // Message PAM (« Mauvais mot de passe », etc.)
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 18
            text: surface.message
            color: surface.messageIsError ? Theme.colorDanger : Theme.textDim
            font.family: "JetBrains Mono"
            font.pixelSize: 12
        }
    }

    // ── Bandeau bas : musique à gauche, stats à droite ────────────────────
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 36
        height: 56
        visible: surface.showWidgets

        LockMusic {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }

        LockStats {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
