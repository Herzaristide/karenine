pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../services"

// Grande horloge + date du lockscreen.
// SystemClock ne tourne qu'à la minute : l'écran verrouillé n'affiche pas les
// secondes, inutile de réveiller le CPU 60 fois par minute pour rien.
Column {
    id: clockRoot

    spacing: 4

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
        font.pixelSize: 96
        font.weight: Font.Light
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        // Locale FR : "jeudi 17 juillet".
        text: {
            const d = Qt.formatDateTime(clockRoot.now, "dddd d MMMM");
            return d.charAt(0).toUpperCase() + d.slice(1);
        }
        color: Theme.textSecondary
        font.family: "JetBrains Mono"
        font.pixelSize: 18
    }
}
