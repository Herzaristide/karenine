pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import "../services"
import "../widgets"

// Les widgets, dans la capsule de la barre de conversation : le flocon
// l'agrandit vers le haut, et la place gagnée au-dessus du champ les montre.
// En haut, une barre qui ne change pas d'un onglet à l'autre (HubTopBar :
// l'alimentation, la capture, la luminosité, le volume) ; puis un widget à
// la fois, en largeur ; la barre d'onglets, juste au-dessus du champ, passe
// de l'un à l'autre.
//
//   ╭────────────────────────────────────────────────╮
//   │ (🔒)(☾)(⇥)(↻)(⏻)  (📷) (☀) ━●─ (🔊) ━━━●─ 64 % │  la barre du haut
//   │ ────────────────────────────────────────────── │
//   │                                                │
//   │      le widget de l'onglet, à l'horizontale     │  fondu croisé et léger
//   │                                                │  glissement d'un onglet
//   │  ▦ Système  ▤ Network  ▶ Musique  △ Métronome…   │  à l'autre
//   │ ────────────────────────────────────────────── │
//   │ ❄  Demander à Karénine…                     🎤 │  le champ, inchangé
//   ╰────────────────────────────────────────────────╯
//
// La barre (ConversationBar) décide de la place : elle lit `preferredHeight`
// et règle la hauteur de la capsule ; ce composant remplit ce qu'on lui
// donne. Un onglet n'existe que tant qu'il est affiché (Loader) : caché, son
// widget ne fait plus tourner ses processus (sondes, lecteur, micro).
Item {
    id: hub

    // La barre de conversation : sa teinte et sa police.
    required property var bar
    // De 0 à 1 : la part de la capsule ouverte (ConversationBar.expand).
    property real expand: 0

    readonly property int pad: 14
    readonly property int tabsH: 40
    readonly property int gap: 12
    // La barre du haut (alimentation, volume), la même pour tous les onglets.
    readonly property int topH: 38

    // La hauteur de chaque widget, à l'horizontale.
    readonly property var heights: ({
        stats: 196,
        network: 196,
        musique: 210,
        metronome: 150,
        accordeur: 150,
        reglages: 330
    })
    readonly property int contentH: hub.heights[Widgets.hubTab] || 200
    // Ce que la capsule doit ajouter au-dessus du champ.
    readonly property int preferredHeight: hub.pad + hub.topH + hub.gap + 1 + hub.gap
                                           + hub.contentH + hub.gap + hub.tabsH + 6

    readonly property int current: Math.max(0, Widgets.hubTabs.indexOf(Widgets.hubTab))
    // Les widgets n'apparaissent qu'une fois la capsule bien ouverte, et
    // s'effacent avant qu'elle ne se referme.
    opacity: Math.max(0, Math.min(1, (hub.expand - 0.45) / 0.55))
    visible: hub.expand > 0
    clip: true

    // ── La barre du haut ─────────────────────────────────────────
    HubTopBar {
        id: topBar
        bar: hub.bar
        live: hub.expand > 0
        x: hub.pad + 4
        y: hub.pad
        width: hub.width - 2 * (hub.pad + 4)
        height: hub.topH
    }

    // Le fil sous la barre du haut.
    Rectangle {
        x: hub.pad + 10
        y: hub.pad + hub.topH + hub.gap
        width: hub.width - 2 * (hub.pad + 10)
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.alpha(Theme.textPrimary, 0.1) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    // ── Le widget ────────────────────────────────────────────────
    Item {
        id: content
        x: hub.pad + 4
        y: hub.pad + hub.topH + 2 * hub.gap + 1
        width: hub.width - 2 * (hub.pad + 4)
        height: hub.contentH

        Repeater {
            model: Widgets.hubTabs

            Loader {
                id: page
                required property string modelData
                required property int index
                readonly property bool isCurrent: page.index === hub.current

                width: content.width
                height: hub.heights[page.modelData] || 200
                active: hub.expand > 0 && (page.isCurrent || page.opacity > 0)
                // Créé par petits morceaux, entre les images : les gros widgets
                // (musique, réglages) ne figent plus le début de l'ouverture.
                asynchronous: true

                // Fondu croisé, et un léger glissement du côté de l'onglet.
                // Le nouvel onglet n'apparaît qu'une fois prêt, en fondu.
                opacity: page.isCurrent && page.status === Loader.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                transform: Translate {
                    x: page.isCurrent ? 0 : (page.index < hub.current ? -28 : 28)
                    Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                }

                sourceComponent: page.modelData === "stats" ? statsPage
                               : page.modelData === "network" ? serversPage
                               : page.modelData === "musique" ? musicPage
                               : page.modelData === "metronome" ? metronomePage
                               : page.modelData === "accordeur" ? tunerPage
                               : settingsPage
            }
        }
    }

    Component { id: statsPage; HardwareStats {} }
    Component { id: serversPage; ServersWidget {} }
    Component { id: musicPage; MusicPlayerWidget {} }
    Component { id: metronomePage; Metronome { active: true } }
    Component { id: tunerPage; Tuner { active: true } }
    Component { id: settingsPage; Settings { showInternalHeader: false } }

    // ── La barre d'onglets ───────────────────────────────────────
    Item {
        id: tabBar
        x: hub.pad
        width: hub.width - 2 * hub.pad
        height: hub.tabsH
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6

        readonly property real tabW: width / Widgets.hubTabs.length

        // La pastille de l'onglet actif : la même que l'indicateur du
        // micro, qui glisse d'un onglet à l'autre.
        Rectangle {
            height: tabBar.height
            width: tabBar.tabW
            x: hub.current * tabBar.tabW
            Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            radius: height / 2
            color: Qt.alpha(hub.bar.hue(0), 0.16)
            border.width: 1
            border.color: Qt.alpha(hub.bar.hue(0), 0.38)
        }

        Repeater {
            model: Widgets.hubTabs

            Item {
                id: tab
                required property string modelData
                required property int index
                readonly property bool active: tab.index === hub.current

                x: tab.index * tabBar.tabW
                width: tabBar.tabW
                height: tabBar.height

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: Qt.alpha(Theme.textPrimary, 0.06)
                    opacity: tabMa.containsMouse && !tab.active ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 7

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        scale: tabMa.pressed ? 0.9 : 1
                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                        Image {
                            id: tabIcon
                            anchors.fill: parent
                            source: "../assets/icons/" + Widgets.hubIcons[tab.modelData]
                            sourceSize.width: 48
                            sourceSize.height: 48
                            visible: false
                        }
                        MultiEffect {
                            anchors.fill: tabIcon
                            source: tabIcon
                            colorization: 1.0
                            colorizationColor: tab.active ? hub.bar.hue(0.05) : Theme.iconColor
                            opacity: tab.active || tabMa.containsMouse ? 1 : 0.7
                            Behavior on colorizationColor { ColorAnimation { duration: 220 } }
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Widgets.hubLabels[tab.modelData]
                        font.family: hub.bar.uiFont
                        font.pixelSize: 12
                        font.weight: tab.active ? Font.DemiBold : Font.Medium
                        color: tab.active ? Theme.textPrimary : Theme.textSecondary
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }
                }

                MouseArea {
                    id: tabMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Widgets.hubTab = tab.modelData
                }
            }
        }
    }
}
