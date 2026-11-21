import QtQuick
import QtQuick.Layouts
import "../services"

// Une ligne d'une section des réglages : une icône (assets/ui), ce qu'elle
// règle, une précision dessous, et à droite son contrôle (ce qu'on met
// dedans). Cliquable (`clickable`) : le survol l'éclaire, Entrée ou Espace
// l'actionne. `selected` : une coche d'accent à droite (un choix parmi
// d'autres). Un filet la sépare de la précédente.
Item {
    id: row

    property string icon: ""
    property string title
    property string subtitle: ""
    property bool clickable: false
    property bool selected: false
    default property alias trailing: trail.data
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: Math.max(row.subtitle !== "" ? 52 : 44, texts.implicitHeight + 18)

    activeFocusOnTab: row.clickable
    Keys.onPressed: (event) => {
        if (row.clickable && (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            row.clicked();
            event.accepted = true;
        }
    }

    // Le filet, sauf pour la première ligne de la carte.
    Rectangle {
        visible: row.y > 0
        x: 12
        width: parent.width - 24
        height: 1
        color: Theme.dividerColor
    }

    // Le survol.
    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: Theme.radiusSmall
        color: Theme.hoverOverlay
        opacity: row.clickable && (ma.containsMouse || row.activeFocus) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    FocusRing { radius: Theme.radiusSmall }

    NixIcon {
        id: glyph
        visible: row.icon !== ""
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        iconSize: 18
        source: row.icon !== "" ? "../assets/ui/" + row.icon : ""
        color: row.selected ? Theme.accentColor : Theme.iconColor
        Behavior on color { ColorAnimation { duration: 200 } }
    }

    Column {
        id: texts
        anchors.left: glyph.visible ? glyph.right : parent.left
        anchors.leftMargin: 12
        anchors.right: trail.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        Text {
            width: parent.width
            text: row.title
            font.family: "Inter"
            font.pixelSize: 13
            font.weight: Font.Medium
            color: Theme.textPrimary
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            visible: row.subtitle !== ""
            text: row.subtitle
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textSecondary
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
    }

    // Le contrôle, à droite ; ou la coche d'un choix.
    Row {
        id: trail
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        NixIcon {
            visible: row.selected || checkFade.running
            anchors.verticalCenter: parent.verticalCenter
            iconSize: 16
            source: "../assets/ui/check.svg"
            color: Theme.accentColor
            opacity: row.selected ? 1 : 0
            scale: row.selected ? 1 : 0.6
            Behavior on opacity { NumberAnimation { id: checkFade; duration: 180 } }
            Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack; easing.overshoot: 2 } }
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        z: -1
        enabled: row.clickable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.clicked()
    }
}
