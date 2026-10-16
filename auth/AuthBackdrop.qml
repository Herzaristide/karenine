pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "../services"

// Fond commun du lockscreen et du greeter, en trois couches :
//   1. le fond d'écran — une vidéo jouée ici (`videoSource`, cas du lock, que
//      le compositeur isole de tout le reste), ou ce qu'il y a sous la surface
//      (`seeThrough`, cas du greeter, où mpvpaper joue dessous) ;
//   2. un voile sombre, pour que la carte reste lisible sur n'importe quelle
//      image ;
//   3. deux halos à la teinte de l'accent derrière la carte.
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

    component Halo: Shape {
        id: halo

        required property real cx
        required property real cy
        required property real radius
        required property color tint

        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: halo.cx
                centerY: halo.cy
                centerRadius: halo.radius
                focalX: halo.cx
                focalY: halo.cy
                GradientStop { position: 0.0; color: Qt.alpha(halo.tint, 0.20) }
                GradientStop { position: 0.45; color: Qt.alpha(halo.tint, 0.06) }
                GradientStop { position: 1.0; color: Qt.alpha(halo.tint, 0.0) }
            }
            startX: 0; startY: 0
            PathLine { x: halo.width; y: 0 }
            PathLine { x: halo.width; y: halo.height }
            PathLine { x: 0; y: halo.height }
            PathLine { x: 0; y: 0 }
        }
    }

    readonly property real span: Math.max(width, height)

    Halo {
        cx: backdrop.width * 0.42
        cy: backdrop.height * 0.38
        radius: backdrop.span * 0.42
        tint: Theme.glow(0)
    }

    Halo {
        cx: backdrop.width * 0.60
        cy: backdrop.height * 0.66
        radius: backdrop.span * 0.36
        tint: Theme.glow(0.12)
    }
}
