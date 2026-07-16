pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import "../services"

// Lecteur MPRIS compact du lockscreen : pochette, titre/artiste, transport.
//
// Volontairement en lecture + transport seulement — pas de barre de seek, pas
// de paroles, pas de spectre cava (le widget du panneau s'en charge). Les
// contrôles restent actionnables sans authentification, comme sur la plupart
// des environnements de bureau ; si tu préfères que l'écran verrouillé
// n'expose aucun contrôle, il suffit de passer `interactive` à false.
RowLayout {
    id: musicRoot

    property bool interactive: true

    spacing: 14
    visible: musicRoot.hasPlayer

    // Même sélection que widgets/MusicPlayerWidget : le premier lecteur en
    // lecture, sinon le premier disponible.
    readonly property var player: {
        const list = Mpris.players ? Mpris.players.values : [];
        if (!list || list.length === 0)
            return null;
        for (let i = 0; i < list.length; ++i) {
            if (list[i].playbackState === MprisPlaybackState.Playing)
                return list[i];
        }
        return list[0];
    }

    readonly property bool hasPlayer: musicRoot.player !== null && musicRoot.player !== undefined
    readonly property bool isPlaying: musicRoot.hasPlayer && musicRoot.player.playbackState === MprisPlaybackState.Playing

    Rectangle {
        Layout.preferredWidth: 48
        Layout.preferredHeight: 48
        radius: 6
        color: Theme.bgElevated
        clip: true

        Image {
            anchors.fill: parent
            source: musicRoot.hasPlayer ? (musicRoot.player.trackArtUrl || "") : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
        }
    }

    ColumnLayout {
        Layout.maximumWidth: 220
        spacing: 2

        Text {
            Layout.fillWidth: true
            text: musicRoot.hasPlayer ? (musicRoot.player.trackTitle || "—") : ""
            color: Theme.textPrimary
            font.family: "JetBrains Mono"
            font.pixelSize: 13
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            text: musicRoot.hasPlayer ? (musicRoot.player.trackArtist || "") : ""
            color: Theme.textSecondary
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            elide: Text.ElideRight
            visible: text.length > 0
        }
    }

    component TransportButton: Rectangle {
        id: button

        required property string glyph

        signal activated

        implicitWidth: 30
        implicitHeight: 30
        radius: width / 2
        color: mouse.containsMouse && button.enabled ? Theme.hoverOverlay : "transparent"
        opacity: button.enabled ? 1.0 : 0.35

        Text {
            anchors.centerIn: parent
            text: button.glyph
            color: Theme.textPrimary
            font.family: "JetBrains Mono"
            font.pixelSize: 14
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.activated()
        }
    }

    TransportButton {
        glyph: "⏮"
        enabled: musicRoot.interactive && musicRoot.hasPlayer && musicRoot.player.canGoPrevious
        onActivated: musicRoot.player.previous()
    }

    TransportButton {
        glyph: musicRoot.isPlaying ? "⏸" : "▶"
        enabled: musicRoot.interactive && musicRoot.hasPlayer
        onActivated: musicRoot.player.togglePlaying()
    }

    TransportButton {
        glyph: "⏭"
        enabled: musicRoot.interactive && musicRoot.hasPlayer && musicRoot.player.canGoNext
        onActivated: musicRoot.player.next()
    }
}
