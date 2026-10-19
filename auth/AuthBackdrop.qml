pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Fond commun du lockscreen et du greeter, en deux couches :
//   1. le fond d'écran — une vidéo jouée ici (`videoSource`, cas du lock, que
//      le compositeur isole de tout le reste), ou ce qu'il y a sous la surface
//      (`seeThrough`, cas du greeter, où mpvpaper joue dessous) ;
//   2. un voile du fond, pour que la carte reste lisible sur n'importe quelle
//      image.
// Sans fond d'écran, la couleur de base de la palette.
Rectangle {
    id: backdrop

    // Vidéo à jouer en boucle derrière la carte (chemin local).
    property string videoSource: ""
    // Mise en pause sans la décharger (écran éteint, inactivité…).
    property bool playing: true
    // Surface transparente : laisse voir le fond dessiné dessous.
    property bool seeThrough: false

    readonly property bool hasWallpaper: backdrop.seeThrough || (video.status === Loader.Ready && video.item.showing) // qmllint disable missing-property

    color: backdrop.seeThrough ? "transparent" : Theme.bgDeep

    // Chargé à part : QtMultimedia n'est fourni qu'au lockscreen (voir
    // lock-session côté NixOS), le greeter ne doit pas en dépendre.
    Loader {
        id: video
        anchors.fill: parent
        active: backdrop.videoSource.length > 0
        source: "AuthVideo.qml"
        onLoaded: {
            video.item.source = Qt.binding(() => backdrop.videoSource);
            video.item.playing = Qt.binding(() => backdrop.playing);
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: backdrop.hasWallpaper
        color: Qt.alpha(Theme.bgDeep, 0.45)
    }
}
