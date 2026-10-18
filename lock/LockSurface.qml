pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../auth"
import "../services"

// Visuel du lockscreen : le fond commun et la carte centrale (auth/AuthCard),
// complétée sur l'écran primaire par la musique et les stats matérielles.
//
// Purement présentation : l'authentification vit dans lock.qml, cette surface
// se contente d'émettre `submitted(password)` et d'afficher l'état que le
// parent lui repasse.
Item {
    id: surface

    // Pilotés par lock.qml
    required property string message
    required property bool messageIsError
    required property bool busy
    required property string userName

    // Musique et stats ne sont montées que sur l'écran primaire :
    // WlSessionLock instancie une surface par moniteur, et chaque LockStats
    // ouvrirait sinon son propre abonnement au socket anna.
    required property bool showWidgets

    // Vidéo de fond (le fond d'écran de la session), vide pour un fond uni.
    property string wallpaper: ""

    signal submitted(password: string)

    // La vidéo s'arrête après un moment sans souris ni clavier — hypridle
    // éteint l'écran peu après le verrouillage, inutile de décoder pour un
    // écran noir — et repart au moindre mouvement.
    property bool idle: false

    function wake(): void {
        surface.idle = false;
        idleTimer.restart();
    }

    Timer {
        id: idleTimer
        interval: 90 * 1000
        running: true
        onTriggered: surface.idle = true
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onPositionChanged: surface.wake()
    }

    // Vidé par lock.qml après chaque tentative.
    function clearPassword(): void {
        card.clearPassword();
    }

    function focusPassword(): void {
        card.focusPassword();
    }

    AuthBackdrop {
        anchors.fill: parent
        z: -1
        videoSource: surface.wallpaper
        playing: !surface.idle
    }

    AuthCard {
        id: card

        anchors.centerIn: parent

        userName: surface.userName
        subtitle: I18n.tr("lock.subtitle")
        message: surface.message
        messageIsError: surface.messageIsError
        busy: surface.busy

        onSubmitted: (user, secret) => surface.submitted(secret)
        onActivity: surface.wake()

        CardRule {
            visible: music.visible
        }

        LockMusic {
            id: music
            Layout.fillWidth: true
            visible: surface.showWidgets && music.hasPlayer
        }

        CardRule {
            visible: stats.visible
        }

        LockStats {
            id: stats
            Layout.fillWidth: true
            visible: surface.showWidgets
        }
    }
}
