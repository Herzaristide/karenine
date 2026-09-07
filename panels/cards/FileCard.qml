import QtQuick
import Quickshell
import "../../services"

// Fichier ou dossier : le glyphe, le nom, le chemin, et les quatre outils sous
// forme d'icônes — celles des applications réellement par défaut. La carte est
// aussi une source de glisser-déposer système.
CardFrame {
    id: card

    required property var item

    // En mode navigation, un dossier se parcourt dans le dock au lieu de
    // partir chez le gestionnaire de fichiers.
    property bool navigateDirs: false
    signal navigateRequested(string path)

    readonly property bool isDir: card.item.payload.isDir
    readonly property string path: card.item.payload.path

    // text/uri-list attend une URI, pas un chemin brut : espaces, apostrophes
    // et dièses doivent être encodés, sinon la cible rejette le dépôt. On encode
    // segment par segment pour garder les « / » intacts.
    readonly property string fileUrl: {
        var parts = card.path.split("/");
        for (var i = 0; i < parts.length; i++)
            parts[i] = encodeURIComponent(parts[i]);
        return "file://" + parts.join("/");
    }

    // Les dossiers prennent l'icône du thème, avec sa variante quand le nom est
    // un dossier connu — le thème en fournit une quinzaine. Si le thème n'a
    // rien, `iconSource` reste vide et le glyphe dessiné plus bas prend le
    // relais. Les fichiers gardent leur extension, qui dit plus qu'une icône
    // générique.
    readonly property string folderIconName: {
        switch (card.item.title.toLowerCase()) {
        case "documents":                    return "folder-documents";
        case "downloads": case "téléchargements": return "folder-download";
        case "music": case "musique":        return "folder-music";
        case "pictures": case "images":      return "folder-pictures";
        case "videos": case "vidéos":        return "folder-videos";
        case "public":                       return "folder-public";
        case "templates": case "modèles":    return "folder-templates";
        }
        return "folder";
    }

    // Un fichier image se montre lui-même : l'extension en toutes lettres ne
    // dit rien qu'une vignette ne dise mieux.
    readonly property bool isImage: {
        var s = card.item.payload.suffix.toLowerCase();
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg",
                "avif", "tif", "tiff", "ico"].indexOf(s) !== -1;
    }

    tone: card.item.tone
    title: card.item.title
    subtitle: card.item.subtitle
    iconSource: card.isDir ? Quickshell.iconPath(card.folderIconName, "folder")
                           : (card.isImage ? card.fileUrl : "")
    iconCrop: card.isImage
    // Le clic et le glissé partent de la même pression, donc d'une MouseArea
    // plutôt que du TapHandler de la coque.
    tapEnabled: false

    // Dossier, ou extension du fichier.
    Item {
        anchors.centerIn: parent
        width: 28
        height: 22

        Rectangle {
            visible: card.isDir
            x: 1; y: 1
            width: 11; height: 5
            radius: 2
            color: card.tone
            opacity: 0.85
        }

        Rectangle {
            visible: card.isDir
            anchors.fill: parent
            anchors.topMargin: 5
            radius: 4
            color: card.tone
            opacity: 0.85
        }

        Text {
            visible: !card.isDir
            anchors.centerIn: parent
            text: card.item.meta.length > 0 ? card.item.meta.substring(0, 4) : "·"
            color: card.tone
            font.family: "JetBrains Mono"
            font.pixelSize: 10
            font.weight: Font.DemiBold
        }
    }

    // Glyphes dessinés plutôt que les icônes des applications : même langage
    // graphique que le reste du dock, et une rangée qui reste lisible à 27 px.
    // C'est le rôle qui est illustré, pas l'outil — celui-ci reste résolu par
    // DefaultApps, donc changer d'éditeur ou de terminal marche toujours.
    actionContent: [
        // Éditeur : chevrons de code.
        IconPill {
            tone: card.tone
            onTriggered: Search.activate(card.item, "editor")

            Item {
                anchors.centerIn: parent
                width: 16
                height: 12

                Rectangle {
                    x: 1; y: 5.3
                    width: 6; height: 1.4
                    radius: 0.7
                    color: card.tone
                    transformOrigin: Item.Left
                    rotation: -45
                }

                Rectangle {
                    x: 1; y: 5.3
                    width: 6; height: 1.4
                    radius: 0.7
                    color: card.tone
                    transformOrigin: Item.Left
                    rotation: 45
                }

                Rectangle {
                    x: 7.3; y: 1
                    width: 1.4; height: 10
                    radius: 0.7
                    color: card.tone
                    rotation: 18
                }

                Rectangle {
                    x: 9; y: 5.3
                    width: 6; height: 1.4
                    radius: 0.7
                    color: card.tone
                    transformOrigin: Item.Right
                    rotation: 45
                }

                Rectangle {
                    x: 9; y: 5.3
                    width: 6; height: 1.4
                    radius: 0.7
                    color: card.tone
                    transformOrigin: Item.Right
                    rotation: -45
                }
            }
        },

        // Explorateur : un dossier, onglet plein et corps tracé.
        IconPill {
            tone: card.tone
            onTriggered: Search.activate(card.item, "explorer")

            Item {
                anchors.centerIn: parent
                width: 16
                height: 13

                Rectangle {
                    x: 0.7; y: 0
                    width: 6.5; height: 3.5
                    radius: 1
                    color: card.tone
                }

                Rectangle {
                    x: 0; y: 2.6
                    width: 16; height: 10.4
                    radius: 2.5
                    color: "transparent"
                    border.width: 1.3
                    border.color: card.tone
                }
            }
        },

        // Terminal : une fenêtre, une invite et un curseur.
        IconPill {
            tone: card.tone
            onTriggered: Search.activate(card.item, "terminal")

            Item {
                anchors.centerIn: parent
                width: 16
                height: 13

                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: "transparent"
                    border.width: 1.3
                    border.color: card.tone
                }

                Rectangle {
                    x: 3.6; y: 5.4
                    width: 3.6; height: 1.2
                    radius: 0.6
                    color: card.tone
                    transformOrigin: Item.Left
                    rotation: -42
                }

                Rectangle {
                    x: 3.6; y: 5.4
                    width: 3.6; height: 1.2
                    radius: 0.6
                    color: card.tone
                    transformOrigin: Item.Left
                    rotation: 42
                }

                Rectangle {
                    x: 8.4; y: 8.1
                    width: 4; height: 1.2
                    radius: 0.6
                    color: card.tone
                }
            }
        },

        // Copier le chemin : deux feuilles superposées.
        IconPill {
            tone: card.tone
            onTriggered: Search.activate(card.item, "copy")

            Item {
                anchors.centerIn: parent
                width: 15
                height: 15

                Rectangle {
                    x: 0; y: 3
                    width: 9.5; height: 9.5
                    radius: 2
                    color: "transparent"
                    border.width: 1.3
                    border.color: card.tone
                }

                Rectangle {
                    x: 4.5; y: 0
                    width: 9.5; height: 9.5
                    radius: 2
                    color: "transparent"
                    border.width: 1.3
                    border.color: card.tone
                }
            }
        }
    ]

    extraContent: [
        // Le porteur du glisser. La carte ne bouge pas : ce proxy invisible est
        // la cible du drag, et son passage en Drag.active démarre le glisser
        // système — le montage prévu pour dragType Automatic.
        Item {
            id: dragProxy

            width: card.width
            height: card.height
            opacity: 0

            Drag.active: dragArea.drag.active
            Drag.dragType: Drag.Automatic
            Drag.supportedActions: Qt.CopyAction
            Drag.proposedAction: Qt.CopyAction
            Drag.mimeData: ({
                "text/uri-list": card.fileUrl + "\r\n",
                "text/plain": card.path
            })

            Drag.onDragStarted: DragState.begin(card.path)

            Drag.onDragFinished: {
                DragState.end();
                dragProxy.x = 0;
                dragProxy.y = 0;
            }
        },

        // Zone de clic et de glissé. Elle couvre toute la carte : la rangée de
        // boutons est déclarée après `extraContent` dans la coque, donc au-dessus,
        // et garde ses propres pressions.
        MouseArea {
            id: dragArea

            // `extraContent` place ses éléments dans une couche intermédiaire : on
            // ne peut donc pas s'ancrer à la carte, qui est le grand-parent.
            anchors.fill: parent
            hoverEnabled: false
            cursorShape: Qt.PointingHandCursor

            drag.target: dragProxy
            drag.threshold: 10

            // La vignette est capturée une fois pour la vie de la carte : son
            // contenu ne change pas, et un rendu hors écran par clic — glissé ou
            // non — se paierait à chaque ouverture.
            property bool grabbed: false

            onPressed: {
                if (dragArea.grabbed)
                    return;
                dragArea.grabbed = true;
                card.grabToImage(function (result) {
                    dragProxy.Drag.imageSource = result.url;
                });
            }

            // Filet de sécurité : si le glisser est annulé sans dragFinished,
            // le drapeau ne doit pas rester bloqué.
            onReleased: {
                DragState.end();
                dragProxy.x = 0;
                dragProxy.y = 0;
            }

            // MouseArea n'émet pas clicked si un glissé a eu lieu.
            onClicked: {
                if (card.isDir && card.navigateDirs)
                    card.navigateRequested(card.path);
                else
                    Search.activate(card.item, "open");
            }
        }
    ]
}
