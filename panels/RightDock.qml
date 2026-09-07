pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtCore
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import "../services"
// Les cartes sont instanciées par URL (setSource), ce qui les rend invisibles
// au scanner de quickshell : sans cet import statique, modifier une carte ne
// déclenche aucun rechargement du shell.
import "cards" // qmllint disable unused-imports

// Le dock de droite : il se glisse depuis le bord au survol, et sert deux
// choses sur une même surface.
//   • requête vide  → navigation, le contenu du dossier courant ;
//   • requête       → résultats, tous types mélangés et classés par pertinence.
//
// Deux dispositions, au choix : liste (une colonne, cartes allongées) ou
// quadrillage (deux colonnes, cartes carrées). La liste est le défaut.
//
// Deux fenêtres, à dessein. La région d'entrée de la bande de bord ne change
// jamais, donc son survol est un signal stable ; celle de la grille n'apparaît
// qu'à côté de cette bande, jamais sous un curseur qui s'y trouve.
Scope {
    id: dock

    property var screen: null
    property bool active: true

    // Le RightPanel occupe le même bord : tant qu'il est ouvert, le dock se
    // retire complètement — bande d'entrée comprise — plutôt que de se glisser
    // par-dessus lui.
    property bool blocked: false

    // ── Design tokens ────────────────────────────────────────────
    readonly property int hotZone:   6
    readonly property int gridWidth: 340
    readonly property int tileInset: 5
    readonly property int vMargin:   14
    readonly property int searchH:   32
    // Largeur du dégradé qui assombrit le bord droit. Il déborde largement la
    // colonne des cartes, hors du masque d'entrée : il s'affiche sans jamais
    // intercepter un clic.
    readonly property int scrimWidth: 320
    readonly property int headerH:   24

    // ── Disposition ──────────────────────────────────────────────
    readonly property int modeList: 0
    readonly property int modeGrid: 1
    property int viewMode: dock.modeList

    readonly property real innerWidth: dock.gridWidth - dock.tileInset * 2
    readonly property real cellW: dock.viewMode === dock.modeGrid
                                  ? dock.innerWidth / 2 : dock.innerWidth
    readonly property real cellH: dock.viewMode === dock.modeGrid
                                  ? dock.cellW : 104
    readonly property int cardInset: 5

    // La carte est plus étroite que sa cellule de la profondeur de l'arc : le
    // décalage du carrousel se fait dans cette réserve, donc à l'intérieur de la
    // vue, qui rognerait tout ce qui dépasse de son bord.
    readonly property real cardW: dock.cellW - dock.cardInset * 2 - dock.arcDepth
    readonly property real cardH: dock.viewMode === dock.modeGrid
                                  ? dock.cardW : dock.cellH - dock.cardInset * 2

    // ── Registre des cartes ──────────────────────────────────────
    // Seul endroit à toucher pour brancher un nouveau type de résultat sur
    // l'affichage : la géométrie vient du mode, plus du type.
    readonly property var cardFor: ({
        "app":          "cards/AppCard.qml",
        "file":         "cards/FileCard.qml",
        "setting":      "cards/SettingCard.qml",
        "conversation": "cards/ConversationCard.qml",
        "web":          "cards/WebCard.qml"
    })

    function cardUrl(type) {
        return dock.cardFor[type] || "cards/GenericCard.qml";
    }

    // ── Open / close state ───────────────────────────────────────
    // Instancie DefaultApps dès le démarrage : la résolution des outils est
    // asynchrone, autant qu'elle soit finie avant la première carte.
    Component.onCompleted: DefaultApps.refresh()

    property bool dockOpen: false
    property bool edgeHovered: false
    property bool gridHovered: false
    readonly property bool pointerInside: edgeHovered || gridHovered

    onPointerInsideChanged: {
        if (pointerInside) {
            closeTimer.stop();
            if (!dockOpen)
                openTimer.restart();
        } else {
            openTimer.stop();
            closeTimer.restart();
        }
    }

    onBlockedChanged: if (dock.blocked) dock.dockOpen = false

    onDockOpenChanged: {
        if (dockOpen) {
            graceTimer.restart();
        } else {
            searchField.text = "";
            Search.clear();
            // La fenêtre reste visible une fois le dock refermé : sans ce
            // relâchement, le champ garderait le focus clavier et le compositeur
            // continuerait de router les frappes vers une surface invisible.
            searchField.focus = false;
        }
    }

    Timer {
        id: openTimer
        interval: 90
        onTriggered: if (!dock.blocked) dock.dockOpen = true
    }

    // La fermeture est différée *et* revérifiée : un couple leave/enter
    // parasite ne peut donc pas refermer le dock.
    Timer {
        id: closeTimer
        interval: 340
        onTriggered: {
            // Un glisser en cours emmène le curseur hors du dock : le fermer
            // détruirait la carte source et annulerait le geste.
            if (graceTimer.running || DragState.active) {
                restart();
                return;
            }
            if (!dock.pointerInside)
                dock.dockOpen = false;
        }
    }

    Timer {
        id: graceTimer
        interval: 600
    }

    // ── Navigation ───────────────────────────────────────────────
    readonly property url homeFolder: StandardPaths.writableLocation(StandardPaths.HomeLocation)
    property url currentFolder: homeFolder

    readonly property string folderLabel: {
        var parts = currentFolder.toString().split("/");
        return decodeURIComponent(parts[parts.length - 1]) || "/";
    }

    // Un chemin brut ne fait pas une URL : « # » ouvrirait un fragment, « ? » une
    // requête, et l'espace n'y a rien à faire. On encode segment par segment pour
    // garder les « / » intacts.
    function folderUrl(path) {
        var parts = path.split("/");
        for (var i = 0; i < parts.length; i++)
            parts[i] = encodeURIComponent(parts[i]);
        return "file://" + parts.join("/");
    }

    // Plafond d'affichage sur la navigation. Il ne borne pas le coût du modèle,
    // qui liste le dossier entier quoi qu'il arrive : il borne la traversée du
    // carrousel, qu'un dossier d'un million d'entrées rendrait inutilisable. On
    // en montre le début, la recherche fait le reste — c'est aussi ce que font
    // Dolphin et Nautilus.
    readonly property int browseCap: 400

    readonly property var tones: [
        Theme.accentColor, Theme.colorCyan, Theme.colorSuccess,
        Theme.colorAmber,  Theme.colorCoral, Theme.colorAltBlue
    ]

    // ── Carrousel ────────────────────────────────────────────────
    // Les cartes sont posées sur un arc : celle du centre avance vers
    // l'intérieur de l'écran, à pleine taille et pleine opacité ; celles qui
    // s'en éloignent reculent vers le bord, rapetissent et s'effacent — d'où le
    // fondu en haut comme en bas, sans dégradé posé par-dessus.
    readonly property int arcDepth: 14

    // Position d'une carte sur l'arc : 0 au centre, ±1 aux extrémités. Quand la
    // liste tient dans la hauteur, le centre de l'arc est celui du contenu et
    // non celui de la vue, sinon une liste courte serait affichée effacée.
    function arcT(cellCentre, contentY, viewH, contentH) {
        var span = Math.min(viewH, contentH) / 2;
        if (span <= 0)
            return 0;
        var focus = contentH <= viewH ? contentH / 2 : contentY + viewH / 2;
        return Math.max(-1, Math.min(1, (cellCentre - focus) / span));
    }

    function toneFor(suffix, isDir) {
        if (isDir)
            return Theme.accentColor;
        if (!suffix || suffix.length === 0)
            return Theme.textSecondary;
        var h = 0;
        for (var i = 0; i < suffix.length; i++)
            h = (h * 31 + suffix.charCodeAt(i)) % 997;
        return dock.tones[h % dock.tones.length];
    }

    // ── Edge strip ───────────────────────────────────────────────
    PanelWindow { // qmllint disable uncreatable-type
        id: edge

        screen: dock.screen
        visible: dock.active && !dock.blocked

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-dockedge"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors { top: true; right: true; bottom: true }
        implicitWidth: dock.hotZone
        exclusiveZone: 0
        color: "transparent"

        Item {
            anchors.fill: parent
            HoverHandler {
                onHoveredChanged: dock.edgeHovered = hovered
            }
        }
    }

    // ── Panel ────────────────────────────────────────────────────
    PanelWindow { // qmllint disable uncreatable-type
        id: panel

        screen: dock.screen
        visible: dock.active && !dock.blocked

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-rightdock"
        // OnDemand : le champ de recherche a besoin du clavier, mais seulement
        // une fois cliqué. Survoler le dock ne vole jamais le focus.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

        anchors { top: true; right: true; bottom: true }

        // La colonne des cartes, la bande de bord contre laquelle elle bute, et la
        // traîne du dégradé — qui sert aussi de mou pour que le glissement parte
        // hors de l'écran.
        implicitWidth: dock.gridWidth + dock.hotZone + dock.scrimWidth
        exclusiveZone: 0
        color: "transparent"

        mask: Region { // qmllint disable unqualified
            x: dock.dockOpen ? panel.width - dock.hotZone - dock.gridWidth : panel.width
            y: 0
            width: dock.dockOpen ? dock.gridWidth : 0
            height: panel.height
        }

        // ── Fond ─────────────────────────────────────────────────
        // Assombrit progressivement le bord droit pour détacher le carrousel du
        // fond d'écran. Il se fond, il ne glisse pas : c'est un décor.
        Rectangle {
            anchors.fill: parent

            opacity: dock.dockOpen ? 1.0 : 0.0
            visible: opacity > 0.001

            Behavior on opacity {
                NumberAnimation { duration: 340; easing.type: Easing.OutCubic }
            }

            gradient: Gradient {
                orientation: Gradient.Horizontal

                GradientStop {
                    position: 0.0
                    color: Qt.rgba(Theme.bgDeep.r, Theme.bgDeep.g, Theme.bgDeep.b, 0.0)
                }
                GradientStop {
                    position: 0.35
                    color: Qt.rgba(Theme.bgDeep.r, Theme.bgDeep.g, Theme.bgDeep.b, 0.22)
                }
                GradientStop {
                    position: 0.62
                    color: Qt.rgba(Theme.bgDeep.r, Theme.bgDeep.g, Theme.bgDeep.b, 0.52)
                }
                GradientStop {
                    position: 0.85
                    color: Qt.rgba(Theme.bgDeep.r, Theme.bgDeep.g, Theme.bgDeep.b, 0.78)
                }
                GradientStop {
                    position: 1.0
                    color: Qt.rgba(Theme.bgDeep.r, Theme.bgDeep.g, Theme.bgDeep.b, 0.90)
                }
            }
        }

        Item {
            id: content

            width: dock.gridWidth
            anchors.right: parent.right
            anchors.rightMargin: dock.hotZone
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: dock.vMargin
            anchors.bottomMargin: dock.vMargin

            opacity: dock.dockOpen ? 1.0 : 0.0
            visible: opacity > 0.001

            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            transform: Translate {
                x: dock.dockOpen ? 0 : dock.gridWidth + dock.hotZone
                Behavior on x {
                    NumberAnimation { duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.7 }
                }
            }

            HoverHandler {
                onHoveredChanged: dock.gridHovered = hovered
            }

            // ── Recherche ────────────────────────────────────────
            Rectangle {
                id: searchPill

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.leftMargin: dock.tileInset
                anchors.right: modeButton.left
                anchors.rightMargin: 6
                height: dock.searchH

                radius: height / 2
                color: searchHover.hovered || searchField.activeFocus
                       ? (Theme.darkMode ? Qt.lighter(Theme.bgElevated, 1.55)
                                         : Qt.darker(Theme.bgElevated, 1.06))
                       : Theme.bgElevated

                Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.accentColor
                    opacity: searchField.activeFocus ? 0.14 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }

                HoverHandler { id: searchHover; cursorShape: Qt.IBeamCursor }
                TapHandler { onTapped: searchField.forceActiveFocus() }

                Item {
                    id: magnifier
                    width: 12
                    height: 12
                    anchors.left: parent.left
                    anchors.leftMargin: 11
                    anchors.verticalCenter: parent.verticalCenter

                    readonly property color tint: searchField.activeFocus ? Theme.accentColor
                                                                         : Theme.textSecondary

                    Rectangle {
                        width: 9
                        height: 9
                        radius: 4.5
                        color: "transparent"
                        border.width: 1.4
                        border.color: magnifier.tint
                    }

                    Rectangle {
                        x: 7.5
                        y: 7.5
                        width: 5
                        height: 1.4
                        radius: 0.7
                        rotation: 45
                        transformOrigin: Item.TopLeft
                        color: magnifier.tint
                    }
                }

                TextField {
                    id: searchField

                    anchors.left: magnifier.right
                    anchors.leftMargin: 8
                    anchors.right: clearGlyph.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter

                    placeholderText: "rechercher…"
                    placeholderTextColor: Theme.placeholderColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    color: Theme.textPrimary
                    background: Item {}
                    leftPadding: 0
                    rightPadding: 0

                    onTextChanged: Search.query = text

                    Keys.onReturnPressed: {
                        var first = Search.firstItem;
                        if (first)
                            Search.activate(first, first.type === "conversation"
                                                   && first.payload.kind !== "desktop"
                                                   ? "resume" : "open");
                    }

                    Keys.onEscapePressed: {
                        if (text.length > 0)
                            text = "";
                        else
                            focus = false;
                    }
                }

                Text {
                    id: clearGlyph
                    anchors.right: parent.right
                    anchors.rightMargin: 11
                    anchors.verticalCenter: parent.verticalCenter

                    text: "✕"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: clearHover.hovered ? Theme.textPrimary : Theme.textDim
                    opacity: searchField.text.length > 0 ? 1.0 : 0.0
                    visible: opacity > 0.001

                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    Behavior on color   { ColorAnimation  { duration: 140 } }

                    HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: searchField.text = "" }
                }
            }

            // ── Bascule liste / quadrillage ──────────────────────
            // Le bouton montre la disposition vers laquelle il emmène.
            Rectangle {
                id: modeButton

                anchors.top: parent.top
                anchors.right: parent.right
                anchors.rightMargin: dock.tileInset
                width: dock.searchH
                height: dock.searchH
                radius: height / 2

                readonly property bool showsGrid: dock.viewMode === dock.modeList

                color: modeHover.hovered
                       ? (Theme.darkMode ? Qt.lighter(Theme.bgElevated, 1.55)
                                         : Qt.darker(Theme.bgElevated, 1.06))
                       : Theme.bgElevated
                scale: modeTap.pressed ? 0.9 : 1.0

                Behavior on color { ColorAnimation { duration: 160 } }
                Behavior on scale {
                    NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                }

                // Quatre carrés → passer en quadrillage.
                Item {
                    anchors.centerIn: parent
                    width: 13
                    height: 13
                    visible: modeButton.showsGrid

                    Repeater {
                        model: 4

                        Rectangle {
                            required property int index

                            width: 5.5
                            height: 5.5
                            radius: 1.5
                            x: (index % 2) * 7.5
                            y: Math.floor(index / 2) * 7.5
                            color: modeHover.hovered ? Theme.accentColor : Theme.textSecondary

                            Behavior on color { ColorAnimation { duration: 140 } }
                        }
                    }
                }

                // Trois barres → revenir en liste.
                Item {
                    anchors.centerIn: parent
                    width: 13
                    height: 13
                    visible: !modeButton.showsGrid

                    Repeater {
                        model: 3

                        Rectangle {
                            required property int index

                            width: 13
                            height: 2.5
                            radius: 1.25
                            y: index * 5.2
                            color: modeHover.hovered ? Theme.accentColor : Theme.textSecondary

                            Behavior on color { ColorAnimation { duration: 140 } }
                        }
                    }
                }

                HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    id: modeTap
                    onTapped: dock.viewMode = dock.viewMode === dock.modeList
                                              ? dock.modeGrid : dock.modeList
                }
            }

            // ── Mode navigation ──────────────────────────────────
            Item {
                id: browse

                anchors.top: searchPill.bottom
                anchors.topMargin: 8
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom

                visible: !Search.active
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Item {
                    id: header
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: dock.tileInset + 4
                    anchors.rightMargin: dock.tileInset + 4
                    height: dock.headerH

                    Text {
                        id: upGlyph
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "←"
                        color: upHover.hovered ? Theme.accentColor : Theme.textSecondary
                        font.family: "JetBrains Mono"
                        font.pixelSize: 13
                        opacity: dock.currentFolder.toString() === "file:///" ? 0.0 : 1.0

                        Behavior on color   { ColorAnimation  { duration: 140 } }
                        Behavior on opacity { NumberAnimation { duration: 140 } }

                        HoverHandler { id: upHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: dock.currentFolder = folderModel.parentFolder }
                    }

                    Text {
                        anchors.left: upGlyph.right
                        anchors.leftMargin: 8
                        anchors.right: countLabel.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: dock.folderLabel
                        color: Theme.textPrimary
                        font.family: "JetBrains Mono"
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        elide: Text.ElideMiddle
                    }

                    Text {
                        id: countLabel
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: folderModel.count > dock.browseCap
                              ? dock.browseCap + " / " + folderModel.count
                              : folderModel.count
                        color: folderModel.count > dock.browseCap ? Theme.colorWarning
                                                                  : Theme.textDim
                        font.family: "JetBrains Mono"
                        font.pixelSize: 10
                    }
                }

                GridView {
                    id: grid

                    // Le carrousel est centré : tant que la liste tient dans la
                    // hauteur disponible, la vue se réduit à son contenu et se
                    // décale pour tomber au milieu.
                    readonly property real avail: browse.height - header.height - 4

                    anchors.top: header.bottom
                    anchors.topMargin: 4
                    anchors.left: parent.left
                    anchors.leftMargin: dock.tileInset
                    anchors.right: parent.right
                    anchors.rightMargin: dock.tileInset
                    height: Math.min(contentHeight, avail)

                    transform: Translate {
                        y: Math.max(0, (grid.avail - grid.contentHeight) / 2)
                        Behavior on y {
                            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                        }
                    }

                    clip: true
                    cacheBuffer: 0

                    // La molette est pilotée à la main et animée : le défilement
                    // par à-coups de Flickable ne rend pas la fluidité voulue.
                    interactive: false
                    boundsBehavior: Flickable.StopAtBounds

                    cellWidth: dock.cellW
                    cellHeight: dock.cellH

                    NumberAnimation {
                        id: browseScroll
                        target: grid
                        property: "contentY"
                        duration: 380
                        easing.type: Easing.OutQuart
                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            var limit = Math.max(0, grid.contentHeight - grid.height);
                            var from = browseScroll.running ? browseScroll.to : grid.contentY;
                            browseScroll.to = Math.max(0, Math.min(limit,
                                from - event.angleDelta.y / 120 * 110));
                            browseScroll.restart();
                        }
                    }

                    model: Math.min(folderModel.count, dock.browseCap)

                    FolderListModel {
                        id: folderModel
                        folder: dock.currentFolder
                        showDirsFirst: true
                        showDotAndDotDot: false
                        showHidden: false
                        sortField: FolderListModel.Name
                    }

                    delegate: Item {
                        id: browseCell

                        required property int index

                        // `folderModel.get()` n'est pas une propriété observable :
                        // s'en remettre à un binding laisserait la cellule sur
                        // l'ancien dossier chaque fois que le nouveau a le même
                        // nombre d'entrées. On relit donc explicitement, à chaque
                        // événement qui peut avoir changé le contenu.
                        property string fileName: ""
                        property string filePath: ""
                        property string fileSuffix: ""
                        property bool fileIsDir: false

                        function refresh() {
                            var ok = browseCell.index < folderModel.count;
                            browseCell.fileName   = ok ? folderModel.get(browseCell.index, "fileName") : "";
                            browseCell.fileSuffix = ok ? folderModel.get(browseCell.index, "fileSuffix") : "";
                            browseCell.fileIsDir  = ok && folderModel.get(browseCell.index, "fileIsDir");
                            // En dernier : c'est lui qui déclenche le rechargement
                            // de la carte, les autres doivent déjà être à jour.
                            browseCell.filePath   = ok ? folderModel.get(browseCell.index, "filePath") : "";
                        }

                        onIndexChanged: refresh()
                        Component.onCompleted: refresh()

                        Connections {
                            target: folderModel
                            function onCountChanged()  { browseCell.refresh(); }
                            function onStatusChanged() { browseCell.refresh(); }
                            function onFolderChanged() { browseCell.refresh(); }
                        }

                        width: dock.cellW
                        height: dock.cellH

                        // Place de la carte sur l'arc du carrousel.
                        readonly property real t:
                            dock.arcT(y + height / 2, grid.contentY, grid.height, grid.contentHeight)
                        readonly property real arc: 1 - t * t

                        onFilePathChanged: cardLoader.reload()

                        Loader {
                            id: cardLoader

                            // Au centre de l'arc la carte est à gauche de sa
                            // réserve ; en s'en éloignant elle glisse vers le
                            // bord, rapetisse et s'efface.
                            x: dock.cardInset + dock.arcDepth * (1 - browseCell.arc)
                            y: (browseCell.height - dock.cardH) / 2
                            width: dock.cardW
                            height: dock.cardH

                            opacity: Math.min(1.0, browseCell.arc * 1.7)
                            scale: 0.87 + 0.13 * browseCell.arc

                            // Les propriétés requises d'une carte se passent par
                            // setSource ; on rejoue donc l'appel quand la cellule
                            // change de fichier.
                            function reload() {
                                setSource("cards/FileCard.qml", {
                                    "item": {
                                        "type": "file",
                                        "id": "browse:" + browseCell.filePath,
                                        "title": browseCell.fileName,
                                        "subtitle": browseCell.fileIsDir ? "dossier" : "",
                                        "meta": browseCell.fileIsDir ? "" : browseCell.fileSuffix.toUpperCase(),
                                        "tone": dock.toneFor(browseCell.fileSuffix, browseCell.fileIsDir),
                                        "score": 0,
                                        "payload": {
                                            "path": browseCell.filePath,
                                            "isDir": browseCell.fileIsDir,
                                            "suffix": browseCell.fileSuffix
                                        }
                                    },
                                    "navigateDirs": true
                                });
                            }

                            // Pas de `Component.onCompleted` ici : les enfants sont
                            // achevés avant leur parent, la carte serait donc créée
                            // une première fois sur des champs encore vides. C'est
                            // le `refresh()` de la cellule qui l'amorce, via
                            // `onFilePathChanged`.

                            Connections {
                                // `item` est indéfini le temps que setSource
                                // aboutisse : Connections veut null, pas undefined.
                                target: cardLoader.item || null
                                ignoreUnknownSignals: true
                                function onNavigateRequested(path) {
                                    dock.currentFolder = dock.folderUrl(path);
                                }
                            }
                        }
                    }
                }
            }

            // ── Mode résultats ───────────────────────────────────
            GridView {
                id: results

                readonly property real avail: content.height - dock.searchH - 10

                anchors.top: searchPill.bottom
                anchors.topMargin: 10
                anchors.left: parent.left
                anchors.leftMargin: dock.tileInset
                anchors.right: parent.right
                anchors.rightMargin: dock.tileInset
                height: Math.min(contentHeight, avail)

                transform: Translate {
                    y: Math.max(0, (results.avail - results.contentHeight) / 2)
                    Behavior on y {
                        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                    }
                }

                visible: Search.active
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                clip: true
                cacheBuffer: 0
                interactive: false
                boundsBehavior: Flickable.StopAtBounds

                cellWidth: dock.cellW
                cellHeight: dock.cellH

                model: Search.results

                NumberAnimation {
                    id: resultScroll
                    target: results
                    property: "contentY"
                    duration: 380
                    easing.type: Easing.OutQuart
                }

                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (event) => {
                        var limit = Math.max(0, results.contentHeight - results.height);
                        var from = resultScroll.running ? resultScroll.to : results.contentY;
                        resultScroll.to = Math.max(0, Math.min(limit,
                            from - event.angleDelta.y / 120 * 110));
                        resultScroll.restart();
                    }
                }

                // Une requête qui change remet la liste en haut, en douceur.
                Connections {
                    target: Search
                    function onResultsChanged() {
                        if (results.contentY > 0.5) {
                            resultScroll.to = 0;
                            resultScroll.restart();
                        }
                    }
                }

                delegate: Item {
                    id: resultCell

                    required property var modelData

                    width: dock.cellW
                    height: dock.cellH

                    // Place de la carte sur l'arc du carrousel.
                    readonly property real t:
                        dock.arcT(y + height / 2, results.contentY, results.height, results.contentHeight)
                    readonly property real arc: 1 - t * t

                    onModelDataChanged: resultLoader.reload()

                    Loader {
                        id: resultLoader

                        x: dock.cardInset + dock.arcDepth * (1 - resultCell.arc)
                        y: (resultCell.height - dock.cardH) / 2
                        width: dock.cardW
                        height: dock.cardH

                        opacity: Math.min(1.0, resultCell.arc * 1.7)
                        scale: 0.87 + 0.13 * resultCell.arc

                        function reload() {
                            setSource(dock.cardUrl(resultCell.modelData.type),
                                      { "item": resultCell.modelData });
                        }

                        Component.onCompleted: reload()
                    }
                }
            }

            // Rien trouvé : on le dit, plutôt que d'afficher du vide.
            Text {
                anchors.top: searchPill.bottom
                anchors.topMargin: 16
                anchors.left: parent.left
                anchors.leftMargin: dock.tileInset + 4
                visible: Search.active && Search.results.length === 0
                text: "aucun résultat"
                color: Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 10
            }
        }
    }
}
