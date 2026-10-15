pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"

// La bulle d'alerte des sessions Claude Code : elle apparaît en haut à
// droite, quand une session réclame l'utilisateur ou qu'un long tour se
// termine (cf. ClaudeLive.alert, levé par anna). Trois sortes :
//
//   permission — Claude veut lancer un outil : la bulle montre lequel et quoi,
//                et se répond sur place (Autoriser / Toujours / Refuser /
//                Terminal). Elle reste tant que la demande est ouverte ;
//   waiting    — Claude attend autre chose (une question dans le terminal) ;
//   done       — un long tour vient de finir ;
//   pilot      — la confirmation d'une action du pilote, quand le dock IA
//                s'est refermé derrière elle.
//
// Hors permission, un clic amène la fenêtre de la session au premier plan.
// Un clic droit congédie la bulle, sauf une demande de permission : sans
// barre, plus rien ne la rouvrirait. Les bulles repartent seules :
// vite pour « terminé », plus lentement pour une attente, et dès que ce
// qu'elles annonçaient est réglé, d'où qu'on y ait répondu.
//
// Il n'y a pas de serveur de notifications sur cette session : c'est cette
// bulle qui prévient.
PanelWindow { // qmllint disable uncreatable-type
    id: toast

    // L'alerte affichée : { id, project, kind, text }, ou null.
    property var current: null

    // La demande de permission affichée, lue en direct sur la session :
    // { req, tool, summary, always }, ou null.
    readonly property var request: {
        var c = toast.current;
        if (!c || c.kind !== "permission")
            return null;
        var s = ClaudeLive.sessions.find(x => x.id === c.id);
        return s && s.request ? s.request : null;
    }

    readonly property color tint: {
        var k = toast.current ? toast.current.kind : "";
        return k === "done" || k === "pilot" ? Theme.accentColor : Theme.colorAmber;
    }


    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-session-toast"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Dans le coin haut droit de l'écran. Le masque ne rend cliquable que la
    // bulle elle-même.
    anchors { top: true; right: true }
    margins { // qmllint disable unqualified unresolved-type
        top: 8
        right: 8
    }
    exclusiveZone: 0
    color: "transparent"

    implicitWidth: card.width
    implicitHeight: card.height
    visible: toast.current !== null || card.opacity > 0

    mask: Region { // qmllint disable unqualified
        x: card.x
        y: 0
        width: card.width
        height: toast.current ? card.height : 0
    }

    function show(a) {
        toast.current = a;
        // Une demande de permission ne s'efface pas d'elle-même : anna la
        // rend au terminal s'il n'y a pas de réponse.
        if (a.kind === "permission") {
            hideTimer.stop();
            return;
        }
        // Le pilote : le temps de lire sa réponse.
        hideTimer.interval = a.kind === "waiting" ? 15000
                           : a.kind === "pilot" ? Math.min(15000, 4000 + 45 * (a.text || "").length)
                           : 6000;
        hideTimer.restart();
    }

    function dismiss() {
        hideTimer.stop();
        toast.current = null;
    }

    function answer(decision) {
        var r = toast.request;
        var c = toast.current;
        if (!r || !c)
            return;
        ClaudeLive.decide(r.req, decision);
        if (decision === "terminal")
            ClaudeLive.focus(c.id);
        toast.dismiss();
    }

    Connections {
        target: ClaudeLive
        function onAlert(a) { toast.show(a); }
        // Ce que la bulle annonçait est réglé (réponse donnée ailleurs,
        // demande rendue au terminal) : elle s'en va.
        function onSessionsChanged() {
            var c = toast.current;
            if (!c)
                return;
            var s = ClaudeLive.sessions.find(x => x.id === c.id);
            if (c.kind === "permission" && !toast.request)
                toast.dismiss();
            else if (c.kind === "waiting" && (!s || s.state !== "waiting"))
                toast.dismiss();
        }
    }

    Timer {
        id: hideTimer
        onTriggered: toast.current = null
    }

    // Un bouton de réponse : plein pour l'action principale, sinon simple
    // libellé teinté.
    component ActionButton: Rectangle {
        id: btn
        property string label
        property color tint: Theme.textSecondary
        property bool primary: false
        signal activated()

        implicitWidth: btnText.implicitWidth + 18
        implicitHeight: 24
        radius: 12
        color: btn.primary ? btn.tint : (btnMa.containsMouse ? Theme.hoverOverlay : "transparent")
        border.width: btn.primary ? 0 : 1
        border.color: Theme.dividerColor
        scale: btnMa.pressed ? 0.94 : 1.0

        Behavior on scale { NumberAnimation { duration: 120 } }

        Text {
            id: btnText
            anchors.centerIn: parent
            text: btn.label
            font.family: "JetBrains Mono"
            font.pixelSize: 10
            font.weight: btn.primary ? Font.DemiBold : Font.Normal
            color: btn.primary ? Theme.bgDeep : btn.tint
        }

        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
    }

    Rectangle {
        id: card
        width: 360
        height: content.implicitHeight + 20
        x: 0
        radius: 12
        color: Theme.bgDeep
        border.width: 1
        border.color: toast.current && (toast.current.kind === "waiting" || toast.current.kind === "permission")
                      ? Theme.colorAmber : Theme.dividerColor

        opacity: toast.current ? 1.0 : 0.0
        transform: Translate { y: toast.current ? 0 : -12 }
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        // Sous le contenu : les boutons, posés par-dessus, gardent leurs clics.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: toast.request ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: (mouse) => {
                // Une demande ouverte reste : plus rien ne la rouvrirait.
                if (mouse.button === Qt.RightButton) {
                    if (!toast.request)
                        toast.dismiss();
                    return;
                }
                if (toast.request || !toast.current)
                    return;
                // La confirmation du pilote n'a pas de fenêtre derrière elle.
                if (toast.current.kind !== "pilot")
                    ClaudeLive.focus(toast.current.id);
                toast.dismiss();
            }
        }

        Column {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 10
            spacing: 6

            Row {
                spacing: 8

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: toast.tint
                }

                Text {
                    text: {
                        var c = toast.current;
                        if (!c)
                            return "";
                        if (c.kind === "pilot")
                            return "✦ pilote";
                        var what = c.kind === "permission" ? "demande une permission"
                                 : c.kind === "waiting" ? "t'attend" : "terminé";
                        return c.project + "  ·  " + what;
                    }
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: Theme.textPrimary
                }
            }

            // Pilote : ce qui a été demandé (compris, si c'était à la voix).
            Text {
                width: parent.width
                visible: toast.current !== null && toast.current.kind === "pilot"
                         && (toast.current.heard || "").length > 0
                text: toast.current && toast.current.heard ? "« " + toast.current.heard + " »" : ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.family: "JetBrains Mono"
                font.pixelSize: 9
                font.italic: true
                color: Theme.textDim
            }

            // Hors permission : le message, ou la demande qui vient de finir.
            Text {
                width: parent.width
                visible: !toast.request
                text: toast.current ? toast.current.text : ""
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                color: Theme.textSecondary
            }

            // Permission : l'outil, puis ce qu'il ferait, tel quel.
            Rectangle {
                width: parent.width
                visible: toast.request !== null
                height: requestText.implicitHeight + 12
                radius: 6
                color: Theme.bgElevated

                Text {
                    id: requestText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 8
                    textFormat: Text.StyledText
                    text: toast.request
                          ? "<b>" + toast.request.tool + "</b>  "
                            + toast.request.summary.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                          : ""
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Theme.textBody
                }
            }

            Row {
                visible: toast.request !== null
                spacing: 6

                ActionButton {
                    label: "Autoriser"
                    primary: true
                    tint: Theme.accentColor
                    onActivated: toast.answer("allow")
                }
                ActionButton {
                    label: "Toujours"
                    visible: toast.request !== null && toast.request.always !== ""
                    tint: Theme.accentColor
                    onActivated: toast.answer("always")
                }
                ActionButton {
                    label: "Refuser"
                    tint: Theme.colorDanger
                    onActivated: toast.answer("deny")
                }
                ActionButton {
                    label: "Terminal"
                    tint: Theme.textDim
                    onActivated: toast.answer("terminal")
                }
            }

            // Ce que « Toujours » accorderait, dit par Claude Code lui-même.
            Text {
                width: parent.width
                visible: toast.request !== null && toast.request.always !== ""
                text: toast.request ? "toujours : " + toast.request.always : ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.family: "JetBrains Mono"
                font.pixelSize: 9
                color: Theme.textDim
            }
        }
    }
}
