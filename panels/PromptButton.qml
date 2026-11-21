import QtQuick
import "../services"

// Un bouton des cartes de demande (PromptCard) : « Annuler », « Autoriser »…
// Le principal est plein (couleur d'accent), celui d'un danger en rouge.
Rectangle {
    id: btn

    property string label
    property bool primary: false
    property bool danger: false
    readonly property bool hovered: btnMa.containsMouse || btn.activeFocus
    signal clicked()

    readonly property color fill: btn.danger ? Theme.colorDanger : Theme.accentColor

    implicitWidth: btnText.implicitWidth + 28
    implicitHeight: 32
    radius: Theme.radiusSmall
    color: btn.primary || btn.danger ? btn.fill : (btn.hovered ? Theme.hoverOverlay : "transparent")
    border.width: btn.primary || btn.danger ? (btn.activeFocus ? 2 : 0) : 1
    border.color: btn.primary || btn.danger ? Theme.textPrimary : Theme.dividerColor
    opacity: btnMa.pressed ? 0.8 : 1

    activeFocusOnTab: true
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            btn.clicked();
            event.accepted = true;
        }
    }

    Text {
        id: btnText
        anchors.centerIn: parent
        text: btn.label
        font.family: "Inter"
        font.pixelSize: 12
        font.weight: Font.Medium
        color: btn.primary || btn.danger ? Theme.bgDeep : Theme.textPrimary
    }
    MouseArea {
        id: btnMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
