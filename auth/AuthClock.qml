pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"

// Grande horloge + date des écrans d'authentification, dans la typo des
// grands chiffres du shell (les tuiles de widgets/StatTile) : Inter Display
// légère, resserrée, chiffres tabulaires pour que l'heure ne danse pas d'une
// minute à l'autre.
//
// SystemClock ne tourne qu'à la minute : pas de secondes affichées, inutile de
// réveiller le CPU 60 fois par minute pour rien.
ColumnLayout {
    id: clockRoot

    // La taille de l'heure ; la date suit de loin.
    property int size: 112
    // Centrée (greeter) ou calée à gauche (carte du lockscreen).
    property int alignment: Qt.AlignHCenter

    spacing: 0

    readonly property date now: clock.date

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Text {
        Layout.alignment: clockRoot.alignment
        // Inter Display garde une marge à gauche de ses chiffres : calée à
        // gauche, l'heure semblerait en retrait du reste.
        Layout.leftMargin: clockRoot.alignment === Qt.AlignLeft ? -clockRoot.size / 20 : 0
        text: Qt.formatDateTime(clockRoot.now, "HH:mm")
        color: Theme.textPrimary
        font.family: "Inter Display"
        font.pixelSize: clockRoot.size
        font.weight: Font.Light
        font.letterSpacing: -clockRoot.size / 28
        font.features: { "tnum": 1 }
    }

    Text {
        Layout.alignment: clockRoot.alignment
        // La langue de l'interface, pas LANG : "Friday, October 17" ou
        // "Vendredi 17 octobre", le format venant du dictionnaire.
        text: {
            const d = I18n.locale.toString(clockRoot.now, I18n.tr("date.long"));
            return d.charAt(0).toUpperCase() + d.slice(1);
        }
        color: Theme.textSecondary
        font.family: "Inter"
        font.pixelSize: 15
        font.weight: Font.Medium
    }
}
