pragma ComponentBehavior: Bound
import QtQuick
// Les cartes sont instanciées par URL (setSource), ce qui les rend invisibles
// au scanner de quickshell : sans cet import statique, modifier une carte ne
// déclenche aucun rechargement du shell.
import "cards" // qmllint disable unused-imports

// Le carrousel du dock — le même quels que soient les éléments posés dessus :
// le dossier courant, les résultats de recherche, les conversations Claude.
// Le type d'une carte décide de son dessin, jamais de sa mécanique.
//
// Il tourne. La carte retenue est clouée au milieu et n'en bouge pas : c'est la
// bande qui défile dessous, et le tour boucle — après la dernière carte on
// revient à la première sans buter. Les extrémités du chemin sont
// transparentes, donc le point de raccord ne se voit pas.
//
// Seule la carte du centre agit : ses boutons sont les seuls affichés, et une
// pression ailleurs ne lance rien, elle ramène la carte visée au milieu.
//
// Le modèle est une liste plate de cartes ; le carrousel la découpe en colonnes
// de `rows`. Une colonne est le pas du défilement : le quadrillage est donc un
// carrousel de colonnes, pas une autre mécanique.
PathView {
    id: carousel

    // Liste plate ({ type, id, title, subtitle, meta, tone, payload, … }),
    // telle que la produisent Search et la navigation.
    property var items: []
    property int rows: 1

    // Géométrie, imposée par le dock.
    property real cellW: 150
    property real cellH: 164
    property real cardW: 140
    property real cardH: 131
    property int cardInset: 5
    property int arcDepth: 14
    property int columnsOnPath: 9

    // De quoi instancier une carte : le type dit le fichier, `cardProps` ajoute
    // ce que le dock veut imposer à toutes les cartes de la vue en cours.
    property var cardFor: ({})
    property var cardProps: ({})

    // La colonne retenue est `currentIndex`, la ligne dans cette colonne est
    // ici. Ensemble elles désignent une carte, et une seule.
    property int currentRow: 0

    signal activated(var item)

    readonly property var columns: {
        var src = carousel.items || [];
        var r = Math.max(1, carousel.rows);
        var out = [];
        for (var i = 0; i < src.length; i += r)
            out.push(src.slice(i, i + r));
        return out;
    }

    // La dernière colonne est souvent incomplète : viser sa deuxième ligne ne
    // désigne rien. Plutôt que de corriger `currentRow` après coup — ce qui
    // laisserait un instant la carte retenue et la carte surlignée en
    // désaccord —, on ne lit jamais que cette valeur rabattue.
    readonly property int effectiveRow: {
        var cols = carousel.columns;
        if (cols.length === 0)
            return 0;
        var col = cols[Math.max(0, Math.min(cols.length - 1, carousel.currentIndex))];
        var limit = Math.min(carousel.rows, col ? col.length : 0);
        return Math.max(0, Math.min(limit - 1, carousel.currentRow));
    }

    readonly property var currentCard: {
        var cols = carousel.columns;
        if (cols.length === 0)
            return null;
        var col = cols[Math.max(0, Math.min(cols.length - 1, carousel.currentIndex))];
        if (!col || col.length === 0)
            return null;
        return col[carousel.effectiveRow];
    }

    // Changer de contenu, c'est changer de sujet : on repart du début plutôt
    // que de garder un index qui ne désigne plus la même carte.
    onItemsChanged: {
        carousel.currentIndex = 0;
        carousel.currentRow = 0;
    }

    // ── Déplacements ─────────────────────────────────────────────
    // La colonne boucle, la ligne non : on ne passe pas du bas d'une colonne au
    // haut de la même, ça n'aurait pas de sens dans une grille.
    function moveColumn(delta) {
        if (carousel.count === 0)
            return;
        if (delta > 0)
            carousel.incrementCurrentIndex();
        else if (delta < 0)
            carousel.decrementCurrentIndex();
    }

    // Tab fait le tour des lignes de la colonne du centre : avec deux rangées,
    // c'est une bascule. Les flèches haut/bas, elles, appartiennent au dock.
    function cycleRow() {
        var cols = carousel.columns;
        if (cols.length === 0)
            return;
        var col = cols[Math.max(0, Math.min(cols.length - 1, carousel.currentIndex))];
        var limit = Math.min(carousel.rows, col ? col.length : 0);
        if (limit <= 1)
            return;
        carousel.currentRow = (carousel.effectiveRow + 1) % limit;
    }

    function moveRow(delta) {
        var cols = carousel.columns;
        if (cols.length === 0)
            return;
        var col = cols[Math.max(0, Math.min(cols.length - 1, carousel.currentIndex))];
        var limit = Math.min(carousel.rows, col ? col.length : 0);
        carousel.currentRow = Math.max(0, Math.min(limit - 1,
                                                   carousel.effectiveRow + delta));
    }

    function activateCurrent() {
        var card = carousel.currentCard;
        if (card)
            carousel.activated(card);
    }

    // ── Mécanique ────────────────────────────────────────────────
    model: carousel.columns
    pathItemCount: carousel.columnsOnPath
    cacheItemCount: 4

    // Le point retenu, c'est le milieu du chemin — et il y reste.
    preferredHighlightBegin: 0.5
    preferredHighlightEnd: 0.5
    highlightRangeMode: PathView.StrictlyEnforceRange
    movementDirection: PathView.Shortest
    highlightMoveDuration: 260

    // Le défilement se pilote à la molette et aux flèches : on ne veut pas du
    // lancer de Flickable par-dessus.
    interactive: false

    readonly property real span: carousel.cellW * carousel.columnsOnPath / 2

    // Les cartes sont posées sur un arc : celle du centre monte vers l'intérieur
    // de l'écran, à pleine taille et pleine opacité ; celles qui s'en éloignent
    // redescendent vers le bord, rapetissent et s'effacent. Le creux suit la
    // parabole d'avant (y ∝ t²), échantillonnée en quatre segments.
    path: Path {
        startX: carousel.width / 2 - carousel.span
        startY: carousel.height / 2 + carousel.arcDepth

        PathAttribute { name: "cardScale";   value: 0.87 }
        PathAttribute { name: "cardOpacity"; value: 0.0 }
        PathAttribute { name: "cardZ";       value: 0 }

        PathLine {
            x: carousel.width / 2 - carousel.span / 2
            y: carousel.height / 2 + carousel.arcDepth * 0.25
        }

        PathAttribute { name: "cardScale";   value: 0.967 }
        PathAttribute { name: "cardOpacity"; value: 1.0 }
        PathAttribute { name: "cardZ";       value: 5 }

        PathLine {
            x: carousel.width / 2
            y: carousel.height / 2
        }

        PathAttribute { name: "cardScale";   value: 1.0 }
        PathAttribute { name: "cardOpacity"; value: 1.0 }
        PathAttribute { name: "cardZ";       value: 10 }

        PathLine {
            x: carousel.width / 2 + carousel.span / 2
            y: carousel.height / 2 + carousel.arcDepth * 0.25
        }

        PathAttribute { name: "cardScale";   value: 0.967 }
        PathAttribute { name: "cardOpacity"; value: 1.0 }
        PathAttribute { name: "cardZ";       value: 5 }

        PathLine {
            x: carousel.width / 2 + carousel.span
            y: carousel.height / 2 + carousel.arcDepth
        }

        PathAttribute { name: "cardScale";   value: 0.87 }
        PathAttribute { name: "cardOpacity"; value: 0.0 }
        PathAttribute { name: "cardZ";       value: 0 }
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            // Une molette verticale fait tourner le carrousel : sur une bande
            // horizontale, c'est le geste attendu, et un pavé tactile fournit
            // les deux axes.
            var step = event.angleDelta.y !== 0 ? event.angleDelta.y
                                                : event.angleDelta.x;
            if (step > 0)
                carousel.moveColumn(-1);
            else if (step < 0)
                carousel.moveColumn(1);
        }
    }

    // ── Une colonne ──────────────────────────────────────────────
    delegate: Item {
        id: column

        required property var modelData
        required property int index

        width: carousel.cellW
        height: carousel.rows * carousel.cellH

        scale:   column.PathView.cardScale // qmllint disable missing-property
        opacity: column.PathView.cardOpacity // qmllint disable missing-property
        z:       column.PathView.cardZ // qmllint disable missing-property

        Repeater {
            model: column.modelData

            delegate: Item {
                id: slot

                required property var modelData
                required property int index

                x: (column.width - carousel.cardW) / 2
                y: slot.index * carousel.cellH + carousel.cardInset
                width: carousel.cardW
                height: carousel.cardH

                readonly property bool isCurrent:
                    column.PathView.isCurrentItem // qmllint disable missing-property
                    && carousel.effectiveRow === slot.index

                function takeFocus() {
                    carousel.currentRow = slot.index;
                    carousel.currentIndex = column.index;
                }

                Loader {
                    id: cardLoader

                    anchors.fill: parent

                    // Les propriétés requises d'une carte se passent par
                    // setSource : on rejoue donc l'appel quand la cellule change
                    // d'élément.
                    function reload() {
                        var props = { "item": slot.modelData };
                        for (var k in carousel.cardProps)
                            props[k] = carousel.cardProps[k];
                        var url = carousel.cardFor[slot.modelData.type];
                        setSource(url ? url : "cards/GenericCard.qml", props);
                    }

                    Component.onCompleted: reload()

                    Connections {
                        // `item` est indéfini le temps que setSource aboutisse :
                        // Connections veut null, pas undefined.
                        target: cardLoader.item || null
                        ignoreUnknownSignals: true

                        function onFocusRequested() { slot.takeFocus(); }
                    }

                    // Ni la sélection ni le droit d'agir ne peuvent passer par
                    // setSource : les propriétés initiales sont posées une fois
                    // pour toutes, sans lien vivant avec le centre du carrousel.
                    Binding {
                        target: cardLoader.item || null
                        property: "selected"
                        value: slot.isCurrent
                        restoreMode: Binding.RestoreNone
                    }

                    Binding {
                        target: cardLoader.item || null
                        property: "primaryEnabled"
                        value: slot.isCurrent
                        restoreMode: Binding.RestoreNone
                    }
                }

                onModelDataChanged: cardLoader.reload()
            }
        }
    }
}
