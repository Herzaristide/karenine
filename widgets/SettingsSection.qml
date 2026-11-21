import QtQuick
import QtQuick.Layouts
import "../services"

// Une section des réglages (widgets/Settings.qml) : un petit titre, puis
// une carte où se suivent ses lignes (SettingsRow), séparées d'un filet.
//
//   APPARENCE
//   ╭──────────────────────────────╮
//   │ ◐ Thème        [Sombre|Clair]│
//   │──────────────────────────────│
//   │ ● Couleur d'accent           │
//   ╰──────────────────────────────╯
ColumnLayout {
    id: section

    property string title
    default property alias rows: card.data

    spacing: 8

    Text {
        Layout.leftMargin: 4
        text: section.title
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.8
        font.capitalization: Font.AllUppercase
        color: Theme.textDim
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: card.implicitHeight + 8
        radius: Theme.radius
        color: Theme.bgElevated

        ColumnLayout {
            id: card
            x: 4
            y: 4
            width: parent.width - 8
            spacing: 0
        }
    }
}
