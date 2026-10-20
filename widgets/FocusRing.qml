import QtQuick
import "../services"

// Le contour de ce qui a le clavier : un fil à la teinte de la barre, posé
// juste autour de son parent. Un clic ne donne pas le focus aux boutons des
// widgets : il n'apparaît qu'en passant de l'un à l'autre au clavier (Tab).
// `watch` : l'élément dont le focus compte, s'il n'est pas le parent (la
// barre d'onglets, dont le contour suit la pastille de l'onglet actif).
Rectangle {
    property Item watch: parent
    property real gap: 3

    anchors.fill: parent
    anchors.margins: -gap
    radius: Theme.radiusSmall + gap
    color: "transparent"
    border.width: 2
    border.color: Qt.alpha(Theme.glow(0), 0.9)
    visible: watch !== null && watch.activeFocus
}
