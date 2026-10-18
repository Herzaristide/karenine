pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../services"

// Grande horloge + date de la carte d'authentification.
// SystemClock ne tourne qu'à la minute : pas de secondes affichées, inutile de
// réveiller le CPU 60 fois par minute pour rien.
Column {
    id: clockRoot

    spacing: 2

    readonly property date now: clock.date

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Qt.formatDateTime(clockRoot.now, "HH:mm")
        color: Theme.textPrimary
        font.family: "JetBrains Mono"
        font.pixelSize: 84
        font.weight: Font.Light
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        // La langue de l'interface, pas LANG : "Friday, October 17" ou
        // "Vendredi 17 octobre", le format venant du dictionnaire.
        text: {
            const d = I18n.locale.toString(clockRoot.now, I18n.tr("date.long"));
            return d.charAt(0).toUpperCase() + d.slice(1);
        }
        color: Theme.textSecondary
        font.family: "JetBrains Mono"
        font.pixelSize: 15
    }
}
