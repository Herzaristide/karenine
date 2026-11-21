import QtQuick
import "../services"

// La case d'une tâche (de Google Tasks) : cliquée, elle la coche, ou la
// décoche, ici tout de suite puis chez Google (Agenda.setDone). Une tâche
// pas encore créée chez Google (`pending`) attend, sans réagir.
Rectangle {
    id: check

    required property var task
    property int size: 10

    width: check.size
    height: check.size
    radius: Math.max(2, check.size / 5)
    color: check.task.done === true ? Theme.glow(0) : "transparent"
    border.color: Theme.glow(0)
    border.width: 1.5
    opacity: check.task.pending === true ? 0.4 : 1

    Text {
        anchors.centerIn: parent
        visible: check.task.done === true
        text: "✓"
        font.pixelSize: Math.round(check.size * 0.8)
        font.weight: Font.Bold
        color: Theme.bgDeep
    }

    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        enabled: check.task.pending !== true
        cursorShape: Qt.PointingHandCursor
        onClicked: Agenda.setDone(check.task, !check.task.done)
    }
}
