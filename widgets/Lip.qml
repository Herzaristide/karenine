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
// Les coins creusés débordent de `radius` à gauche et à droite : l'item
// garde la largeur de son contenu.
Item {
    id: lip

    property color color: Theme.bgDeep
    property real radius: Theme.radius

    Shape {
        x: -lip.radius
        width: lip.width + 2 * lip.radius
        height: lip.height
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: lip.color
            strokeWidth: -1

            // En bas à gauche, sur la barre, puis le coin creusé.
            startX: 0
            startY: lip.height
            PathArc {
                x: lip.radius
                y: lip.height - lip.radius
                radiusX: lip.radius
                radiusY: lip.radius
                direction: PathArc.Counterclockwise
            }
            PathLine { x: lip.radius; y: lip.radius }
            PathArc { x: 2 * lip.radius; y: 0; radiusX: lip.radius; radiusY: lip.radius }
            PathLine { x: lip.width; y: 0 }
            PathArc { x: lip.width + lip.radius; y: lip.radius; radiusX: lip.radius; radiusY: lip.radius }
            PathLine { x: lip.width + lip.radius; y: lip.height - lip.radius }
            PathArc {
                x: lip.width + 2 * lip.radius
                y: lip.height
                radiusX: lip.radius
                radiusY: lip.radius
                direction: PathArc.Counterclockwise
            }
            PathLine { x: 0; y: lip.height }
        }
    }
}
