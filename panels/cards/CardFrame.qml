import QtQuick
import "../../services"

// Composition commune à toutes les cartes, quel que soit le mode d'affichage :
// l'icône occupe toute la tuile, le nom et le type sont posés par-dessus en
// haut, les actions par-dessus en bas. Aucun fond, aucun contour — c'est
// l'icône qui fait la carte, et sa couleur de titre qui porte le survol.
//
// Le texte et les boutons se superposent donc à l'image : ils gardent chacun
// leur plaque translucide, qui est ce qui les rend lisibles quelle que soit
// l'icône dessous.
//
// Une carte concrète ne fait que renseigner `title`, `subtitle`, l'icône (image
// ou glyphe dessiné) et sa liste d'actions ; la géométrie vient du dock, qui
// donne à ce cadre une tuile.
Item {
    id: frame

    property color tone: Theme.accentColor
    property string title: ""
    property string subtitle: ""
    property string iconSource: ""
    property bool tapEnabled: true

    // Une vignette d'image remplit sa boîte ; une icône garde ses proportions
    // et sa marge.
    property bool iconCrop: false

    // Glyphe dessiné, utilisé quand il n'y a pas d'icône d'application.
    default property alias glyphContent: glyphSlot.data
    property alias actionContent: actionRow.data

    // De quoi poser autre chose sur la carte — une zone de glissé, par exemple —
    // sans que ça atterrisse dans la boîte à icône. La couche passe sous la
    // rangée d'actions, qui garde ses propres pressions.
    property alias extraContent: extraSlot.data

    readonly property bool hovered: frameHover.hovered
    readonly property bool pressed: frameTap.pressed

    // Sélection au clavier (flèches du dock). La carte s'allume exactement
    // comme au survol : il n'y a jamais qu'un seul « ici » à l'écran.
    property bool selected: false
    readonly property bool highlighted: frame.hovered || frame.selected

    // Le carrousel ne laisse agir que la carte du centre. Ailleurs, la pression
    // ne lance rien : elle réclame le centre, et c'est le carrousel qui l'y
    // amène. Une carte hors du dock garde le comportement direct.
    property bool primaryEnabled: true
    signal focusRequested()

    // Le geste d'activation, quel que soit le type de carte : c'est ici qu'on
    // tranche entre « agir » et « venir au centre », et nulle part ailleurs.
    function primaryPressed() {
        if (frame.primaryEnabled)
            frame.primaryActivated();
        else
            frame.focusRequested();
    }

    // Largeur utile pour le texte, une fois les marges de la plaque retirées.
    // Elle ne dépend que du cadre : la plaque, elle, se règle sur le texte, et
    // la faire entrer dans ce calcul bouclerait.
    readonly property real textAvail: Math.max(40, width - 16)

    // L'icône prend toute la tuile ; le côté le plus court la borne, puisqu'elle
    // garde ses proportions.
    readonly property real iconSize: Math.min(frame.width, frame.height)

    signal primaryActivated()

    scale: pressed ? 0.96 : (highlighted ? 1.03 : 1.0)

    Behavior on scale {
        NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
    }

    // ── Icône ────────────────────────────────────────────────────
    // Déclarée en premier : tout le reste de la carte se pose dessus.
    Item {
        id: iconBox

        anchors.fill: parent
        clip: frame.iconCrop

        Image {
            id: iconImage

            anchors.fill: parent
            anchors.margins: frame.iconCrop ? 0 : frame.iconSize * 0.06
            source: frame.iconSource
            visible: frame.iconSource.length > 0 && status !== Image.Error

            // `sourceSize` borne le décodage : une photo de 4000 px n'est jamais
            // décompressée en entier pour une vignette de 126. `asynchronous`
            // garde le chargement hors du fil de rendu.
            sourceSize.width: frame.iconSize
            sourceSize.height: frame.iconSize
            asynchronous: true

            fillMode: frame.iconCrop ? Image.PreserveAspectCrop
                                     : Image.PreserveAspectFit
            smooth: true
        }

        // Les glyphes sont dessinés sur un repère de 40 px ; on les met à
        // l'échelle de la boîte plutôt que de redessiner chaque carte. Le
        // facteur est calé pour que l'encre occupe la boîte, pas pour qu'elle
        // y flotte : un glyphe de 22 px de haut en remplit environ 75 %.
        Item {
            id: glyphSlot

            anchors.centerIn: parent
            width: 40
            height: 40
            scale: Math.max(1.0, frame.iconSize / 30)
            // Le glyphe reprend la main si l'image est illisible.
            visible: frame.iconSource.length === 0 || iconImage.status === Image.Error
        }
    }

    // Déclaré avant le texte et la rangée d'actions, donc dessous : ce qu'on
    // pose ici — une zone de glissé, typiquement — peut couvrir toute la carte
    // sans avaler les pressions destinées aux boutons.
    Item {
        id: extraSlot
        anchors.fill: parent
    }

    // Plaque de lisibilité : elle épouse le texte, pas la carte. Posée sur
    // l'icône, c'est elle qui garde un titre lisible sur une vignette claire —
    // et elle ne déborde pas du texte, donc l'icône reste visible autour.
    Rectangle {
        id: textPlate

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter

        width: Math.max(titleText.width, subtitleText.width) + 16
        height: textCol.implicitHeight + 8
        radius: 9

        color: Theme.darkMode ? Qt.rgba(0, 0, 0, frame.highlighted ? 0.66 : 0.54)
                              : Qt.rgba(1, 1, 1, frame.highlighted ? 0.84 : 0.74)

        Behavior on color { ColorAnimation { duration: 180 } }

        Column {
            id: textCol

            anchors.centerIn: parent
            spacing: 1

            Text {
                id: titleText

                // La tuile est étroite : le titre se replie sur deux lignes
                // plutôt que d'être amputé dès le premier mot un peu long.
                width: Math.min(implicitWidth, frame.textAvail)
                text: frame.title
                color: frame.highlighted ? frame.tone : Theme.textPrimary
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.letterSpacing: 0.2
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight

                Behavior on color { ColorAnimation { duration: 150 } }
            }

            Text {
                id: subtitleText

                width: Math.min(implicitWidth, frame.textAvail)
                text: frame.subtitle
                color: Theme.textSecondary
                font.family: "JetBrains Mono"
                font.pixelSize: 9
                font.letterSpacing: 0.1
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 1
                // Un chemin se lit par la fin : c'est le début qu'on ampute.
                elide: Text.ElideLeft
                visible: text.length > 0
            }
        }
    }

    // Les actions n'appartiennent qu'à la carte retenue — celle du centre du
    // carrousel. Ailleurs elles ne servent à rien : on ne peut pas les viser
    // sans d'abord amener la carte au milieu, et vingt rangées de boutons sur
    // la bande ne font que du bruit. Déclarées en dernier : elles passent
    // au-dessus de l'icône et de la couche de glissé.
    Row {
        id: actionRow

        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 5

        opacity: frame.selected ? 1.0 : 0.0
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    HoverHandler {
        id: frameHover
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        id: frameTap
        enabled: frame.tapEnabled
        onTapped: frame.primaryPressed()
    }
}
