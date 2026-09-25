pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtCore
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import "../services"
import "../ai"
// Les cartes sont instanciées par URL (setSource), ce qui les rend invisibles
// au scanner de quickshell : sans cet import statique, modifier une carte ne
// déclenche aucun rechargement du shell.
import "cards" // qmllint disable unused-imports

// Le dock du bas : il se glisse depuis le bord au survol, et sert trois choses
// sur une même surface.
//   • requête vide  → navigation, le contenu du dossier courant ;
//   • requête       → résultats, tous types mélangés et classés par pertinence ;
//   • mode IA (✦)   → les conversations Claude de la machine, celle du centre
//                     du carrousel lisible et reprenable juste au-dessus.
//
// Les trois vues partagent un seul carrousel (cf. CardCarousel) : c'est le
// modèle qui change, jamais la mécanique. Ce fichier ne fournit que le contenu
// — la liste plate de cartes, la géométrie, et ce que « activer » veut dire —,
// il ne sait rien de la façon dont la bande tourne.
//
// La chrome (recherche, mode IA, disposition) tient sur une seule rangée
// posée contre le bord bas de l'écran, centrée en largeur.
//
// Deux dispositions, au choix : ruban (une rangée, cartes allongées) ou
// quadrillage (deux rangées, cartes carrées). Le ruban est le défaut. Le
// quadrillage n'est pas une autre mécanique : le carrousel découpe alors la
// liste en colonnes de deux, et la colonne devient le pas du défilement.
//
// Deux fenêtres, à dessein. La région d'entrée de la bande de bord ne change
// jamais, donc son survol est un signal stable ; celle du deck n'apparaît
// qu'à côté de cette bande, jamais sous un curseur qui s'y trouve.
Scope {
    id: dock

    property var screen: null
    property bool active: true

    // Ouverture au clavier (« dock » sur le FIFO IPC, câblé sur le tap de
    // Super). Le dock reste alors ouvert sans curseur dessus, jusqu'au tap
    // suivant ou à Échap ; le survol garde son comportement habituel.
    // Le dock ne se déverrouille jamais lui-même : il émet closeRequested()
    // et c'est shell.qml, seul propriétaire de l'état, qui retombe pinned.
    property bool pinned: false
    signal closeRequested()

    // ── Sélection clavier ────────────────────────────────────────
    // Le champ de recherche garde le focus tant que le dock est ouvert. Il n'y
    // a pas d'index promené sur la bande : la carte retenue est celle du centre
    // du carrousel, toujours. Les flèches font tourner le carrousel, Entrée
    // active ce qui se trouve au milieu.

    // Ce que la bande montre, selon la vue. Une seule liste plate de cartes,
    // quel qu'en soit le type : c'est ce qui permet au carrousel d'être le même
    // partout (cf. CardCarousel).
    readonly property var items: dock.aiMode
                                 ? dock.aiCards
                                 : (Search.active ? Search.results : dock.browseItems)

    // Le quadrillage empile deux cartes par colonne, le ruban une seule. Le
    // mode IA n'a qu'une rangée : une conversation se choisit dans une file,
    // pas dans une grille.
    readonly property int rows: dock.aiMode
                                ? 1
                                : (dock.viewMode === dock.modeGrid ? 2 : 1)

    // Rien à imposer aux cartes pour l'instant : toutes les vues les traitent
    // de la même façon. Le point d'entrée reste, il ne coûte rien.
    readonly property var cardProps: ({})

    // On ne descend dans l'arborescence qu'en navigation : une requête ou une
    // conversation n'a pas de dossier courant.
    readonly property bool browsing: !dock.aiMode && !Search.active

    // ── Mode IA ──────────────────────────────────────────────────
    // Une troisième vue, à côté de la navigation et des résultats : les
    // conversations Claude de la machine, et celle du centre lisible juste
    // au-dessus. Ici le carrousel tourne pour de bon — la carte retenue ne
    // bouge pas, c'est la bande qui défile dessous, et elle boucle.
    property bool aiMode: false

    // En mode IA le champ de recherche filtre les sessions sur place ; il ne
    // part pas dans Search, qui basculerait le dock en vue résultats.
    property string aiQuery: ""

    readonly property var aiSessions: {
        var all = ClaudeSessions.liveSessions;
        var q = dock.aiQuery.trim();
        if (q.length === 0)
            return all;

        var out = [];
        for (var i = 0; i < all.length; i++) {
            var s = all[i];
            if (Fuzzy.best(q, [s.title, s.project]) > 0)
                out.push(s);
        }
        return out;
    }

    // Une session devient une carte comme une autre : même forme que ce que
    // produisent les sources de recherche, donc même carrousel et même carte.
    readonly property var aiCards: dock.aiSessions.map(function (s) {
        return {
            "type":     "conversation",
            "id":       "conv:" + s.id,
            "title":    s.title,
            "subtitle": s.project,
            "meta":     ClaudeSessions.ago(s.at),
            "tone":     Theme.colorCoral,
            "score":    0,
            "payload":  { "id": s.id, "kind": s.kind, "cwd": s.cwd, "path": s.path }
        };
    })

    // Le volet de lecture n'a pas à s'étaler sur toute la largeur de l'écran :
    // une ligne de texte de 1500 px ne se lit pas. Il tient dans une colonne
    // centrée, posée juste au-dessus de la carte du centre — celle dont il
    // montre la conversation.
    readonly property int transcriptW: 780

    // Et il lui faut de la hauteur : c'est une conversation, pas une ligne
    // d'état. Le mode IA prend franchement le bas de l'écran — mais reste
    // borné, pour qu'un petit écran garde de la place ailleurs.
    readonly property int transcriptH: {
        var h = dock.screen ? dock.screen.height : 1080;
        return Math.max(220, Math.min(430, Math.round(h * 0.42)));
    }

    // L'écart entre la plaque du volet et la bande. Plus large que celui de la
    // chrome : c'est ce qui détache la lecture du carrousel au lieu de les
    // empiler.
    readonly property int transcriptGap: 20

    // Le chemin du carrousel porte `deckItems` cartes ; sa longueur en découle,
    // puisque PathView les espace d'une fraction 1/deckItems. Les extrémités
    // sont transparentes, c'est là que le tour se referme sans qu'on le voie.
    readonly property int deckItems: 9
    readonly property real deckSpan: dock.cellW * dock.deckItems / 2

    // ── Design tokens ────────────────────────────────────────────
    readonly property int hotZone:   6
    readonly property int tileInset: 5
    readonly property int hMargin:   14
    readonly property int searchH:   32
    readonly property int searchW:   320
    // Hauteur du dégradé qui assombrit le bord bas. Il déborde largement la
    // bande des cartes, hors du masque d'entrée : il s'affiche sans jamais
    // intercepter un clic.
    readonly property int scrimHeight: 260

    // ── Disposition ──────────────────────────────────────────────
    readonly property int modeList: 0
    readonly property int modeGrid: 1
    property int viewMode: dock.modeList

    // Les cartes gardent la même tuile dans les deux dispositions : c'est le
    // nombre de rangées qui change, pas leur taille. La tuile est celle d'une
    // icône : l'image la remplit, le nom et les boutons se posent dessus (cf.
    // CardFrame), et la hauteur est calée pour qu'il reste de l'icône à voir
    // entre les deux.
    readonly property int rowH: 164
    readonly property real bandH: dock.rowH * dock.rows

    readonly property real cellH: dock.rowH
    readonly property real cellW: 150
    readonly property int cardInset: 5

    // La carte est moins haute que sa cellule de la profondeur de l'arc : le
    // décalage du carrousel se fait dans cette réserve, donc à l'intérieur de la
    // vue, qui rognerait tout ce qui dépasse de son bord.
    readonly property real cardH: dock.cellH - dock.cardInset * 2 - dock.arcDepth
    readonly property real cardW: dock.cellW - dock.cardInset * 2

    // Hauteur totale du deck : la chrome contre le bord, la bande des cartes
    // au-dessus, et l'encoche de part et d'autre. Le mode IA pousse le volet de
    // lecture par-dessus, donc le deck grandit d'autant.
    readonly property int deckHeight: dock.tileInset * 2 + dock.searchH + 8
                                      + (dock.aiMode
                                         ? dock.rowH + dock.transcriptGap + dock.transcriptH
                                         : dock.bandH)

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
    property bool deckHovered: false
    readonly property bool pointerInside: edgeHovered || deckHovered

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

    onPinnedChanged: {
        if (dock.pinned) {
            openTimer.stop();
            closeTimer.stop();
            dock.dockOpen = true;
        } else if (!dock.pointerInside) {
            dock.dockOpen = false;
        }
    }

    onDockOpenChanged: {
        if (dockOpen) {
            graceTimer.restart();
            // Le dock s'ouvre prêt à écrire : la surface est en OnDemand, elle
            // ne réclame le clavier qu'à cet instant.
            searchField.forceActiveFocus();
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
        onTriggered: dock.dockOpen = true
    }

    // La fermeture est différée *et* revérifiée : un couple leave/enter
    // parasite ne peut donc pas refermer le dock.
    Timer {
        id: closeTimer
        interval: 340
        onTriggered: {
            // Ouvert au clavier : c'est un nouveau tap (ou Échap) qui referme,
            // jamais la sortie du curseur.
            if (dock.pinned)
                return;
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

    // Le dossier courant, mis à la forme d'une liste de cartes — la même que
    // celle des sources de recherche. `folderModel.get()` n'est pas observable,
    // donc on relit à chaque événement qui peut avoir changé le contenu.
    property var browseItems: []

    function rebuildBrowse() {
        var n = Math.min(folderModel.count, dock.browseCap);
        var out = [];

        for (var i = 0; i < n; i++) {
            var path = folderModel.get(i, "filePath");
            var isDir = folderModel.get(i, "fileIsDir");
            var suffix = folderModel.get(i, "fileSuffix") || "";

            out.push({
                "type":     "file",
                "id":       "browse:" + path,
                "title":    folderModel.get(i, "fileName"),
                "subtitle": isDir ? "dossier" : "",
                "meta":     isDir ? "" : suffix.toUpperCase(),
                "tone":     dock.toneFor(suffix, isDir),
                "score":    0,
                "payload":  { "path": path, "isDir": isDir, "suffix": suffix }
            });
        }

        dock.browseItems = out;
    }

    // ── Carrousel ────────────────────────────────────────────────
    // La profondeur de l'arc sur lequel les cartes sont posées : celle du
    // centre monte vers l'intérieur de l'écran, celles qui s'en éloignent
    // redescendent vers le bord — d'où le fondu à gauche comme à droite, sans
    // dégradé posé par-dessus. La mécanique est dans CardCarousel.
    readonly property int arcDepth: 14

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

    // ── Activation ───────────────────────────────────────────────
    // La carte du centre, et elle seule. Même règle au clic et à Entrée, quel
    // que soit le type : c'est ici qu'on décide ce que « lancer » veut dire,
    // plus dans chaque carte.
    //
    // Activer, c'est ouvrir dans l'application par défaut — un dossier comme un
    // fichier, `xdg-open` s'occupe des deux. Entrer dans un dossier est un
    // autre geste : les flèches haut/bas.
    function activateCard(item) {
        if (!item)
            return;

        // En mode IA la carte du centre est déjà lue : l'activer, c'est
        // descendre dans la conversation pour la poursuivre.
        if (dock.aiMode) {
            transcript.focusComposer();
            return;
        }

        Search.activate(item, item.type === "conversation"
                              && item.payload.kind !== "desktop" ? "resume" : "open");
    }

    // ── Réglage sur place ────────────────────────────────────────
    // Certaines cartes portent une valeur qui se règle sans rien ouvrir — le
    // volume, la teinte de l'accent. Sur celles-là, haut et bas modifient au
    // lieu de naviguer. C'est la carte qui le déclare dans sa charge utile : le
    // dock n'a pas à connaître les réglages un par un.
    function adjustCurrent(dir) {
        var card = carousel.currentCard;
        if (!card || !card.payload || !card.payload.adjust)
            return false;
        Search.activate(card, dir > 0 ? "up" : "down");
        return true;
    }

    // ── Arborescence ─────────────────────────────────────────────
    // Haut et bas ne promènent pas une sélection : ils montent et descendent
    // dans les dossiers. La bande, elle, ne bouge qu'à gauche/droite.
    function descend() {
        if (!dock.browsing)
            return false;
        var card = carousel.currentCard;
        if (!card || card.type !== "file" || !card.payload.isDir)
            return false;
        dock.currentFolder = dock.folderUrl(card.payload.path);
        return true;
    }

    function ascend() {
        if (!dock.browsing || dock.currentFolder.toString() === "file:///")
            return false;
        dock.currentFolder = folderModel.parentFolder;
        return true;
    }

    // ── Entrée et sortie du mode IA ──────────────────────────────
    function enterAiMode() {
        if (dock.aiMode)
            return;
        // La requête en cours appartenait à la recherche : le mode IA repart
        // d'un champ vide, qui filtrera les sessions et non plus le disque.
        searchField.text = "";
        Search.clear();
        dock.aiMode = true;
        ClaudeSessions.ensureIndex();
        Qt.callLater(dock.syncAiFocus);
    }

    function leaveAiMode() {
        if (!dock.aiMode)
            return;
        dock.aiMode = false;
        searchField.text = "";
        dock.aiQuery = "";
        // Le CLI resté ouvert pour la reprise n'a plus personne à qui parler.
        ClaudeSessions.stopAgent();
        ClaudeSessions.focus(null);
        searchField.forceActiveFocus();
    }

    // La carte au centre du carrousel *est* la session lue : tout ce qui fait
    // tourner la bande repasse par ici.
    function syncAiFocus() {
        var list = dock.aiSessions;
        if (!dock.aiMode || list.length === 0) {
            ClaudeSessions.focus(null);
            return;
        }
        var i = Math.max(0, Math.min(list.length - 1, carousel.currentIndex));
        ClaudeSessions.focus(list[i]);
    }

    // Filtrer rebat la bande : le carrousel repart du début de lui-même, mais
    // c'est à nous de rouvrir la conversation qui se retrouve au centre.
    onAiSessionsChanged: {
        if (dock.aiMode)
            Qt.callLater(dock.syncAiFocus);
    }

    // ── Edge strip ───────────────────────────────────────────────
    PanelWindow { // qmllint disable uncreatable-type
        id: edge

        screen: dock.screen
        visible: dock.active

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-dockedge"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors { left: true; right: true; bottom: true }
        implicitHeight: dock.hotZone
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
        visible: dock.active

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-bottomdock"
        // Ouvert au clavier, le dock prend le focus pour de bon : en OnDemand,
        // le compositeur ne route les frappes vers une layer qu'une fois
        // cliquée — le champ aurait le focus côté Qt sans jamais rien recevoir.
        // Au survol on reste en OnDemand : passer la souris au bord bas ne
        // doit pas détourner ce qu'on est en train de taper ailleurs.
        WlrLayershell.keyboardFocus: dock.pinned ? WlrKeyboardFocus.Exclusive
                                                 : WlrKeyboardFocus.OnDemand

        anchors { left: true; right: true; bottom: true }

        // La bande des cartes, celle de bord contre laquelle elle bute, et la
        // traîne du dégradé — qui sert aussi de mou pour que le glissement parte
        // hors de l'écran.
        implicitHeight: dock.deckHeight + dock.hotZone + dock.scrimHeight
        exclusiveZone: 0
        color: "transparent"

        mask: Region { // qmllint disable unqualified
            x: 0
            y: dock.dockOpen ? panel.height - dock.hotZone - dock.deckHeight : panel.height
            width: panel.width
            height: dock.dockOpen ? dock.deckHeight : 0
        }

        // ── Fond ─────────────────────────────────────────────────
        // Assombrit progressivement le bord bas pour détacher le carrousel du
        // fond d'écran. Il se fond, il ne glisse pas : c'est un décor.
        Rectangle {
            anchors.fill: parent

            opacity: dock.dockOpen ? 1.0 : 0.0
            visible: opacity > 0.001

            Behavior on opacity {
                NumberAnimation { duration: 340; easing.type: Easing.OutCubic }
            }

            gradient: Gradient {
                orientation: Gradient.Vertical

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

            height: dock.deckHeight
            anchors.bottom: parent.bottom
            anchors.bottomMargin: dock.hotZone
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: dock.hMargin
            anchors.rightMargin: dock.hMargin

            opacity: dock.dockOpen ? 1.0 : 0.0
            visible: opacity > 0.001

            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            transform: Translate {
                y: dock.dockOpen ? 0 : dock.deckHeight + dock.hotZone
                Behavior on y {
                    NumberAnimation { duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.7 }
                }
            }

            HoverHandler {
                onHoveredChanged: dock.deckHovered = hovered
            }

            // ── Recherche ────────────────────────────────────────
            // La chrome tient contre le bord bas : c'est le carrousel qui
            // occupe la place gagnée vers l'intérieur de l'écran.
            Rectangle {
                id: searchPill

                anchors.bottom: parent.bottom
                anchors.bottomMargin: dock.tileInset

                // Recherche et boutons forment un seul bloc, centré sur la
                // rangée : on décale la pastille de la moitié de ce qui la
                // suit, pour que ce soit le groupe — et non le seul champ —
                // qui tombe au milieu. La bascule ruban/quadrillage s'efface
                // en mode IA, le groupe se recentre donc de lui-même.
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.horizontalCenterOffset:
                    -(6 + dock.searchH + (dock.aiMode ? 0 : 6 + dock.searchH)) / 2

                Behavior on anchors.horizontalCenterOffset {
                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                }

                width: dock.searchW
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

                    placeholderText: dock.aiMode ? "filtrer les sessions…" : "rechercher…"
                    placeholderTextColor: Theme.placeholderColor
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    color: Theme.textPrimary
                    background: Item {}
                    leftPadding: 0
                    rightPadding: 0

                    // En mode IA le champ ne cherche plus, il filtre la bande.
                    onTextChanged: {
                        if (dock.aiMode)
                            dock.aiQuery = text;
                        else
                            Search.query = text;
                    }

                    // Entrée active la carte du centre — la seule qui agisse,
                    // quelle que soit la vue.
                    Keys.onReturnPressed: carousel.activateCurrent()
                    Keys.onEnterPressed: carousel.activateCurrent()

                    // Le carrousel tourne de gauche à droite : gauche/droite
                    // sont donc ses flèches, et elles gardent la main sur le
                    // curseur du champ — sans quoi on ne pourrait plus le faire
                    // tourner sans effacer sa requête. Le curseur se pose à la
                    // souris, ou aux touches Origine / Fin.
                    Keys.onRightPressed: carousel.moveColumn(1)
                    Keys.onLeftPressed: carousel.moveColumn(-1)

                    // Haut et bas travaillent en profondeur, pas le long de la
                    // bande : sur une carte réglable ils modifient la valeur,
                    // sinon ils montent et descendent dans les dossiers. En
                    // mode IA, bas descend dans la conversation.
                    Keys.onUpPressed: (event) => {
                        if (dock.adjustCurrent(1))
                            return;
                        if (!dock.ascend())
                            event.accepted = false;
                    }

                    Keys.onDownPressed: (event) => {
                        if (dock.aiMode) {
                            transcript.focusComposer();
                            return;
                        }
                        if (dock.adjustCurrent(-1))
                            return;
                        if (!dock.descend())
                            event.accepted = false;
                    }

                    Keys.onPressed: (event) => {
                        // Champ vide, en navigation : Retour arrière remonte
                        // d'un cran, comme la flèche haut — c'est le geste
                        // attendu dans un explorateur.
                        if (event.key === Qt.Key_Backspace
                                && searchField.text.length === 0) {
                            event.accepted = dock.ascend();
                            return;
                        }

                        // Les flèches haut/bas servent à l'arborescence : c'est
                        // Tab qui fait le tour des rangées du quadrillage.
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            if (dock.rows > 1) {
                                carousel.cycleRow();
                                event.accepted = true;
                            }
                        }
                    }

                    Keys.onEscapePressed: {
                        if (text.length > 0) {
                            text = "";
                        } else if (dock.aiMode) {
                            // Le mode IA se quitte avant le dock : une seule
                            // échappée par cran, comme ailleurs.
                            dock.leaveAiMode();
                        } else {
                            focus = false;
                            // Ouvert au clavier : Échap referme aussi le dock,
                            // sinon il resterait épinglé sans plus rien à faire.
                            if (dock.pinned)
                                dock.closeRequested();
                        }
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

            // ── Bascule du mode IA ───────────────────────────────
            // Allumé, le dock montre les conversations Claude au lieu du
            // disque : la bande devient un carrousel de sessions, et celle du
            // centre se lit juste au-dessus.
            Rectangle {
                id: aiButton

                anchors.verticalCenter: searchPill.verticalCenter
                anchors.left: searchPill.right
                anchors.leftMargin: 6
                width: dock.searchH
                height: dock.searchH
                radius: height / 2

                color: dock.aiMode
                       ? Qt.rgba(Theme.accentColor.r, Theme.accentColor.g,
                                 Theme.accentColor.b, 0.18)
                       : (aiHover.hovered
                          ? (Theme.darkMode ? Qt.lighter(Theme.bgElevated, 1.55)
                                            : Qt.darker(Theme.bgElevated, 1.06))
                          : Theme.bgElevated)
                scale: aiTap.pressed ? 0.9 : 1.0

                Behavior on color { ColorAnimation { duration: 160 } }
                Behavior on scale {
                    NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
                }

                Text {
                    anchors.centerIn: parent
                    text: "✦"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 13
                    color: dock.aiMode || aiHover.hovered ? Theme.accentColor
                                                          : Theme.textSecondary

                    Behavior on color { ColorAnimation { duration: 140 } }
                }

                HoverHandler { id: aiHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    id: aiTap
                    onTapped: {
                        if (dock.aiMode)
                            dock.leaveAiMode();
                        else
                            dock.enterAiMode();
                    }
                }
            }

            // ── Bascule ruban / quadrillage ──────────────────────
            // Le bouton montre la disposition vers laquelle il emmène. Le mode
            // IA n'a qu'une rangée : la bascule s'efface alors, largeur comprise,
            // pour que le fil d'Ariane se recolle à sa gauche.
            Rectangle {
                id: modeButton

                anchors.verticalCenter: searchPill.verticalCenter
                anchors.left: aiButton.right
                anchors.leftMargin: 6
                width: dock.aiMode ? 0 : dock.searchH
                height: dock.searchH
                radius: height / 2
                visible: !dock.aiMode

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

                // Trois colonnes → revenir au ruban.
                Item {
                    anchors.centerIn: parent
                    width: 13
                    height: 13
                    visible: !modeButton.showsGrid

                    Repeater {
                        model: 3

                        Rectangle {
                            required property int index

                            width: 2.5
                            height: 13
                            radius: 1.25
                            x: index * 5.2
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

            // Pas de fil d'Ariane : la rangée ne porte que la recherche et ses
            // boutons, centrés. Le dossier courant se lit sur les cartes, et on
            // remonte d'un cran au clavier (flèche haut ou Retour arrière).

            // De quoi on parcourt en mode IA, et combien il en reste une fois
            // filtré. Rangé dans le coin, pour ne pas déséquilibrer le groupe
            // centré.
            Text {
                id: aiCrumb

                anchors.right: parent.right
                anchors.rightMargin: dock.tileInset + 6
                anchors.verticalCenter: searchPill.verticalCenter
                horizontalAlignment: Text.AlignRight

                visible: opacity > 0.001
                opacity: dock.aiMode ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                text: {
                    var n = dock.aiSessions.length;
                    var total = ClaudeSessions.liveSessions.length;
                    if (ClaudeSessions.indexing && total === 0)
                        return "lecture des sessions…";
                    if (n === total)
                        return total + (total > 1 ? " sessions" : " session");
                    return n + " / " + total;
                }
                color: Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                elide: Text.ElideRight
            }

            // ── La bande ─────────────────────────────────────────
            // Un seul carrousel pour les trois vues : c'est le modèle qui
            // change, jamais la mécanique. Fichier, réglage, page web ou
            // conversation, une carte se parcourt et s'active de la même façon.
            CardCarousel {
                id: carousel

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: searchPill.top
                anchors.bottomMargin: 8
                height: dock.aiMode ? dock.rowH : dock.bandH

                items: dock.items
                rows: dock.rows
                cardFor: dock.cardFor
                cardProps: dock.cardProps

                cellW: dock.cellW
                cellH: dock.cellH
                cardW: dock.cardW
                cardH: dock.cardH
                cardInset: dock.cardInset
                arcDepth: dock.arcDepth
                columnsOnPath: dock.deckItems

                onActivated: (item) => dock.activateCard(item)

                // La carte du centre *est* la session lue : en mode IA, faire
                // tourner le carrousel, c'est changer de conversation.
                onCurrentIndexChanged: dock.syncAiFocus()
            }

            // Non visuel, mais posé ici : c'est lui qui alimente la bande en
            // mode navigation.
            FolderListModel {
                id: folderModel

                folder: dock.currentFolder
                showDirsFirst: true
                showDotAndDotDot: false
                showHidden: false
                sortField: FolderListModel.Name

                // `get()` n'est pas une propriété observable : s'en remettre à
                // une liaison laisserait la bande sur l'ancien dossier chaque
                // fois que le nouveau a le même nombre d'entrées. On relit donc
                // explicitement, à chaque événement qui peut avoir changé le
                // contenu.
                onCountChanged:  dock.rebuildBrowse()
                onStatusChanged: dock.rebuildBrowse()
                onFolderChanged: dock.rebuildBrowse()
            }

            // Le volet de lecture du mode IA, posé au-dessus de la bande : la
            // conversation de la carte retenue, et de quoi la poursuivre.
            SessionTranscript {
                id: transcript

                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: carousel.top
                anchors.bottomMargin: dock.transcriptGap
                width: Math.min(parent.width - (dock.tileInset + 4) * 2, dock.transcriptW)
                height: dock.transcriptH

                visible: dock.aiMode
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200 } }

                // Sortir du champ de saisie rend la main au carrousel.
                onEscaped: searchField.forceActiveFocus()
            }

            // Rien à montrer : on le dit, plutôt que d'afficher du vide. En
            // mode IA c'est le volet qui s'en charge, il a la place.
            Text {
                anchors.left: parent.left
                anchors.leftMargin: dock.tileInset + 4
                anchors.verticalCenter: carousel.verticalCenter

                visible: !dock.aiMode && dock.items.length === 0
                text: Search.active ? "aucun résultat" : "dossier vide"
                color: Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 10
            }
        }
    }
}
