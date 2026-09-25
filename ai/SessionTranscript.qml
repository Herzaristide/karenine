pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import "../services"

// Le volet de lecture du mode IA : l'en-tête de la session regardée, ses
// derniers échanges, et de quoi reprendre le fil.
//
// Il ne tient aucun état — tout vient de [ClaudeSessions], qui suit la carte
// au centre du carrousel. Le volet ne fait que le rendre.
Item {
    id: pane

    // Le dock reprend la main au clavier quand on sort du champ de saisie.
    signal escaped()

    readonly property var session: ClaudeSessions.current
    readonly property bool hasSession: pane.session !== null

    function focusComposer() {
        if (composer.enabled)
            composer.forceActiveFocus();
    }

    // Marge intérieure de la plaque : le texte ne colle pas au bord.
    readonly property int inset: 14

    // ── Surface ──────────────────────────────────────────────────
    // Une conversation a besoin d'un fond à elle. Sans plaque, le texte se
    // pose directement sur le fond d'écran à travers le dégradé du dock, et
    // devient illisible dès que le papier peint est clair ou chargé. Déclarée
    // en premier : tout le reste du volet se pose dessus.
    Rectangle {
        id: plate

        anchors.fill: parent
        radius: 16

        color: Theme.darkMode
               ? Qt.rgba(Theme.bgDeep.r, Theme.bgDeep.g, Theme.bgDeep.b, 0.86)
               : Qt.rgba(Theme.bgElevated.r, Theme.bgElevated.g, Theme.bgElevated.b, 0.92)

        border.width: 1
        border.color: Theme.dividerColor
    }

    // ── En-tête ──────────────────────────────────────────────────
    Item {
        id: header

        anchors.top: parent.top
        anchors.topMargin: pane.inset
        anchors.left: parent.left
        anchors.leftMargin: pane.inset
        anchors.right: parent.right
        anchors.rightMargin: pane.inset
        height: 18

        Text {
            id: projectLabel

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, header.width * 0.45)

            text: pane.hasSession ? pane.session.project : ""
            color: Theme.textPrimary
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            elide: Text.ElideMiddle
        }

        Text {
            anchors.left: projectLabel.right
            anchors.leftMargin: 8
            anchors.right: stateLabel.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter

            text: {
                if (!pane.hasSession)
                    return "";
                var bits = [ClaudeSessions.ago(pane.session.at)];
                if (ClaudeSessions.total > 0)
                    bits.push(ClaudeSessions.total + " messages");
                return bits.join("  ·  ");
            }
            color: Theme.textDim
            font.family: "JetBrains Mono"
            font.pixelSize: 9
            elide: Text.ElideRight
        }

        Text {
            id: stateLabel

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            text: ClaudeSessions.streaming ? "en cours…"
                                           : (ClaudeSessions.loading ? "lecture…" : "")
            color: ClaudeSessions.streaming ? Theme.accentColor : Theme.textDim
            font.family: "JetBrains Mono"
            font.pixelSize: 9
            opacity: text.length > 0 ? 1.0 : 0.0

            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
    }

    Rectangle {
        id: rule

        anchors.top: header.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.leftMargin: pane.inset
        anchors.right: parent.right
        anchors.rightMargin: pane.inset
        height: 1
        color: Theme.dividerColor
    }

    // ── Échanges ─────────────────────────────────────────────────
    ListView {
        id: thread

        anchors.top: rule.bottom
        anchors.topMargin: 8
        anchors.bottom: composerPill.top
        anchors.bottomMargin: 8
        anchors.left: parent.left
        anchors.leftMargin: pane.inset
        anchors.right: parent.right
        anchors.rightMargin: pane.inset

        clip: true
        spacing: 6
        model: ClaudeSessions.messages

        // Une conversation se lit par la fin : on y reste collé, sauf si on
        // est remonté soi-même dans l'historique.
        property bool pinnedToEnd: true

        onCountChanged: if (pinnedToEnd) Qt.callLater(positionViewAtEnd)
        onContentHeightChanged: if (pinnedToEnd) Qt.callLater(positionViewAtEnd)
        onDragStarted: pinnedToEnd = false

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (event) => {
                thread.pinnedToEnd = false;
                thread.contentY = Math.max(
                    0,
                    Math.min(Math.max(0, thread.contentHeight - thread.height),
                             thread.contentY - event.angleDelta.y / 120 * 60));
                // Revenu tout en bas : on se ré-accroche.
                if (thread.contentY >= thread.contentHeight - thread.height - 2)
                    thread.pinnedToEnd = true;
            }
        }

        // Changer de session remet la lecture à la fin.
        Connections {
            target: ClaudeSessions
            function onCurrentChanged() { thread.pinnedToEnd = true; }
        }

        delegate: Item {
            id: row

            required property string role
            required property string text

            width: thread.width
            height: bubble.implicitHeight

            readonly property bool isUser: row.role === "user"
            readonly property bool isTool: row.role === "tool"

            Rectangle {
                id: marker

                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: 3
                width: 2
                height: bubble.implicitHeight - 4
                radius: 1
                color: row.isUser ? Theme.accentColor : Theme.colorCoral
                opacity: row.isTool ? 0.0 : (row.isUser ? 0.9 : 0.35)
                visible: opacity > 0.001
            }

            Text {
                id: bubble

                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: parent.right

                text: row.isTool ? "⚙  " + row.text : row.text
                color: row.isTool ? Theme.textDim
                                  : (row.isUser ? Theme.textPrimary : Theme.textBody)
                font.family: "JetBrains Mono"
                font.pixelSize: row.isTool ? 9 : 11
                font.weight: row.isUser ? Font.DemiBold : Font.Normal
                lineHeight: 1.25
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
        }
    }

    // Rien à lire : on le dit, plutôt que d'afficher du vide.
    Text {
        anchors.centerIn: thread
        width: thread.width - 20

        visible: !ClaudeSessions.loading && ClaudeSessions.messages.count === 0
        text: pane.hasSession ? "conversation vide" : "aucune session"
        color: Theme.textDim
        font.family: "JetBrains Mono"
        font.pixelSize: 10
        horizontalAlignment: Text.AlignHCenter
    }

    // ── Reprise ──────────────────────────────────────────────────
    // Écrire ici reprend la session pour de bon : `claude --resume` rouvre le
    // JSONL d'origine, donc la suite s'écrit dans la conversation elle-même.
    Rectangle {
        id: composerPill

        anchors.bottom: parent.bottom
        anchors.bottomMargin: pane.inset
        anchors.left: parent.left
        anchors.leftMargin: pane.inset
        anchors.right: parent.right
        anchors.rightMargin: pane.inset
        height: 28
        radius: height / 2

        color: composer.activeFocus
               ? (Theme.darkMode ? Qt.lighter(Theme.bgElevated, 1.55)
                                 : Qt.darker(Theme.bgElevated, 1.06))
               : Theme.bgElevated
        opacity: composer.enabled ? 1.0 : 0.5

        Behavior on color   { ColorAnimation  { duration: 180 } }
        Behavior on opacity { NumberAnimation { duration: 180 } }

        HoverHandler { cursorShape: Qt.IBeamCursor }
        TapHandler { onTapped: pane.focusComposer() }

        Text {
            id: prompt

            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter

            text: "›"
            color: composer.activeFocus ? Theme.accentColor : Theme.textSecondary
            font.family: "JetBrains Mono"
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }

        TextField {
            id: composer

            anchors.left: prompt.right
            anchors.leftMargin: 8
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter

            enabled: ClaudeSessions.canResume && !ClaudeSessions.streaming
            placeholderText: ClaudeSessions.streaming ? "Claude répond…"
                                                      : "poursuivre la conversation…"
            placeholderTextColor: Theme.placeholderColor
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            color: Theme.textPrimary
            background: Item {}
            leftPadding: 0
            rightPadding: 0

            function submit() {
                var t = composer.text.trim();
                if (t.length === 0)
                    return;
                composer.text = "";
                thread.pinnedToEnd = true;
                ClaudeSessions.send(t);
            }

            Keys.onReturnPressed: composer.submit()
            Keys.onEnterPressed: composer.submit()

            Keys.onEscapePressed: {
                if (composer.text.length > 0)
                    composer.text = "";
                else
                    pane.escaped();
            }
        }
    }
}
