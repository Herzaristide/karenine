pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"

// L'onglet « Notifications » : celles qu'on n'a pas encore fermées, la plus
// récente en haut (services/Notifications.qml). En tête, leur nombre et de
// quoi tout effacer.
//
//   3 notifications                                      (Tout effacer)
//   ╭ [ic] Firefox · 14:02 ─────────────────────────────────────── ✕ ╮
//   │      Téléchargement terminé                                    │
//   ╰────────────────────────────────────────────────────────────────╯
Item {
    id: root

    readonly property int count: Notifications.all.length

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: root.count > 0 ? I18n.trn("notifications.count", root.count) : ""
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                color: Theme.textSecondary
            }

            GlassButton {
                implicitHeight: 28
                fontSize: 11
                visible: root.count > 0
                text: I18n.tr("notifications.clear")
                onClicked: Notifications.clear()
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: ScriptModel { values: Notifications.all }

            delegate: NotificationCard {
                required property var modelData
                notification: modelData
                width: list.width
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: I18n.tr("notifications.none")
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.textSecondary
            }
        }
    }
}
