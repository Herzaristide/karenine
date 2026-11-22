pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"
import "../widgets"

// Le module central commun au lockscreen et au greeter, dans la langue du
// shell (Ajar : aplats opaques, Inter, coins à 14 px) :
//
//       ❄ MACHINE                     87 %     ← en-tête, petites capitales
//                   14:32                       ← l'heure, posée sur le fond
//             Samedi 22 novembre
//     ╭─────────────────────────────────────╮
//     │  (A)  aristide                      │  ← la carte : un ton au-dessus
//     │       Session verrouillée           │    du fond (bgElevated)
//     │  ┌───────────────────────────── → ┐ │
//     │  └────────────────────────────────┘ │  ← le champ, creusé (bgDeep)
//     │              message PAM            │
//     ├─────────────────────────────────────┤
//     │  sections propres à l'écran         │  ← musique et stats (lock),
//     ╰─────────────────────────────────────╯    session et alimentation (greeter)
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

    readonly property int pad: 24

    signal submitted(user: string, secret: string)
    // Une frappe dans le champ : sert au fond pour reprendre la vidéo.
    signal activity()

    function clearPassword(): void {
        passwordField.clear();
    }

    function focusPassword(): void {
        passwordField.focusInput();
    }

    implicitWidth: 420
    implicitHeight: layout.implicitHeight

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

    // Petites capitales espacées, comme les titres de section du shell
    // (widgets/SectionTitle).
    component Caps: Text {
        font.family: "Inter"
        font.pixelSize: 10
        font.weight: Font.DemiBold
        font.letterSpacing: 1.2
        font.capitalization: Font.AllUppercase
        font.features: { "tnum": 1 }
        color: Theme.textDim
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    ColumnLayout {
        id: layout

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        // ── En-tête : machine à gauche, batterie à droite ─────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            spacing: 8

            NixIcon {
                source: "../assets/nixos.svg"
                iconSize: 13
                color: Theme.accentColor
            }

            Caps {
                Layout.fillWidth: true
                text: card.hostName
            }

            NixIcon {
                visible: Battery.present && Battery.status === "Charging"
                source: "../assets/icons/bolt.svg"
                iconSize: 10
                color: Theme.textDim
            }

            Caps {
                visible: Battery.present
                text: Battery.percent + " %"
                color: Battery.percent <= 15 && Battery.status !== "Charging" ? Theme.colorDanger : Theme.textDim
            }
        }

        AuthClock {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 18
            Layout.bottomMargin: 32
        }

        // ── La carte ──────────────────────────────────────────────────────
        Rectangle {
            id: plate

            Layout.fillWidth: true
            implicitHeight: content.implicitHeight + card.pad * 2
            radius: Theme.radius
            color: Theme.bgElevated

            ColumnLayout {
                id: content

                anchors.fill: parent
                anchors.margins: card.pad
                spacing: 18

                // ── Utilisateur ───────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    Rectangle {
                        Layout.preferredWidth: 44
                        Layout.preferredHeight: 44
                        radius: 22
                        color: Theme.selectedFill

                        Text {
                            anchors.centerIn: parent
                            text: (userInput.text.charAt(0) || "?").toUpperCase()
                            color: Theme.accentColor
                            font.family: "Inter Display"
                            font.pixelSize: 20
                            font.weight: Font.Medium
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

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
                            font.family: "Inter"
                            font.pixelSize: 16
                            font.weight: Font.DemiBold

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
                            font.family: "Inter"
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }
                }

                // ── Saisie + état PAM ─────────────────────────────────────
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
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: card.messageIsError ? Font.Medium : Font.Normal
                    }
                }

                // ── Sections propres à l'écran ────────────────────────────
                ColumnLayout {
                    id: sectionColumn

                    Layout.fillWidth: true
                    spacing: 16
                    visible: children.length > 0
                }
            }
        }
    }
}
