pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../services"

// L'heure du tableau noir (panels/Blackboard.qml), à la manière de la grande
// horloge des Pixel : les heures empilées sur les minutes, très grandes, en
// deux tons de l'accent (les heures pleines, les minutes adoucies), la date
// au-dessus en petites capitales espacées.
//
//      LUNDI 19 OCTOBRE
//      ██  ██
//      ██  ██      ← heures, Theme.accentColor
//      ██  ██      ← minutes, Theme.accentMuted
//
// `size` est la hauteur d'un chiffre ; tout le reste en découle. Les
// chiffres sont à chasse fixe (tnum) : rien ne bouge quand l'heure change.
Item {
    id: clock

    property real size: 200

    implicitWidth: Math.max(digits.width, date.implicitWidth)
    implicitHeight: date.implicitHeight + clock.gap + digits.height

    readonly property real gap: clock.size * 0.12
    readonly property real dateSize: Math.max(12, clock.size * 0.085)

    SystemClock {
        id: now
        precision: SystemClock.Minutes
    }

    Text {
        id: date
        // « lundi 19 octobre », dans la langue de l'interface.
        text: I18n.locale.toString(now.date, "dddd d MMMM").toUpperCase()
        font.family: "Inter"
        font.pixelSize: clock.dateSize
        font.weight: Font.DemiBold
        font.letterSpacing: clock.dateSize * 0.32
        color: Theme.textSecondary
        // Aligné sur le bord gauche des chiffres, pas sur leur approche.
        leftPadding: clock.size * 0.04
    }

    Column {
        id: digits
        anchors.top: date.bottom
        anchors.topMargin: clock.gap
        // Les deux lignes se touchent presque, comme sur un écran verrouillé.
        spacing: clock.size * 0.07

        Digits {
            text: Qt.formatTime(now.date, "HH")
            color: Theme.accentColor
        }
        Digits {
            text: Qt.formatTime(now.date, "mm")
            color: Theme.accentMuted
        }
    }

    // La police des chiffres, et ce qu'ils mesurent vraiment : chaque ligne
    // fait la hauteur d'un chiffre, sans l'interligne de la police, pour que
    // l'écart entre les heures et les minutes soit celui qu'on choisit.
    readonly property font digitFont: Qt.font({
        family: "Inter Display",
        pixelSize: clock.size,
        weight: Font.Bold,
        letterSpacing: -clock.size * 0.04,
        features: { "tnum": 1 }
    })

    readonly property real digitHeight: glyph.tightBoundingRect.height
    readonly property real digitLift: metrics.ascent - clock.digitHeight

    FontMetrics {
        id: metrics
        font: clock.digitFont
    }

    TextMetrics {
        id: glyph
        font: clock.digitFont
        text: "0"
    }

    component Digits: Text {
        font: clock.digitFont
        height: clock.digitHeight
        verticalAlignment: Text.AlignTop
        // Remonté de ce qui sépare le haut de la ligne du haut des chiffres.
        topPadding: -clock.digitLift
    }
}
