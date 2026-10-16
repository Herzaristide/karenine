import QtQuick
import QtMultimedia

// Vidéo de fond du lockscreen : en boucle, sans son, recadrée pour remplir
// l'écran — le rendu de mpvpaper (`panscan=1.0`) dans la session.
//
// Le compositeur ne dessine rien sous un écran verrouillé (ext-session-lock),
// mpvpaper compris : le lock doit donc jouer la vidéo lui-même. Chargé par
// AuthBackdrop via un Loader, pour que seul le lock dépende de QtMultimedia.
Item {
    id: root

    property string source: ""
    property bool playing: true

    // Vrai dès qu'une image est à l'écran ; en cas d'erreur (fichier absent,
    // codec), AuthBackdrop garde sa couleur unie.
    readonly property bool showing: player.hasVideo && player.error === MediaPlayer.NoError

    MediaPlayer {
        id: player
        source: root.source.length > 0 ? "file://" + root.source : ""
        loops: MediaPlayer.Infinite
        videoOutput: output
        // Pas d'audioOutput : aucune piste son n'est jouée.

        // La source arrive après la création (liée par AuthBackdrop au
        // chargement), et un play() donné avant ne vaut pas pour elle : on
        // relance à chaque nouvelle source du lecteur — pas de root, dont le
        // signal part avant que cette liaison-ci ne soit réévaluée.
        onSourceChanged: root.sync()
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: root.showing
    }

    function sync(): void {
        if (root.playing)
            player.play();
        else
            player.pause();
    }

    onPlayingChanged: root.sync()
}
