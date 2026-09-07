import QtQuick
import "../../services"

// Composition commune à toutes les cartes, quel que soit le mode d'affichage :
// une icône à gauche, le texte à sa droite, les actions en dessous. Aucun fond,
// aucun contour — ce sont l'icône et la couleur du titre qui portent le survol.
//
// Une carte concrète ne fait que renseigner `title`, `subtitle`, l'icône (image
// ou glyphe dessiné) et sa liste d'actions ; la géométrie vient du dock, qui
// donne à ce cadre soit une ligne allongée, soit un carré.
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

    // En carré la colonne de texte est étroite : le titre passe sur deux lignes.
    readonly property bool square: width < 200

    // L'icône occupe toute la hauteur de la carte. En carré, cette règle la
    // ferait manger toute la largeur : on la plafonne pour garder au texte une
    // colonne utilisable.
    readonly property real iconSize: Math.min(height, width * 0.42)

    // Largeur utile pour le texte, une fois l'icône, l'écart et les marges de
    // la plaque retirés.
    readonly property real textAvail: Math.max(40, width - iconSize - 10 - 16)

    signal primaryActivated()

    scale: pressed ? 0.96 : (hovered ? 1.03 : 1.0)

    Behavior on scale {
        NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
    }

    Item {
        id: iconBox

        width: frame.iconSize
        height: frame.iconSize
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        clip: frame.iconCrop

        Image {
            id: iconImage

            anchors.fill: parent
            anchors.margins: frame.iconCrop ? 0 : frame.iconSize * 0.10
            source: frame.iconSource
            visible: frame.iconSource.length > 0 && status !== Image.Error

            // `sourceSize` borne le décodage : une photo de 4000 px n'est jamais
            // décompressée en entier pour une vignette de 94. `asynchronous`
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

    // Plaque de lisibilité : elle épouse le texte, pas la carte. Sans fond de
    // carte, un titre posé sur un fond d'écran clair devient illisible ; une
    // plaque qui ne dépasse pas du texte règle ça sans rendre la carte lourde.
    Rectangle {
        id: textPlate

        anchors.left: iconBox.right
        anchors.leftMargin: 10
        anchors.top: parent.top
        anchors.topMargin: frame.square ? 0 : 3

        width: Math.max(titleText.width, subtitleText.width) + 16
        height: textCol.implicitHeight + 10
        radius: 9

        color: Theme.darkMode ? Qt.rgba(0, 0, 0, frame.hovered ? 0.52 : 0.42)
                              : Qt.rgba(1, 1, 1, frame.hovered ? 0.78 : 0.66)

        Behavior on color { ColorAnimation { duration: 180 } }

        Column {
            id: textCol

            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                id: titleText

                // En carré on fixe la largeur pour pouvoir replier sur deux
                // lignes ; en liste on épouse le texte, ce qui donne à la
                // plaque sa largeur.
                width: frame.square ? frame.textAvail
                                    : Math.min(implicitWidth, frame.textAvail)
                text: frame.title
                color: frame.hovered ? frame.tone : Theme.textPrimary
                font.family: "JetBrains Mono"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.letterSpacing: 0.2
                wrapMode: frame.square ? Text.WrapAnywhere : Text.NoWrap
                maximumLineCount: frame.square ? 2 : 1
                elide: Text.ElideRight

                Behavior on color { ColorAnimation { duration: 150 } }
            }

            Text {
                id: subtitleText

                width: frame.square ? frame.textAvail
                                    : Math.min(implicitWidth, frame.textAvail)
                text: frame.subtitle
                color: Theme.textSecondary
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 0.1
                wrapMode: frame.square ? Text.WrapAnywhere : Text.NoWrap
                maximumLineCount: frame.square ? 2 : 1
                // Un chemin se lit par la fin : c'est le début qu'on ampute.
                elide: frame.square ? Text.ElideRight : Text.ElideLeft
                visible: text.length > 0
            }
        }
    }

    // Déclaré avant la rangée d'actions, donc dessous : ce qu'on pose ici — une
    // zone de glissé, typiquement — peut couvrir toute la carte sans avaler les
    // pressions destinées aux boutons.
    Item {
        id: extraSlot
        anchors.fill: parent
    }

    // Les actions restent visibles mais en retrait ; le survol les révèle
    // franchement, sans que la carte change de taille.
    Row {
        id: actionRow

        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 5

        opacity: frame.hovered ? 1.0 : 0.45
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    HoverHandler {
        id: frameHover
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        id: frameTap
        enabled: frame.tapEnabled
        onTapped: frame.primaryActivated()
    }
}
