import QtQuick
import "../services"

// Le titre d'une carte du panneau Musique : petit, en capitales espacées,
// discret ; il s'abrège s'il ne tient pas.
Text {
    font.family: "Inter"
    font.pixelSize: 10
    font.weight: Font.DemiBold
    font.letterSpacing: 1.2
    font.capitalization: Font.AllUppercase
    color: Theme.textDim
    elide: Text.ElideRight
    maximumLineCount: 1
}
