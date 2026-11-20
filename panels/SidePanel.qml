pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"
import "../widgets"

// Le panneau de droite : la surface qui s'élargit sur le bord droit, de la
// même encre, au-dessus de la barre du bas. Le dernier bouton de la barre
// le montre ou le cache (Widgets.panelOpen) ; il prend alors sa place aux
// fenêtres (exclusiveZone), qui se poussent.
//
//   ╭ ♫ Musique ▭ Explorer ▦ Système ▣ Agenda ✦ Claude ╮   les onglets, tous
//   │                        │   de la même largeur
//   │   la vue de l'onglet    │
//   │                        │
//   ┃ ← le bord gauche se tire pour l'élargir (Widgets.panelWidth)
//
// Une vue n'existe que tant qu'elle est affichée (Loader) : cachée, son
// widget ne fait plus tourner ses processus (sondes, lecteur, micro).
PanelWindow { // qmllint disable uncreatable-type
    id: panel

    readonly property int minW: 340
    readonly property int maxW: 860
    // Le même écart que celui des fenêtres au bord de l'écran (gaps_out
    // d'Hyprland) : le haut du panneau tombe sur le haut des fenêtres.
    readonly property int edge: 18
    // Le retrait du contenu sur le bord gauche (la poignée qui élargit le
    // panneau s'y tient) : laissé hors de la zone réservée, pour que l'écart
    // entre une fenêtre et le panneau soit le gaps_out d'Hyprland (18),
    // comme entre deux fenêtres.
    readonly property int inset: 6
    readonly property string uiFont: "Inter"

    visible: Widgets.panelOpen
    // Sur la couche Top, comme la barre : la barre, créée avant, garde
    // toute la largeur et le panneau se pose au-dessus d'elle. Les volets
    // de la barre, sur la couche Overlay, passent par-dessus.
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-panel"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors { // qmllint disable unqualified unresolved-type
        top: true
        right: true
        bottom: true
    }
    implicitWidth: Math.max(panel.minW, Math.min(panel.maxW, Widgets.panelWidth))
    exclusiveZone: panel.implicitWidth - panel.inset
    color: Theme.bgDeep

    readonly property var tabs: [
        { key: "music", icon: "music.svg", label: I18n.tr("widget.music") },
        { key: "files", icon: "folder.svg", label: I18n.tr("widget.explorer") },
        { key: "system", icon: "monitor.svg", label: I18n.tr("widget.stats") },
        { key: "agenda", icon: "calendar.svg", label: I18n.tr("widget.agenda") },
        { key: "claude", icon: "claude.svg", label: I18n.tr("widget.claude"), badge: true }
    ]

    Item {
        id: body
        anchors.fill: parent
        anchors.topMargin: panel.edge
        anchors.rightMargin: panel.edge
        anchors.leftMargin: panel.inset
        // Le bas du contenu tombe sur le bas des fenêtres : le panneau
        // s'arrête au bord de la zone réservée par la barre, les fenêtres
        // gaps_out (18) au-dessus.
        anchors.bottomMargin: panel.edge

        // ── Les onglets ──────────────────────────────────────────
        Rectangle {
            id: tabBar
            anchors.left: parent.left
            anchors.right: parent.right
            height: 40
            radius: Theme.radiusSmall + 3
            color: Theme.bgElevated

            Row {
                id: tabRow
                anchors.fill: parent
                anchors.margins: 3
                spacing: 3

                // Tous de la même largeur, toujours avec leur nom : l'onglet
                // ouvert se distingue par son fond, pas par sa taille.
                readonly property real unit: (tabRow.width - 4 * tabRow.spacing) / panel.tabs.length

                Repeater {
                    model: panel.tabs

                    Rectangle {
                        id: tab
                        required property var modelData
                        readonly property bool active: Widgets.panelTab === tab.modelData.key

                        width: tabRow.unit
                        height: tabRow.height
                        radius: Theme.radiusSmall
                        color: tab.active ? Theme.bgDeep : tabMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        Behavior on color { ColorAnimation { duration: 160 } }

                        Row {
                            anchors.centerIn: parent
                            spacing: 7

                            NixIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                iconSize: 16
                                source: "../assets/ui/" + tab.modelData.icon
                                color: tab.active ? Theme.accentColor : Theme.iconColor
                                opacity: tab.active || tabMa.containsMouse ? 1 : 0.75
                            }
                            // Des sessions attendent : leur nombre.
                            Rectangle {
                                id: waitBadge
                                anchors.verticalCenter: parent.verticalCenter
                                visible: tab.modelData.badge === true && ClaudeSessions.waiting > 0
                                width: Math.max(16, waitText.implicitWidth + 8)
                                height: 16
                                radius: 8
                                color: Theme.accentColor
                                Text {
                                    id: waitText
                                    anchors.centerIn: parent
                                    text: ClaudeSessions.waiting
                                    font.family: panel.uiFont
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                    color: Theme.bgDeep
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                // Trop étroit pour le nom entier : il s'abrège.
                                width: Math.min(implicitWidth, tab.width - 16 - 7 - 12
                                                - (waitBadge.visible ? waitBadge.width + 7 : 0))
                                elide: Text.ElideRight
                                text: tab.modelData.label
                                font.family: panel.uiFont
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                color: tab.active ? Theme.textPrimary : Theme.textSecondary
                            }
                        }

                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Widgets.panelTab = tab.modelData.key
                        }
                    }
                }
            }
        }

        // ── La vue ───────────────────────────────────────────────
        Loader {
            id: view
            anchors.top: tabBar.bottom
            anchors.topMargin: 16
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            asynchronous: true
            active: panel.visible
            sourceComponent: ({
                "music": musicView, "files": filesView, "system": systemView,
                "agenda": agendaView, "claude": claudeView, "settings": settingsView
            })[Widgets.panelTab] || musicView

            opacity: view.status === Loader.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        Component { id: musicView; MusicView {} }
        // Ouvrir un fichier ne referme pas le panneau : il reste là.
        Component { id: filesView; FileExplorer {} }
        Component { id: systemView; FleetView {} }
        // Hors des onglets : la palette de la barre y mène (« Tous les
        // réglages »).
        Component { id: settingsView; Settings { showInternalHeader: false } }
        Component { id: agendaView; CalendarWidget {} }
        Component { id: claudeView; ClaudeView {} }
    }

    // ── Le bord gauche, qui se tire ──────────────────────────────
    // Rien ne le montre : le curseur change au survol. La fenêtre garde son
    // bord droit collé à l'écran ; tirer vers la gauche l'élargit.
    MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 8
        hoverEnabled: true
        cursorShape: Qt.SizeHorCursor
        preventStealing: true

        property real pressX: 0
        onPressed: (mouse) => pressX = mouse.x
        // La fenêtre suit, et le bord revient sous le curseur : chaque
        // mouvement ne compte que l'écart depuis le précédent.
        onPositionChanged: (mouse) => {
            if (!pressed)
                return;
            Widgets.panelWidth = Math.round(Math.max(panel.minW, Math.min(panel.maxW,
                                                     panel.implicitWidth - (mouse.x - pressX))));
        }
    }
}
