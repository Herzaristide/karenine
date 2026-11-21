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
//   ╭ ♫ Musique ▭ Explorer ▦ Système ▣ Agenda ✦ Claude ⚙ Réglages ╮   les onglets, tous
//   │                        │   de la même largeur
//   │   la vue de l'onglet    │
//   │                        │
//   ┃ ← le bord gauche se tire pour l'élargir (Widgets.panelWidth)
//
// Une vue n'existe que tant qu'elle est affichée (Loader) : cachée, son
// widget ne fait plus tourner ses processus (sondes, lecteur, micro).
//
// Le mouvement : l'effet « génie » de macOS. Le panneau sort de son bouton,
// le dernier de la barre, comme une fenêtre du Dock : d'abord un filet qui
// monte de l'entonnoir posé sur le bouton, puis l'image s'élargit et ses
// flancs se redressent jusqu'au panneau entier. À la fermeture, il s'y
// engouffre, plus vite. Pendant le mouvement, c'est une image du panneau
// ouvert (ShaderEffectSource), déformée sur une grille par
// shaders/genie.vert ; une fois ouvert, le vrai panneau, net et vivant.
// Les fenêtres se poussent dès l'ouverture ; à la fermeture, elles ne
// reprennent la place qu'à la fin, quand le génie est presque rentré
// (`releaseAt`).
//
// La fenêtre du panneau reste là, vide et transparente, ne prenant pas la
// souris : rien n'est créé au moment d'ouvrir, et Hyprland n'y ajoute pas
// sa propre animation. Elle déborde de `lipR` à gauche du panneau, pour le
// coin creusé qui le raccorde à la barre.
//
// D'un onglet à l'autre, la pastille de l'onglet ouvert glisse vers le
// nouveau, et les vues se relaient : l'ancienne s'efface en partant du côté
// opposé, la nouvelle arrive du côté de son onglet.
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

    // La fenêtre de la barre existe (shell.qml) : le panneau n'est créé
    // qu'après elle, et se recrée après elle si elle est recréée.
    property bool barReady: true
    // Le bouton du panneau dans la barre : son retrait depuis le bord droit
    // de l'écran et sa largeur (Bar.panelButtonInset / panelButtonWidth).
    property real buttonInset: 14
    property real buttonWidth: 34

    // La largeur du panneau, et le débord à gauche pour le coin creusé.
    readonly property int panelW: Math.max(panel.minW, Math.min(panel.maxW, Widgets.panelWidth))
    readonly property int lipR: Theme.radius

    // Le génie. À l'ouverture, il jaillit (le début n'est qu'un filet
    // au-dessus du bouton : il ne doit pas s'y attarder) puis se pose en
    // douceur ; à la fermeture, il part aussitôt, plus vite encore, et
    // ralentit à peine en entrant dans le bouton.
    readonly property int openMs: 420
    readonly property int closeMs: 280

    // 0 : rentré dans le bouton ; 1 : ouvert.
    property real reveal: 0
    // Ouvert, ou en train de rentrer : les vues sont chargées.
    readonly property bool live: Widgets.panelOpen || panel.reveal > 0
    // Tout à fait ouvert : le vrai panneau, plus son image.
    readonly property bool settled: panel.reveal >= 1
    visible: panel.barReady
    // Seul le panneau ouvert prend la souris ; en mouvement ou rentré, rien.
    mask: Region { item: panel.settled ? panelArea : null } // qmllint disable unqualified

    Connections {
        target: Widgets
        function onPanelOpenChanged() {
            if (Widgets.panelOpen) {
                hideAnim.stop();
                showAnim.restart();
            } else {
                showAnim.stop();
                hideAnim.restart();
            }
        }
    }
    Component.onCompleted: if (Widgets.panelOpen) showAnim.restart()
    NumberAnimation {
        id: showAnim
        target: panel
        property: "reveal"
        to: 1
        duration: panel.openMs
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: hideAnim
        target: panel
        property: "reveal"
        to: 0
        duration: panel.closeMs
        easing.type: Easing.OutCubic
    }
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
    implicitWidth: panel.panelW + panel.lipR
    // Les fenêtres se poussent dès l'ouverture, et reviennent à la fin de la
    // fermeture.
    // À l'ouverture, aussitôt ; à la fermeture, la place reste réservée
    // jusqu'à ce que le génie soit presque rentré (Hyprland rend la place
    // aux fenêtres plus vite que le génie ne se referme : sans cela, elles
    // filent dessous avant qu'il ait disparu).
    readonly property real releaseAt: 0.1
    exclusiveZone: Widgets.panelOpen || panel.reveal > panel.releaseAt ? panel.panelW - panel.inset : 0
    color: "transparent"

    // Le rang d'un onglet ; un inconnu, après eux.
    function tabIndex(key) {
        for (var i = 0; i < panel.tabs.length; i++)
            if (panel.tabs[i].key === key)
                return i;
        return panel.tabs.length;
    }

    readonly property var tabs: [
        { key: "music", icon: "music.svg", label: I18n.tr("widget.music") },
        { key: "files", icon: "folder.svg", label: I18n.tr("widget.explorer") },
        { key: "system", icon: "monitor.svg", label: I18n.tr("widget.stats") },
        { key: "agenda", icon: "calendar.svg", label: I18n.tr("widget.agenda") },
        { key: "claude", icon: "sparkles.svg", label: I18n.tr("widget.claude"), badge: true },
        { key: "settings", icon: "settings.svg", label: I18n.tr("widget.settings") }
    ]

    // ── Le panneau tel qu'ouvert ─────────────────────────────────
    // La surface (celle des volets, raccordée à la barre par son coin
    // creusé ; celui de droite sort de l'écran) et son contenu. Pendant le
    // génie, il ne se montre que par son image.
    Item {
        id: sheet
        anchors.fill: parent
        visible: panel.live

        Lip {
            x: panel.lipR
            width: panel.panelW
            height: parent.height
        }

        Item {
            id: panelArea
            x: panel.lipR
            width: panel.panelW
            height: parent.height

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

                    // Le fond de l'onglet ouvert : une pastille qui glisse de l'un à
                    // l'autre (et s'efface hors des onglets).
                    Rectangle {
                        id: tabPill
                        readonly property int index: panel.tabIndex(Widgets.panelTab)
                        readonly property bool onTab: tabPill.index < panel.tabs.length
                        property real at: tabPill.onTab ? tabPill.index : 0
                        Behavior on at { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                        x: tabRow.x + tabPill.at * (tabRow.unit + tabRow.spacing)
                        y: tabRow.y
                        width: tabRow.unit
                        height: tabRow.height
                        radius: Theme.radiusSmall
                        color: Theme.bgDeep
                        opacity: tabPill.onTab ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }

                    Row {
                        id: tabRow
                        anchors.fill: parent
                        anchors.margins: 3
                        spacing: 3

                        // Tous de la même largeur, toujours avec leur nom : l'onglet
                        // ouvert se distingue par son fond, pas par sa taille.
                        readonly property real unit: (tabRow.width - (panel.tabs.length - 1) * tabRow.spacing) / panel.tabs.length

                        Repeater {
                            model: panel.tabs

                            Rectangle {
                                id: tab
                                required property var modelData
                                readonly property bool active: Widgets.panelTab === tab.modelData.key

                                width: tabRow.unit
                                height: tabRow.height
                                radius: Theme.radiusSmall
                                color: !tab.active && tabMa.containsMouse ? Theme.hoverOverlay : "transparent"
                                Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 7

                                    NixIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconSize: 16
                                        source: "../assets/ui/" + tab.modelData.icon
                                        color: tab.active ? Theme.accentColor : Theme.iconColor
                                        opacity: tab.active || tabMa.containsMouse ? 1 : 0.75
                                        Behavior on color { ColorAnimation { duration: 260 } }
                                        Behavior on opacity { NumberAnimation { duration: 200 } }
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
                                        // Trop étroit pour le nom entier : il s'abrège ; pour
                                        // un nom lisible, il s'efface et l'icône reste seule.
                                        readonly property real room: tab.width - 16 - 7 - 12
                                                        - (waitBadge.visible ? waitBadge.width + 7 : 0)
                                        visible: room >= 34
                                        width: Math.min(implicitWidth, room)
                                        elide: Text.ElideRight
                                        text: tab.modelData.label
                                        font.family: panel.uiFont
                                        font.pixelSize: 12
                                        font.weight: Font.Medium
                                        color: tab.active ? Theme.textPrimary : Theme.textSecondary
                                        Behavior on color { ColorAnimation { duration: 260 } }
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
                // Deux emplacements qui alternent : celui qui reçoit le nouvel
                // onglet le charge, puis l'amène ; l'autre s'en va et se décharge.
                Item {
                    id: stage
                    anchors.top: tabBar.bottom
                    anchors.topMargin: 16
                    anchors.left: parent.left
                    anchors.leftMargin: 6
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom

                    property bool frontA: true

                    Connections {
                        target: Widgets
                        function onPanelTabChanged() {
                            var incoming = stage.frontA ? paneB : paneA;
                            var outgoing = stage.frontA ? paneA : paneB;
                            // Vers la droite des onglets : la nouvelle vue vient de
                            // droite, l'ancienne part à gauche ; et inversement.
                            var dir = panel.tabIndex(Widgets.panelTab) >= panel.tabIndex(outgoing.key) ? 1 : -1;
                            outgoing.leave(-dir);
                            incoming.enter(Widgets.panelTab, dir);
                            stage.frontA = !stage.frontA;
                        }
                    }

                    ViewPane { id: paneA; front: stage.frontA }
                    ViewPane { id: paneB; front: !stage.frontA }
                    Component.onCompleted: paneA.key = Widgets.panelTab
                }

                // Une vue : chargée tant qu'elle est devant ou qu'elle s'efface.
                // `t` va de 0 (absente, décalée vers `side`) à 1 (à sa place).
                component ViewPane: Loader {
                    id: pane
                    property string key: ""
                    property bool front: false
                    property real t: 0
                    property int side: 1

                    anchors.fill: parent
                    asynchronous: true
                    active: panel.live && pane.key !== "" && (pane.front || pane.t > 0)
                    sourceComponent: ({
                        "music": musicView, "files": filesView, "system": systemView,
                        "agenda": agendaView, "claude": claudeView, "settings": settingsView
                    })[pane.key] || musicView

                    opacity: pane.t
                    transform: Translate { x: (1 - pane.t) * pane.side * 28 }
                    // La vue qui part ne prend plus la souris.
                    enabled: pane.front

                    function enter(key, dir) {
                        outAnim.stop();
                        pane.side = dir;
                        pane.t = 0;
                        pane.key = key;
                        pane.arrive();
                    }
                    function leave(dir) {
                        inAnim.stop();
                        pane.side = dir;
                        outAnim.restart();
                    }
                    // Elle n'arrive qu'une fois chargée : pas de vide qui glisse.
                    function arrive() {
                        if (pane.front && pane.status === Loader.Ready && pane.t < 1 && !inAnim.running)
                            inAnim.restart();
                    }
                    onStatusChanged: pane.arrive()
                    onFrontChanged: pane.arrive()
                    Component.onCompleted: pane.arrive()

                    SequentialAnimation {
                        id: inAnim
                        // Le temps que l'ancienne commence à partir.
                        PauseAnimation { duration: 70 }
                        NumberAnimation { target: pane; property: "t"; to: 1; duration: 380; easing.type: Easing.OutQuint }
                    }
                    NumberAnimation {
                        id: outAnim
                        target: pane
                        property: "t"
                        to: 0
                        duration: 170
                        easing.type: Easing.InCubic
                    }
                }

                Component { id: musicView; MusicView {} }
                // Ouvrir un fichier ne referme pas le panneau : il reste là.
                Component { id: filesView; FileExplorer {} }
                Component { id: systemView; FleetView {} }
                // Un onglet, où mène aussi la palette de la barre (« Tous les
                // réglages »).
                Component { id: settingsView; Settings { showInternalHeader: false } }
                Component { id: agendaView; CalendarWidget {} }
                Component { id: claudeView; ClaudeView {} }
            }

        }
    }

    // ── Le génie ─────────────────────────────────────────────────
    // L'image du panneau ouvert, sur une grille fine en hauteur (les flancs
    // s'incurvent) : shaders/genie.vert la tire vers le bouton.
    ShaderEffect {
        id: genie
        anchors.fill: parent
        visible: panel.reveal > 0 && !panel.settled

        property real t: 1 - panel.reveal
        property real itemW: genie.width
        property real itemH: genie.height
        property real buttonL: genie.width - panel.buttonInset - panel.buttonWidth
        property real buttonR: genie.width - panel.buttonInset
        property var source: ShaderEffectSource {
            sourceItem: sheet
            hideSource: genie.visible
            live: true
        }

        mesh: GridMesh { resolution: Qt.size(8, 64) }
        vertexShader: Qt.resolvedUrl("../shaders/genie.vert.qsb")
        fragmentShader: Qt.resolvedUrl("../shaders/genie.frag.qsb")
    }

    // ── Le bord gauche, qui se tire ──────────────────────────────
    // Rien ne le montre : le curseur change au survol. La fenêtre garde son
    // bord droit collé à l'écran ; tirer vers la gauche l'élargit.
    MouseArea {
        x: panel.lipR
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 8
        enabled: panel.settled
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
                                                     panel.panelW - (mouse.x - pressX))));
        }
    }
}
