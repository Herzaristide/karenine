pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import "../services"

// Le second dossier de l'Explorer, sous le premier (le mode split) : il
// reste où on l'a laissé pendant qu'on navigue au-dessus, pour y glisser
// des fichiers. En liste, sans plus : l'icône, le nom, la taille.
//
//   ╭ (↑)  ~/drop                               12 éléments  (×) ╮
//   │ ▭ archives                                                  │
//   │ ▤ facture.pdf                                       84 Ko   │
//   ╰─────────────────────────────────────────────────────────────╯
//
// Un clic sélectionne, Ctrl+clic ajoute ou retire ; un double clic entre
// dans le dossier ou ouvre le fichier ; le clic droit ouvre le menu de
// l'Explorer (ouvrir, éditeur, terminal, renommer, supprimer…). Ce qu'on y dépose (depuis le dossier
// du haut, ou d'ici vers celui du haut) y est déplacé ; sur une ligne de
// dossier, dans ce dossier. L'Explorer (`explorer`) fait le déplacement et
// tient le chemin (`path`, Widgets.explorerSplitPath).
//
// Par défaut en arborescence (Widgets.explorerSplitTree) : un clic sur un
// dossier le déplie sur place, comme dans la barre latérale d'un IDE ; le
// bouton de l'en-tête repasse en liste, où le double clic entre dedans.
Rectangle {
    id: pane

    required property Item explorer
    required property string path
    // Pour relire le dossier après un déplacement (sshfs ne prévient pas).
    property int reloadTick: 0

    signal navigate(string path)
    signal closeRequested()

    property var selection: ({})
    readonly property var selectedPaths: Object.keys(pane.selection)

    radius: Theme.radius
    color: Qt.alpha(Theme.textPrimary, 0.03)
    border.width: 1
    border.color: Theme.dividerColor

    // Sur un serveur monté : « gary : /mnt/crucial » ; ici, « ~ » pour le
    // dossier personnel.
    readonly property string mountBase: pane.explorer.mountBase + "/"
    readonly property string mountRoot: {
        if (pane.path.indexOf(pane.mountBase) !== 0)
            return "/";
        var rest = pane.path.substring(pane.mountBase.length);
        var slash = rest.indexOf("/");
        return pane.mountBase + (slash < 0 ? rest : rest.substring(0, slash));
    }
    readonly property string shownPath: {
        var p = pane.path;
        if (pane.mountRoot !== "/") {
            var name = pane.mountRoot.substring(pane.mountBase.length);
            return name + " : " + (p.substring(pane.mountRoot.length) || "/");
        }
        var h = pane.explorer.localHome;
        if (p === h)
            return "~";
        if (p.indexOf(h + "/") === 0)
            return "~" + p.substring(h.length);
        return p;
    }

    readonly property bool tree: Widgets.explorerSplitTree
    readonly property int treeIndent: 14

    onPathChanged: {
        pane.selection = {};
        pane.pruneExpanded(pane.path);
    }
    onTreeChanged: Qt.callLater(pane.rebuild)

    // ── Les entrées : le dossier, et en arborescence ce qui est déplié ──
    property var entries: []
    property var expanded: ({})
    property var treeModels: ({})
    ListModel { id: expandedModel }

    function readEntries(m, depth) {
        var out = [];
        for (var i = 0; i < m.count; i++) {
            var path = String(m.get(i, "filePath"));
            var isDir = m.get(i, "fileIsDir") === true;
            var open = pane.tree && isDir && pane.expanded[path] === true;
            out.push({
                name: String(m.get(i, "fileName")),
                path: path,
                isDir: isDir,
                suffix: m.get(i, "fileSuffix"),
                size: m.get(i, "fileSize"),
                depth: depth,
                expanded: open
            });
            if (open) {
                var sub = pane.treeModels[path];
                if (sub && sub.status === FolderListModel.Ready)
                    out = out.concat(pane.readEntries(sub, depth + 1));
            }
        }
        return out;
    }
    function rebuild() {
        var y = list.contentY;
        pane.entries = pane.readEntries(model, 0);
        list.contentY = Math.min(y, Math.max(0, list.contentHeight - list.height));
    }

    function setExpanded(p, open) {
        if ((pane.expanded[p] === true) === open)
            return;
        var e = Object.assign({}, pane.expanded);
        if (open) {
            e[p] = true;
            expandedModel.append({ path: p });
        } else {
            for (var i = expandedModel.count - 1; i >= 0; i--) {
                var q = expandedModel.get(i).path;
                if (q === p || q.indexOf(p + "/") === 0) {
                    delete e[q];
                    expandedModel.remove(i);
                }
            }
        }
        pane.expanded = e;
        Qt.callLater(pane.rebuild);
    }
    function toggleExpanded(p) {
        pane.setExpanded(p, pane.expanded[p] !== true);
    }
    function pruneExpanded(p) {
        var e = {};
        for (var i = expandedModel.count - 1; i >= 0; i--) {
            var q = expandedModel.get(i).path;
            if (q.indexOf(p + "/") === 0)
                e[q] = true;
            else
                expandedModel.remove(i);
        }
        pane.expanded = e;
    }

    Instantiator {
        model: expandedModel
        delegate: FolderListModel {
            id: sub
            required property string path
            folder: pane.explorer.urlOf(sub.path) + (pane.reloadTick % 2 === 1 ? "/" : "")
            showDirsFirst: true
            showDotAndDotDot: false
            showHidden: pane.explorer.showHidden
            sortField: FolderListModel.Name
            sortCaseSensitive: false
            onCountChanged: Qt.callLater(pane.rebuild)
            onStatusChanged: Qt.callLater(pane.rebuild)
        }
        onObjectAdded: (index, object) => {
            var m = Object.assign({}, pane.treeModels);
            m[object.path] = object;
            pane.treeModels = m;
        }
        onObjectRemoved: (index, object) => {
            var m = Object.assign({}, pane.treeModels);
            if (m[object.path] === object)
                delete m[object.path];
            pane.treeModels = m;
            Qt.callLater(pane.rebuild);
        }
    }

    function go(p) {
        pane.selection = {};
        pane.navigate(p);
    }
    function up() {
        if (pane.path !== pane.mountRoot)
            pane.go(pane.explorer.parentOf(pane.path));
    }
    function select(p, add) {
        var s = add ? Object.assign({}, pane.selection) : {};
        if (add && s[p])
            delete s[p];
        else
            s[p] = true;
        pane.selection = s;
    }
    function isDir(p) {
        var e = pane.entries.find(x => x.path === p);
        return e ? e.isDir : false;
    }
    function carried(p) {
        return pane.selection[p] ? pane.selectedPaths : [p];
    }

    FolderListModel {
        id: model
        // Une barre de plus, une de moins : la même adresse, relue.
        folder: pane.explorer.urlOf(pane.path) + (pane.reloadTick % 2 === 1 && pane.path !== "/" ? "/" : "")
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: pane.explorer.showHidden
        sortField: FolderListModel.Name
        sortCaseSensitive: false
        onCountChanged: Qt.callLater(pane.rebuild)
        onStatusChanged: Qt.callLater(pane.rebuild)
    }
    Connections {
        target: model
        function onDataChanged() { Qt.callLater(pane.rebuild); }
        function onModelReset() { Qt.callLater(pane.rebuild); }
    }

    // ── L'en-tête ────────────────────────────────────────────────
    Item {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 5
        height: 26

        GlassButton {
            id: upBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 24
            icon: "../assets/icons/up.svg"
            opacity: pane.path !== pane.mountRoot ? 1 : 0.4
            onClicked: pane.up()
        }
        Text {
            anchors.left: upBtn.right
            anchors.leftMargin: 8
            anchors.right: countLabel.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: pane.shownPath
            elide: Text.ElideMiddle
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: Theme.textPrimary
        }
        Text {
            id: countLabel
            anchors.right: viewBtn.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: pane.selectedPaths.length > 0 ? I18n.trn("explorer.selected", pane.selectedPaths.length)
                                                : I18n.trn("explorer.items", model.count)
            font.family: "Inter"
            font.pixelSize: 11
            font.features: { "tnum": 1 }
            color: Theme.textDim
        }
        // Arborescence ou liste.
        GlassButton {
            id: viewBtn
            anchors.right: closeBtn.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 24
            icon: pane.tree ? "../assets/icons/view-list.svg" : "../assets/icons/view-tree.svg"
            onClicked: Widgets.explorerSplitTree = !Widgets.explorerSplitTree
        }
        GlassButton {
            id: closeBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 24
            icon: "../assets/icons/close.svg"
            onClicked: pane.closeRequested()
        }
    }

    // Un clic dans le vide désélectionne.
    // Le droit : le menu de ce dossier.
    MouseArea {
        id: voidMa
        anchors.fill: list
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                var at = voidMa.mapToItem(pane.explorer, mouse.x, mouse.y);
                pane.explorer.showMenu(pane.path, true, true, at.x, at.y, [], true);
            } else {
                pane.selection = {};
            }
        }
    }

    // Déposé dans le vide : dans ce dossier. Sous la liste, pour que les
    // lignes de dossier (au-dessus) prennent la main.
    DropArea {
        id: paneDrop
        anchors.fill: list
        keys: ["text/uri-list"]
        onEntered: (drag) => drag.accept(Qt.CopyAction)
        onDropped: (drop) => pane.explorer.dropInto(drop, pane.path)
    }
    Rectangle {
        anchors.fill: list
        radius: Theme.radiusSmall
        color: "transparent"
        border.width: 1.5
        border.color: Theme.accentColor
        visible: paneDrop.containsDrag
    }

    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: head.bottom
        anchors.bottom: parent.bottom
        anchors.margins: 5
        anchors.topMargin: 4
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: pane.entries

        delegate: Item {
            id: row
            required property int index
            required property var modelData
            readonly property string fileName: row.modelData.name
            readonly property string filePath: row.modelData.path
            readonly property bool fileIsDir: row.modelData.isDir
            readonly property string fileSuffix: row.modelData.suffix
            readonly property real fileSize: row.modelData.size
            readonly property int depth: pane.tree ? row.modelData.depth : 0
            readonly property int treeX: 6 + row.depth * pane.treeIndent
            readonly property bool selected: pane.selection[row.filePath] === true
            readonly property string icon: pane.explorer.iconFor(row.filePath, row.fileIsDir, row.fileSuffix, row.fileName)
            readonly property bool glyph: row.icon.indexOf("../assets/") === 0
            readonly property var carried: pane.carried(row.filePath)

            width: ListView.view.width
            height: pane.tree ? 26 : 28

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: Theme.radiusSmall
                color: rowDrop.containsDrag ? Qt.alpha(Theme.accentColor, 0.3)
                     : row.selected ? Qt.alpha(Theme.accentColor, 0.2)
                     : rowMa.containsMouse ? Qt.alpha(Theme.textPrimary, 0.06) : "transparent"
                Behavior on color { ColorAnimation { duration: 110 } }
            }

            // Les guides de l'arborescence, un par niveau au-dessus.
            Repeater {
                model: row.depth
                Rectangle {
                    required property int index
                    x: 6 + index * pane.treeIndent + 6
                    width: 1
                    height: row.height
                    color: Qt.alpha(Theme.textPrimary, index === row.depth - 1 ? 0.14 : 0.08)
                }
            }
            // Le chevron d'un dossier ; un clic dessus déplie ou replie.
            Item {
                visible: pane.tree && row.fileIsDir
                x: row.treeX
                width: 14
                height: parent.height
                z: 2
                NixIcon {
                    anchors.centerIn: parent
                    iconSize: 9
                    source: "../assets/icons/chevron-down.svg"
                    rotation: row.modelData.expanded ? 0 : -90
                    color: chevronMa.containsMouse ? Theme.textPrimary : Theme.textDim
                    Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                }
                MouseArea {
                    id: chevronMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: pane.toggleExpanded(row.filePath)
                }
            }

            Item {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: pane.tree ? row.treeX + 16 : 8
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                Image {
                    anchors.fill: parent
                    visible: !row.glyph
                    source: row.glyph ? "" : row.icon
                    sourceSize.width: 64
                    sourceSize.height: 64
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }
                NixIcon {
                    anchors.fill: parent
                    visible: row.glyph
                    iconSize: 16
                    source: row.glyph ? row.icon : ""
                    color: Theme.accentColor
                }
            }
            Text {
                anchors.left: rowIcon.right
                anchors.leftMargin: 9
                anchors.right: sizeLabel.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: row.fileName
                elide: Text.ElideMiddle
                font.family: "Inter"
                font.pixelSize: 12
                font.weight: row.selected ? Font.DemiBold : Font.Normal
                color: row.fileName.charAt(0) === "." ? Theme.textDim : Theme.textPrimary
            }
            Text {
                id: sizeLabel
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: row.fileIsDir ? "" : pane.explorer.humanSize(row.fileSize)
                font.family: "Inter"
                font.pixelSize: 11
                font.features: { "tnum": 1 }
                color: Theme.textDim
            }

            // Un dossier reçoit ce qu'on y dépose (pas lui-même).
            DropArea {
                id: rowDrop
                anchors.fill: parent
                enabled: row.fileIsDir
                keys: ["text/uri-list"]
                onEntered: (drag) => {
                    if (DragState.path === row.filePath)
                        drag.accepted = false;
                    else
                        drag.accept(Qt.CopyAction);
                }
                onDropped: (drop) => pane.explorer.dropInto(drop, row.filePath)
            }

            // Le porteur du glisser, comme les tuiles du dossier du haut.
            Item {
                id: dragProxy
                width: row.width
                height: row.height
                opacity: 0
                Drag.active: rowMa.drag.active
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction
                Drag.proposedAction: Qt.CopyAction
                Drag.mimeData: ({
                    "text/uri-list": row.carried.map(p => pane.explorer.urlOf(p) + "\r\n").join(""),
                    "text/plain": row.carried.join("\n")
                })
                Drag.onDragStarted: DragState.begin(row.filePath)
                Drag.onDragFinished: (dropAction) => {
                    DragState.end();
                    dragProxy.x = 0;
                    dragProxy.y = 0;
                    pane.explorer.dragFinished(dropAction);
                    if (dropAction !== Qt.IgnoreAction)
                        pane.selection = {};
                }
            }

            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                drag.target: dragProxy
                drag.threshold: 10
                onPressed: row.grabToImage(result => { dragProxy.Drag.imageSource = result.url; })
                onReleased: {
                    DragState.end();
                    dragProxy.x = 0;
                    dragProxy.y = 0;
                }
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        var at = rowMa.mapToItem(pane.explorer, mouse.x, mouse.y);
                        pane.explorer.showMenu(row.filePath, row.fileIsDir, true, at.x, at.y, pane.carried(row.filePath), false);
                        return;
                    }
                    var add = (mouse.modifiers & Qt.ControlModifier) !== 0;
                    pane.select(row.filePath, add);
                    // En arborescence, un clic sur un dossier le déplie.
                    if (pane.tree && row.fileIsDir && !add)
                        pane.toggleExpanded(row.filePath);
                }
                onDoubleClicked: (mouse) => {
                    if (mouse.button !== Qt.LeftButton)
                        return;
                    if (row.fileIsDir) {
                        // En arborescence, le premier clic l'a déjà déplié.
                        if (!pane.tree)
                            pane.go(row.filePath);
                    } else {
                        Quickshell.execDetached(["xdg-open", row.filePath]);
                        pane.explorer.opened();
                    }
                }
            }
        }
    }

    Text {
        anchors.centerIn: list
        visible: model.status === FolderListModel.Ready && model.count === 0
        text: I18n.tr("explorer.emptyFolder")
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textDim
    }
}
