pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell.Io
import "../services"
import "../widgets"

// Le module central commun au lockscreen et au greeter : une seule carte qui
// porte toutes les infos — machine, heure, utilisateur, saisie, état PAM —
// puis les sections propres à chaque écran (musique et stats pour le lock,
// session et alimentation pour le greeter), posées en enfants.
//
// Purement présentation : l'authentification vit dans lock.qml / greeter.qml,
// la carte émet `submitted(user, secret)` et affiche l'état qu'on lui repasse.
Item {
    id: card

    required property string userName
    required property string message
    required property bool messageIsError
    required property bool busy

    // Sous le nom : « Session verrouillée », « Hyprland »…
    property string subtitle: ""
    // Le greeter laisse changer d'utilisateur ; le lock, jamais.
    property bool userEditable: false
    // Invite PAM courante (un second facteur remplace « Mot de passe… »).
    property string prompt: I18n.tr("auth.password")
    property bool echoInput: false

    // Sections supplémentaires, empilées sous la saisie.
    default property alias sections: sectionColumn.data

    readonly property int pad: 28

    signal submitted(user: string, secret: string)
    // Une frappe dans le champ : sert au fond pour reprendre la vidéo.
    signal activity()

    function clearPassword(): void {
        passwordField.clear();
    }

    function focusPassword(): void {
        passwordField.focusInput();
    }

    implicitWidth: 440
    implicitHeight: content.implicitHeight + pad * 2

    onMessageIsErrorChanged: {
        if (card.messageIsError)
            passwordField.shake();
    }

    // Entrée : fondu + légère montée.
    opacity: 0
    transform: Translate { id: rise; y: 18 }
    Component.onCompleted: entrance.start()

    ParallelAnimation {
        id: entrance
        NumberAnimation { target: card; property: "opacity"; to: 1; duration: 320; easing.type: Easing.OutCubic }
        NumberAnimation { target: rise; property: "y"; to: 0; duration: 420; easing.type: Easing.OutCubic }
    }

    // Nom de la machine pour l'en-tête.
    FileView {
        id: hostFile
        path: "/etc/hostname"
        printErrors: false
    }
    readonly property string hostName: hostFile.loaded ? hostFile.text().trim() : ""

    Rectangle {
        id: plate

        anchors.fill: parent
        radius: 18
        color: Qt.alpha(Theme.bgDeep, 0.94)
        border.width: 1
        border.color: Theme.dividerColor
        visible: false
    }

    MultiEffect {
        anchors.fill: plate
        source: plate
        shadowEnabled: true
        shadowColor: "#000000"
        shadowOpacity: 0.55
        shadowBlur: 1.0
        shadowVerticalOffset: 12
        autoPaddingEnabled: true
    }

    ColumnLayout {
        id: content

        anchors.fill: parent
        anchors.margins: card.pad
        spacing: 20

        // ── En-tête : machine à gauche, batterie à droite ─────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            NixIcon {
                source: "../assets/nixos.svg"
                iconSize: 14
                color: Theme.accentMuted
            }

            Text {
                Layout.fillWidth: true
                text: card.hostName.toUpperCase()
                color: Theme.accentMuted
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 1.5
                elide: Text.ElideRight
            }

            Text {
                visible: Battery.present
                text: Battery.percent + " %" + (Battery.status === "Charging" ? " ⚡" : "")
                color: Battery.percent <= 15 && Battery.status !== "Charging" ? Theme.colorDanger : Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 1.5
            }
        }

        AuthClock {
            Layout.alignment: Qt.AlignHCenter
        }

        CardRule {}

        // ── Utilisateur ───────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 14

            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: 21
                color: Qt.alpha(Theme.accentColor, 0.16)
                border.width: 1
                border.color: Qt.alpha(Theme.accentColor, 0.45)

                Text {
                    anchors.centerIn: parent
                    text: (userInput.text.charAt(0) || "?").toUpperCase()
                    color: Theme.accentColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 18
                    font.weight: Font.Medium
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                TextInput {
                    id: userInput

                    Layout.fillWidth: true
                    text: card.userName
                    readOnly: !card.userEditable || card.busy
                    activeFocusOnTab: card.userEditable
                    selectByMouse: card.userEditable
                    clip: true
                    color: Theme.textPrimary
                    selectionColor: Theme.accentColor
                    selectedTextColor: Theme.selectedTextColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 16

                    // Entrée ou Tab dans le nom : on passe au mot de passe.
                    onAccepted: passwordField.focusInput()
                    Keys.onTabPressed: passwordField.focusInput()

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.bottom
                        anchors.topMargin: 1
                        height: 1
                        color: Theme.accentColor
                        visible: userInput.activeFocus
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: card.subtitle
                    color: Theme.textDim
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
        }

        // ── Saisie + état PAM ─────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8

            PasswordField {
                id: passwordField

                Layout.fillWidth: true
                busy: card.busy
                error: card.messageIsError
                echo: card.echoInput
                placeholder: card.prompt
                backtabTarget: card.userEditable ? userInput : null

                onTextChanged: card.activity()

                onSubmitted: (secret) => {
                    const user = userInput.text.trim();
                    if (user.length > 0)
                        card.submitted(user, secret);
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                horizontalAlignment: Text.AlignHCenter
                text: card.message
                elide: Text.ElideRight
                color: card.messageIsError ? Theme.colorDanger : Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 12
            }
        }

        // ── Sections propres à l'écran ────────────────────────────────────
        ColumnLayout {
            id: sectionColumn

            Layout.fillWidth: true
            spacing: 18
            visible: children.length > 0
        }
    }
}
