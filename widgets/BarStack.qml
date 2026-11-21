pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Une colonne d'actions au-dessus d'un bouton de la barre du bas
// (panels/Bar.qml) : elle sort de la barre comme les volets (Lip, mêmes
// coins creusés, même encre), sans titre — juste des boutons de la barre,
// qui y montent l'un après l'autre. À la fermeture, ils redescendent dans
// l'ordre inverse et la colonne rentre dans la barre. Un message éventuel
// s'écrit au-dessus d'eux (la colonne s'élargit pour lui).
//
//        ╭────╮
//        │ ⏻  │   ← le dernier de `actions`
//        │ ⟳  │
//        │ 🔒 │   ← le premier
//   ━━━━━╯ ⏻  ╰━━━━━  la barre
//
// Le téléphone (PhonePop) et l'alimentation (PowerStack) s'en servent.
Item {
    id: root

    // Les boutons sont sortis.
    property bool shown: false
    // Ce qui monte, de bas en haut : { name, glyph, success? }. `success`
    // teinte l'icône en vert (accepter).
    property var actions: []
    // L'action qui vient de réussir : sa coche, un instant.
    property string done: ""
    // L'action qui attend un second clic : en rouge.
    property string armed: ""
    property string message: ""
    property color messageColor: Theme.textDim
    signal triggered(string name)

    readonly property int chip: 34
    readonly property int gap: 4
    readonly property int pad: 8

    readonly property int stackH: Math.max(0, root.actions.length * (root.chip + root.gap) - root.gap)
    readonly property real fullH: 2 * root.pad + root.stackH
        + (root.message !== "" ? bubble.height + (root.actions.length > 0 ? root.gap + 4 : 0) : 0)
    width: (root.message !== "" ? 220 : root.chip) + 2 * root.pad
    height: root.fullH
    Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }

    // La colonne : sort de la barre, plus vite qu'elle n'y rentre.
    property real env: 0
    onShownChanged: {
        envOpen.stop();
        envClose.stop();
        if (root.shown)
            envOpen.restart();
        else
            envClose.restart();
    }
    NumberAnimation { id: envOpen; target: root; property: "env"; to: 1; duration: 460; easing.type: Easing.OutExpo }
    NumberAnimation { id: envClose; target: root; property: "env"; to: 0; duration: 260; easing.type: Easing.InOutCubic }
    // Visible tant qu'un bouton est encore là, même en train de descendre.
    property int out: 0
    visible: root.shown || root.out > 0 || root.env > 0.001

    Lip {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.fullH * root.env
    }

    // Un bouton qui monte : son décalage, son fondu et sa taille suivent
    // `up` (0 en bas, rentrée ; 1 à sa place), avec un retard selon son rang.
    component Riser: Item {
        id: riser
        property int rank: 0
        property int count: 1
        property real up: 0
        readonly property bool raised: root.shown
        // En montant, le premier part d'abord ; en descendant, le dernier.
        onRaisedChanged: {
            riseAnim.stop();
            fallAnim.stop();
            if (riser.raised) {
                riseAnim.delay = riser.rank * 45;
                riseAnim.restart();
            } else {
                fallAnim.delay = (riser.count - 1 - riser.rank) * 30;
                fallAnim.restart();
            }
        }
        Component.onCompleted: if (riser.raised) { riseAnim.delay = riser.rank * 45; riseAnim.restart(); }
        onUpChanged: {
            var o = riser.up > 0.001;
            if (o !== riser.counted) {
                riser.counted = o;
                root.out += o ? 1 : -1;
            }
        }
        property bool counted: false
        Component.onDestruction: if (riser.counted) root.out -= 1

        SequentialAnimation {
            id: riseAnim
            property int delay: 0
            PauseAnimation { duration: riseAnim.delay }
            NumberAnimation { target: riser; property: "up"; to: 1; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 1.3 }
        }
        SequentialAnimation {
            id: fallAnim
            property int delay: 0
            PauseAnimation { duration: fallAnim.delay }
            NumberAnimation { target: riser; property: "up"; to: 0; duration: 200; easing.type: Easing.InCubic }
        }

        opacity: Math.min(1, riser.up * 1.5)
        scale: 0.6 + 0.4 * riser.up
        transform: Translate { y: (1 - riser.up) * (18 + riser.rank * 10) }
    }

    // Ce qui monte reste dans la colonne, qui grandit avec sa surface : rien
    // ne passe sur la barre, ni au-dessus de la colonne.
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.fullH * root.env
        clip: true

        // ── Les boutons, de bas en haut ──
        Repeater {
            model: root.actions

            Riser {
                id: slot
                required property var modelData
                required property int index
                rank: slot.index
                count: root.actions.length
                width: root.chip
                height: root.chip
                x: (root.width - root.chip) / 2
                y: parent.height - root.pad - (slot.index + 1) * root.chip - slot.index * root.gap

                readonly property bool isDone: root.done === slot.modelData.name
                readonly property bool isArmed: root.armed === slot.modelData.name

                // Armé : le fond et l'icône passent au rouge.
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSmall
                    color: Theme.colorDanger
                    opacity: slot.isArmed ? 0.18 : 0
                    scale: slot.isArmed ? 1 : 0.8
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                    Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                }
                BarButton {
                    anchors.centerIn: parent
                    size: root.chip
                    icon: slot.isDone ? "check.svg" : slot.modelData.glyph
                    tint: slot.isArmed ? Theme.colorDanger
                        : slot.isDone || slot.modelData.success === true ? Theme.colorSuccess : Theme.iconColor
                    onClicked: root.triggered(slot.modelData.name)
                }
            }
        }

        // ── Le message, au-dessus des boutons ──
        Riser {
            id: bubble
            rank: root.actions.length
            count: root.actions.length + 1
            visible: root.message !== ""
            x: root.pad
            y: parent.height - root.fullH + root.pad
            width: root.width - 2 * root.pad
            height: bubbleText.implicitHeight + 8

            Text {
                id: bubbleText
                anchors.fill: parent
                anchors.margins: 4
                text: root.message
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.family: "Inter"
                font.pixelSize: 11
                color: root.messageColor
                Behavior on color { ColorAnimation { duration: 200 } }
            }
        }
    }
}
