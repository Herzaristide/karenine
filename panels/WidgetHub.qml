pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import "../services"
import "../widgets"

// Les widgets, dans la capsule de la barre de conversation : le flocon
// l'agrandit vers le haut, et la place gagnée au-dessus du champ les montre.
// En haut, une barre qui ne change pas d'un onglet à l'autre (HubTopBar :
// l'alimentation, le Bluetooth, la capture) ; puis un widget à
// la fois, en largeur ; la barre d'onglets, juste au-dessus du champ, passe
// de l'un à l'autre.
//
//   ╭────────────────────────────────────────────────╮
//   │ (🔒)(☾)(⇥)(↻)(⏻)             (ᛒ)(📷)(●)  [87] │  la barre du haut
//   │ ────────────────────────────────────────────── │
//   │                                                │
//   │      le widget de l'onglet, à l'horizontale     │  fondu croisé et léger
//   │                                                │  glissement d'un onglet
//   │  ▭ Explorer  ▦ Système  ▣ Notes  ▶ Lecteur…     │  à l'autre
//   │ ────────────────────────────────────────────── │
//   │ ❄  Demander à Karénine…                     🎤 │  le champ, inchangé
//   ╰────────────────────────────────────────────────╯
//
// La barre (ConversationBar) décide de la place : elle lit `preferredHeight`
// et règle la hauteur de la capsule ; ce composant remplit ce qu'on lui
// donne. Un onglet n'existe que tant qu'il est affiché (Loader) : caché, son
// widget ne fait plus tourner ses processus (sondes, lecteur, micro).
//
// Au clavier, tout s'atteint : Tab et Maj+Tab passent d'un contrôle à
// l'autre (la barre du haut, le widget, les onglets, puis le champ), Entrée
// ou Espace actionne, les flèches règlent ce qui se règle. Ailleurs, et
// dans le champ vide, ← → changent de widget ; Ctrl+Tab aussi. Échap rend
// le clavier au champ. Une portée de focus : la barre sait qu'il est ici.
FocusScope {
    id: hub

    // La barre de conversation : sa teinte et sa police.
    required property var bar
    // De 0 à 1 : la part de la capsule ouverte (ConversationBar.expand).
    property real expand: 0

    // Échap : le clavier retourne au champ.
    signal leave()

    // L'onglet d'à côté (dir : 1 ou -1), en boucle. Le clavier, s'il était
    // dans le widget qui s'en va, passe sur les onglets.
    function step(dir) {
        var n = Widgets.hubTabs.length;
        if (content.activeFocus)
            tabBar.forceActiveFocus();
        Widgets.hubTab = Widgets.hubTabs[(hub.current + dir + n) % n];
    }

    // Le clavier sur les onglets (↑ depuis le champ).
    function enter() {
        tabBar.forceActiveFocus();
    }

    Keys.onPressed: (event) => {
        var ctrl = event.modifiers & Qt.ControlModifier;
        if (ctrl && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
            hub.step(event.key === Qt.Key_Backtab ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            // Ce qui se règle aux flèches (curseurs, sélecteurs) les garde ;
            // ailleurs, elles passent au widget d'à côté.
            hub.step(event.key === Qt.Key_Left ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            hub.leave();
            event.accepted = true;
        }
    }

    readonly property int pad: 14
    readonly property int tabsH: 40
    readonly property int gap: 12
    // La barre du haut (alimentation, capture), la même pour tous les onglets.
    readonly property int topH: 38

    // La hauteur de chaque widget, à l'horizontale.
    readonly property var heights: ({
        // Les lieux, trois rangées de tuiles, les disques.
        explorer: 300 + 56,
        // Le choix de la machine, trois cartes, puis le téléphone.
        stats: 30 + 10 + 150 + 10 + 76,
        notifications: 300,
        // Le champ, puis le mur de cartes, qui défile.
        notes: 340,
        lecteur: 210,
        // L'accordeur et le métronome, puis s'enregistrer (MusicPanel).
        musique: 196,
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
        // Au-dessus du widget : le menu Bluetooth se déplie par-dessus.
        z: 2
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
        color: Theme.dividerColor
    }

    // ── Le widget ────────────────────────────────────────────────
    FocusScope {
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
                // Celui qui s'efface n'est plus atteignable, ni au clic ni à Tab.
                enabled: page.isCurrent
                // Créé par petits morceaux, entre les images : les gros widgets
                // (lecteur, réglages) ne figent plus le début de l'ouverture.
                asynchronous: true

                // Fondu croisé, et un léger glissement du côté de l'onglet.
                // Le nouvel onglet n'apparaît qu'une fois prêt, en fondu.
                opacity: page.isCurrent && page.status === Loader.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                transform: Translate {
                    x: page.isCurrent ? 0 : (page.index < hub.current ? -28 : 28)
                    Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                }

                sourceComponent: page.modelData === "explorer" ? explorerPage
                               : page.modelData === "stats" ? statsPage
                               : page.modelData === "notifications" ? notificationsPage
                               : page.modelData === "notes" ? notesPage
                               : page.modelData === "lecteur" ? playerPage
                               : page.modelData === "musique" ? musicPage
                               : settingsPage
            }
        }
    }

    // Un fichier ouvert : la barre s'efface pour laisser voir l'application.
    Component { id: explorerPage; FileExplorer { onOpened: hub.bar.dismiss() } }
    Component { id: statsPage; HardwareStats {} }
    Component { id: notificationsPage; NotificationCenter {} }
    Component { id: notesPage; NotesWidget {} }
    Component { id: playerPage; MusicPlayerWidget {} }
    // L'accordeur, le métronome et l'enregistrement, d'un seul tenant.
    Component { id: musicPage; MusicPanel {} }
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

        // Un seul arrêt de Tab pour toute la barre : ← → changent d'onglet
        // (le hub s'en charge), Début et Fin vont aux extrémités.
        activeFocusOnTab: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                Widgets.hubTab = Widgets.hubTabs[event.key === Qt.Key_Home ? 0 : Widgets.hubTabs.length - 1];
                event.accepted = true;
            }
        }

        // La pastille de l'onglet actif : la même que l'indicateur du
        // micro, qui glisse d'un onglet à l'autre.
        Rectangle {
            height: tabBar.height
            width: tabBar.tabW
            x: hub.current * tabBar.tabW
            Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            radius: Theme.radiusSmall
            color: Theme.selectedFill

            FocusRing { watch: tabBar; gap: 2 }
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
                    radius: Theme.radiusSmall
                    color: Theme.hoverOverlay
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
                        // Huit onglets se partagent la largeur : un nom trop
                        // long s'abrège plutôt que de déborder sur le voisin.
                        width: Math.min(implicitWidth, tabBar.tabW - 16 - 7 - 10)
                        elide: Text.ElideRight
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
