pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"

// La barre des sessions : toujours là, une bande toute noire contre le bord
// gauche de l'écran de l'interface, sur toute la hauteur. En haut, ✦ puis un
// point par session Claude Code vivante (le pilote n'en a pas : il vit dans
// la barre de conversation).
//
//   ▌✦
//   ▌●  karenine·fix-dock · travaille     (au survol)
//   ▌◉
//   ▌●
//   ▌
//
// La couleur d'un point dit son état : ambre s'il attend l'utilisateur, la
// teinte de l'accent s'il travaille (il respire), éteint au repos. Le point
// de la session ouverte dans le dock porte un anneau.
//
// Un clic sur un point ouvre le dock IA sur cette session (et le referme si
// c'est déjà elle) ; un clic sur ✦ ouvre ou referme le dock tout court. Une
// session qui attend une permission rouvre aussi sa bulle.
PanelWindow { // qmllint disable uncreatable-type
    id: sbar

    // La session affichée par le dock, "" s'il est fermé.
    property string openId: ""
    signal picked(string id)
    signal toggled()

    // La largeur réservée aux points ; le dock se pose juste à côté (AiDock).
    readonly property int barW: 28
    // L'écart que Hyprland laisse entre la bande et les fenêtres
    // (general:gaps_out) : la bande le couvre aussi, pour que le noir aille
    // jusqu'aux fenêtres et se confonde avec le bord de l'écran.
    readonly property int gap: 12
    readonly property int dotSize: 9
    readonly property int dotGap: 16

    // Les sessions qui ont un point.
    readonly property var sessions: ClaudeLive.sessions.filter(s => s.id !== "pilote")

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-sessions"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors { left: true; top: true; bottom: true }
    // Toujours là : les fenêtres lui laissent sa place, au lieu de passer
    // dessous (l'étiquette du survol, elle, passe par-dessus).
    exclusiveZone: sbar.barW
    color: "transparent"

    // De la place à droite de la bande pour l'étiquette du survol ; seule
    // la bande reçoit la souris.
    implicitWidth: sbar.barW + sbar.gap + 320

    mask: Region { item: strip } // qmllint disable unqualified

    function stateColor(s) {
        return s === "waiting" ? Theme.colorAmber
             : s === "working" ? Theme.glow(0)
             : Qt.rgba(1, 1, 1, 0.3);
    }

    function stateLabel(s) {
        return s === "waiting" ? "t'attend"
             : s === "working" ? "travaille"
             : "au repos";
    }

    function sessionLabel(s) {
        return s.worktree ? s.project + "·" + s.worktree.name.replace(/-[0-9a-f]{4}$/, "") : s.project;
    }

    // La session survolée, pour l'étiquette, et la hauteur de son point.
    property var hovered: null
    property real hoveredY: 0

    // ── La bande ─────────────────────────────────────────────────
    Rectangle {
        id: strip
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: sbar.barW + sbar.gap
        color: "#000000"

        Column {
            id: column
            anchors.top: parent.top
            anchors.topMargin: 12
            anchors.left: parent.left
            width: sbar.barW
            spacing: sbar.dotGap

            // ✦ : le dock tout court.
            Text {
                id: star
                anchors.horizontalCenter: parent.horizontalCenter
                text: "✦"
                font.pixelSize: 14
                color: starMa.containsMouse ? Theme.glow(0) : Qt.rgba(1, 1, 1, 0.7)
                scale: starMa.pressed ? 0.85 : (starMa.containsMouse ? 1.15 : 1)
                Behavior on scale { SpringAnimation { spring: 5; damping: 0.3; epsilon: 0.002 } }
                Behavior on color { ColorAnimation { duration: 160 } }

                MouseArea {
                    id: starMa
                    anchors.fill: parent
                    anchors.margins: -7
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sbar.toggled()
                }
            }

            Repeater {
                model: sbar.sessions

                Item {
                    id: dot
                    required property var modelData
                    readonly property bool current: sbar.openId === dot.modelData.id
                    readonly property color tone: sbar.stateColor(dot.modelData.state)
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: sbar.dotSize
                    height: sbar.dotSize

                    // L'anneau de la session ouverte dans le dock.
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width + 7
                        height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: 1.5
                        border.color: dot.tone
                        opacity: dot.current ? 0.9 : 0
                        Behavior on opacity { NumberAnimation { duration: 160 } }
                    }

                    // Le halo d'une session qui attend : il s'élargit et s'efface.
                    Rectangle {
                        id: ping
                        anchors.centerIn: parent
                        width: parent.width
                        height: width
                        radius: width / 2
                        color: dot.tone
                        opacity: 0
                        visible: dot.modelData.state === "waiting"

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
                        color: dot.tone
                        Behavior on color { ColorAnimation { duration: 260 } }
                        scale: dotMa.pressed ? 0.8 : (dotMa.containsMouse ? 1.3 : 1)
                        Behavior on scale { SpringAnimation { spring: 5; damping: 0.3; epsilon: 0.002 } }

                        // Une session au travail respire.
                        SequentialAnimation on opacity {
                            running: dot.modelData.state === "working"
                            loops: Animation.Infinite
                            alwaysRunToEnd: true
                            NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
                        }
                    }

                    MouseArea {
                        id: dotMa
                        anchors.fill: parent
                        anchors.margins: -(sbar.dotGap / 2)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: {
                            if (containsMouse) {
                                sbar.hovered = dot.modelData;
                                sbar.hoveredY = dot.mapToItem(strip, 0, dot.height / 2).y;
                            } else if (sbar.hovered && sbar.hovered.id === dot.modelData.id)
                                sbar.hovered = null;
                        }
                        onClicked: {
                            if (dot.modelData.request)
                                ClaudeLive.reopen(dot.modelData.id);
                            sbar.picked(dot.modelData.id);
                        }
                    }
                }
            }
        }
    }

    // ── L'étiquette du survol ────────────────────────────────────
    // Le nom de la session et son état, à droite de son point. Lue en
    // direct : l'état peut changer pendant qu'on survole.
    Rectangle {
        id: label
        readonly property var session: sbar.hovered ? ClaudeLive.find(sbar.hovered.id) : null
        x: sbar.barW + sbar.gap + 6
        y: sbar.hoveredY - height / 2
        width: labelText.implicitWidth + 22
        height: 24
        radius: height / 2
        color: "#000000"

        opacity: label.session && sbar.openId !== label.session.id ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        Text {
            id: labelText
            anchors.centerIn: parent
            textFormat: Text.StyledText
            text: label.session
                  ? sbar.sessionLabel(label.session) + "  <font color=\""
                    + (label.session.state === "idle" ? "#9a9a9a" : sbar.stateColor(label.session.state))
                    + "\">· " + sbar.stateLabel(label.session.state) + "</font>"
                  : ""
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: "#ffffff"
        }
    }
}
