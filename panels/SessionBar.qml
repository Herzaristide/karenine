pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"

// La barre des sessions : toujours là, une bande toute noire contre le bord
// gauche de l'écran de l'interface, sur toute la hauteur. Les fenêtres lui
// laissent sa place. En haut ✦, puis une ligne par session Claude Code
// vivante (le pilote n'en a pas : il vit dans la barre de conversation).
//
//   ▌✦ Sessions
//   ▌● karenine·fix-dock   t'attend
//   ▌  Bash  nix build .#anna
//   ▌  [Autoriser] [Toujours] [Refuser]
//   ▌◉ karenine            travaille
//   ▌  corrige le dock…
//   ▌● v4ult
//
// La couleur d'un point dit son état : ambre s'il attend l'utilisateur, la
// teinte de l'accent s'il travaille (il respire), éteint au repos. Une
// session qui demande une permission se valide ici même, d'un bouton, sans
// rien ouvrir d'autre.
//
// Un clic sur une ligne affiche son texte (le dock IA, qui sort à côté) et le
// fait disparaître si c'est déjà elle ; un clic sur ✦ ouvre ou referme le
// dock tout court.
PanelWindow { // qmllint disable uncreatable-type
    id: sbar

    // La session dont le texte est affiché, "" sinon.
    property string openId: ""
    signal picked(string id)
    signal toggled()

    // La largeur de la liste ; le dock se pose juste à côté (AiDock.stripW).
    readonly property int barW: 220
    // L'écart que Hyprland laisse entre la bande et les fenêtres
    // (general:gaps_out) : la bande le couvre aussi, pour que le noir aille
    // jusqu'aux fenêtres et se confonde avec le bord de l'écran.
    readonly property int gap: 12

    // Les sessions qui ont une ligne.
    readonly property var sessions: ClaudeLive.sessions.filter(s => s.id !== "pilote")

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-sessions"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors { left: true; top: true; bottom: true }
    exclusiveZone: sbar.barW
    color: "#000000"
    implicitWidth: sbar.barW + sbar.gap

    function stateColor(s) {
        return s === "waiting" ? Theme.colorAmber
             : s === "working" ? Theme.glow(0)
             : Qt.rgba(1, 1, 1, 0.3);
    }

    function stateLabel(s) {
        return s === "waiting" ? "t'attend"
             : s === "working" ? "travaille"
             : "";
    }

    function sessionLabel(s) {
        return s.worktree ? s.project + "·" + s.worktree.name.replace(/-[0-9a-f]{4}$/, "") : s.project;
    }

    // Un bouton de réponse à une permission : plein pour l'action
    // principale, sinon un simple contour.
    component Answer: Rectangle {
        id: ans
        property string label
        property color tint: "#ffffff"
        property bool primary: false
        signal activated()

        implicitWidth: ansText.implicitWidth + 16
        implicitHeight: 22
        radius: height / 2
        color: ans.primary ? ans.tint : (ansMa.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent")
        border.width: ans.primary ? 0 : 1
        border.color: Qt.rgba(1, 1, 1, 0.2)
        scale: ansMa.pressed ? 0.92 : 1.0
        Behavior on scale { SpringAnimation { spring: 5; damping: 0.28; epsilon: 0.002 } }

        Text {
            id: ansText
            anchors.centerIn: parent
            text: ans.label
            font.family: "JetBrains Mono"
            font.pixelSize: 10
            font.weight: ans.primary ? Font.DemiBold : Font.Normal
            color: ans.primary ? "#ffffff" : ans.tint
        }

        MouseArea {
            id: ansMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ans.activated()
        }
    }

    // ── ✦ : le dock tout court ───────────────────────────────────
    Rectangle {
        id: head
        x: 6
        y: 8
        width: sbar.barW - 12
        height: 32
        radius: height / 2
        color: starMa.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent"

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "✦"
                font.pixelSize: 14
                color: starMa.containsMouse ? Theme.glow(0) : Qt.rgba(1, 1, 1, 0.7)
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Sessions"
                font.family: "Inter"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: Qt.rgba(1, 1, 1, 0.85)
            }
        }

        MouseArea {
            id: starMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sbar.toggled()
        }
    }

    // ── Les sessions ─────────────────────────────────────────────
    ListView {
        id: list
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        x: 6
        width: sbar.barW - 12
        clip: true
        spacing: 4
        boundsBehavior: Flickable.StopAtBounds
        model: sbar.sessions

        delegate: Rectangle {
            id: row
            required property var modelData
            // Lue en direct : l'état et la demande changent sous nos yeux.
            readonly property var request: row.modelData.request || null
            readonly property bool current: sbar.openId === row.modelData.id
            readonly property color tone: sbar.stateColor(row.modelData.state)
            readonly property string detail: ((row.modelData.state === "waiting" && row.modelData.message)
                                              || row.modelData.prompt || "").replace(/\s+/g, " ")

            width: list.width
            height: col.implicitHeight + 16
            radius: 14
            color: row.current ? Qt.alpha(Theme.glow(0), 0.25)
                   : row.request ? Qt.alpha(Theme.colorAmber, 0.1)
                   : (rowMa.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent")
            Behavior on color { ColorAnimation { duration: 140 } }

            // Toute la ligne ouvre son texte ; les boutons, posés dessus,
            // répondent sans l'ouvrir.
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sbar.picked(row.modelData.id)
            }

            Column {
                id: col
                x: 12
                y: 8
                width: row.width - 24
                spacing: 4

                Row {
                    width: parent.width
                    spacing: 8

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8
                        height: 8

                        // Le halo d'une session qui attend : il s'élargit et s'efface.
                        Rectangle {
                            id: ping
                            anchors.fill: parent
                            radius: width / 2
                            color: row.tone
                            opacity: 0
                            visible: row.modelData.state === "waiting"

                            ParallelAnimation {
                                running: ping.visible
                                loops: Animation.Infinite
                                NumberAnimation { target: ping; property: "scale"; from: 1; to: 2.4; duration: 1400; easing.type: Easing.OutCubic }
                                NumberAnimation { target: ping; property: "opacity"; from: 0.5; to: 0; duration: 1400; easing.type: Easing.OutCubic }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: row.tone
                            Behavior on color { ColorAnimation { duration: 260 } }

                            // Une session au travail respire.
                            SequentialAnimation on opacity {
                                running: row.modelData.state === "working"
                                loops: Animation.Infinite
                                alwaysRunToEnd: true
                                NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
                            }
                        }
                    }

                    Text {
                        width: parent.width - 16 - (stateText.visible ? stateText.implicitWidth + 8 : 0)
                        text: sbar.sessionLabel(row.modelData)
                        elide: Text.ElideRight
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: "#ffffff"
                    }

                    Text {
                        id: stateText
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text.length > 0
                        text: sbar.stateLabel(row.modelData.state)
                        font.family: "JetBrains Mono"
                        font.pixelSize: 9
                        color: row.tone
                    }
                }

                // Hors permission : ce qu'elle attend, ou sa demande.
                Text {
                    width: parent.width
                    leftPadding: 16
                    visible: !row.request && row.detail.length > 0
                    text: row.detail
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.family: "JetBrains Mono"
                    font.pixelSize: 9
                    color: Qt.rgba(1, 1, 1, 0.45)
                }

                // Permission : l'outil, ce qu'il ferait, et la réponse.
                Text {
                    width: parent.width
                    leftPadding: 16
                    visible: row.request !== null
                    textFormat: Text.StyledText
                    text: row.request
                          ? "<b>" + row.request.tool + "</b>  "
                            + row.request.summary.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                          : ""
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Qt.rgba(1, 1, 1, 0.8)
                }

                Flow {
                    width: parent.width
                    leftPadding: 16
                    visible: row.request !== null
                    spacing: 5

                    Answer {
                        label: "Autoriser"
                        primary: true
                        tint: Theme.glow(0)
                        onActivated: ClaudeLive.decide(row.request.req, "allow")
                    }
                    Answer {
                        visible: row.request !== null && row.request.always !== ""
                        label: "Toujours"
                        tint: Theme.glow(0)
                        onActivated: ClaudeLive.decide(row.request.req, "always")
                    }
                    Answer {
                        label: "Refuser"
                        tint: Theme.colorDanger
                        onActivated: ClaudeLive.decide(row.request.req, "deny")
                    }
                }
            }
        }

        Text {
            width: list.width
            visible: list.count === 0
            topPadding: 6
            leftPadding: 12
            text: "Aucune session en cours."
            font.family: "Inter"
            font.pixelSize: 11
            color: Qt.rgba(1, 1, 1, 0.35)
        }
    }
}
