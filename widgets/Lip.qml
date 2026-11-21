import QtQuick
import QtQuick.Shapes
import "../services"

// Ce qui sort de la barre du bas : un volet, la réponse du pilote, les
// suggestions. Le haut arrondi comme les cartes, le bas collé à la barre et
// raccordé à elle par deux coins creusés, si bien que les deux ne font
// qu'une seule surface, de la même encre.
//
//            ╭──────────────────╮
//            │                  │
//          ╭─╯                  ╰─╮   ← les coins creusés, hors de l'item
//   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  la barre
//
// Les coins creusés débordent de `radius` à gauche et à droite (moins
// quand l'item est plus bas que deux rayons) : l'item garde la largeur de
// son contenu.
Item {
    id: lip

    property color color: Theme.bgDeep
    property real radius: Theme.radius
    // Le rayon tracé : jamais plus que la moitié de la hauteur, pour que
    // la surface reste propre pendant qu'elle sort de la barre (un volet qui
    // s'ouvre part de zéro).
    readonly property real r: Math.max(0, Math.min(lip.radius, lip.height / 2))

    Shape {
        x: -lip.r
        width: lip.width + 2 * lip.r
        height: lip.height
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: lip.color
            strokeWidth: -1

            // En bas à gauche, sur la barre, puis le coin creusé.
            startX: 0
            startY: lip.height
            PathArc {
                x: lip.r
                y: lip.height - lip.r
                radiusX: lip.r
                radiusY: lip.r
                direction: PathArc.Counterclockwise
            }
            PathLine { x: lip.r; y: lip.r }
            PathArc { x: 2 * lip.r; y: 0; radiusX: lip.r; radiusY: lip.r }
            PathLine { x: lip.width; y: 0 }
            PathArc { x: lip.width + lip.r; y: lip.r; radiusX: lip.r; radiusY: lip.r }
            PathLine { x: lip.width + lip.r; y: lip.height - lip.r }
            PathArc {
                x: lip.width + 2 * lip.r
                y: lip.height
                radiusX: lip.r
                radiusY: lip.r
                direction: PathArc.Counterclockwise
            }
            PathLine { x: 0; y: lip.height }
        }
    }
}
