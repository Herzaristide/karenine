pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

// Le serveur de notifications du bureau : le shell tient lui-même
// org.freedesktop.Notifications. Tout ce qui notifie passe par ici —
// notify-send, le navigateur, grimblast, et le téléphone (kdeconnectd
// envoie ses notifications ici). Un seul serveur peut tenir ce nom : ni mako,
// ni dunst à côté.
//
// Rien ne s'affiche par-dessus l'écran : une notification reçue attend dans
// l'onglet « Notifications » des widgets (widgets/NotificationCenter.qml)
// jusqu'à ce qu'on la ferme. Une éphémère (transient) s'en va seule, au bout
// du temps qu'elle demande, sinon de 10 s.
Singleton {
    id: root

    // Les notifications ouvertes, de la plus récente à la plus ancienne.
    readonly property var all: server.trackedNotifications.values.slice().reverse()

    // L'heure d'arrivée de chaque notification, par id.
    property var _times: ({})
    // Les éphémères : l'instant (ms) où chacune s'en va, par id.
    property var _expiries: ({})

    NotificationServer {
        id: server
        keepOnReload: true
        actionsSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: false
        imageSupported: true
        persistenceSupported: true
        inlineReplySupported: true

        onNotification: (n) => {
            n.tracked = true;
            var t = Object.assign({}, root._times);
            t[n.id] = new Date();
            root._times = t;
            if (n.transient) {
                var e = Object.assign({}, root._expiries);
                e[n.id] = Date.now() + (n.expireTimeout > 0 ? n.expireTimeout : 10000);
                root._expiries = e;
            }
        }
    }

    // Fait partir les éphémères arrivées à échéance.
    Timer {
        interval: 1000
        repeat: true
        running: Object.keys(root._expiries).length > 0
        onTriggered: {
            var now = Date.now();
            var e = Object.assign({}, root._expiries);
            root.all.forEach(n => {
                if (e[n.id] !== undefined && e[n.id] <= now)
                    n.expire();
            });
            // Les échues, et celles déjà fermées entre-temps.
            var open = root.all.map(n => String(n.id));
            Object.keys(e).forEach(id => {
                if (e[id] <= now || open.indexOf(id) < 0)
                    delete e[id];
            });
            root._expiries = e;
        }
    }

    function time(n) {
        var d = n ? root._times[n.id] : null;
        return d ? Qt.formatTime(d, "HH:mm") : "";
    }

    function dismiss(n) {
        n.dismiss();
    }

    function clear() {
        root.all.forEach(n => n.dismiss());
    }

    // Ferme celles d'une application : la batterie, rebranchée, retire ses
    // avertissements.
    function closeFrom(appName) {
        root.all.filter(n => n.appName === appName).forEach(n => n.dismiss());
    }

    // Ses actions, hors l'action par défaut (le clic sur la notification).
    function actionsOf(n) {
        return n ? n.actions.filter(a => a.identifier !== "default") : [];
    }

    // Une action : l'application la reçoit, et la notification se ferme si
    // elle n'est pas résidente.
    function invoke(n, action) {
        action.invoke();
    }

    // Le clic sur la notification : son action par défaut, s'il y en a une.
    function activate(n) {
        var d = n.actions.find(a => a.identifier === "default");
        if (d)
            root.invoke(n, d);
    }

    function reply(n, text) {
        n.sendInlineReply(text);
    }

    // ── Les fichiers reçus du téléphone ──────────────────────────
    // kdeconnectd ne notifie pas les fichiers qu'il reçoit : il les confie au
    // suivi des tâches de Plasma (org.kde.JobViewServer), absent ici. Mais il
    // émet `shareReceived(url)` sur le bus, une fois chaque fichier rangé
    // (dans le dossier de téléchargements) : on l'écoute, et une rafale
    // (plusieurs photos d'un coup) fait une seule notification. Un clic ouvre
    // le fichier (le dossier, s'il y en a plusieurs) ; « Dossier » ouvre le
    // dossier.
    property var _received: []

    Process {
        id: shareWatch
        running: true
        command: ["busctl", "--user", "--json=short", "monitor", "--match",
                  "type='signal',interface='org.kde.kdeconnect.device.share',member='shareReceived'"]
        stdout: SplitParser {
            onRead: (line) => {
                try {
                    var url = JSON.parse(line).payload.data[0];
                    if (url.indexOf("file://") !== 0)
                        return;
                    root._received = root._received.concat([decodeURIComponent(url.substring(7))]);
                    receivedBurst.restart();
                } catch (e) { /* « Monitoring bus… », ou un autre message */ }
            }
        }
        // busctl arrêté (bus redémarré…) : on y retourne.
        onRunningChanged: if (!running) shareWatchRetry.restart()
    }
    Timer {
        id: shareWatchRetry
        interval: 5000
        onTriggered: shareWatch.running = true
    }

    Timer {
        id: receivedBurst
        interval: 1500
        onTriggered: {
            var files = root._received;
            root._received = [];
            if (files.length > 0)
                receivedNotice.createObject(root, { files: files });
        }
    }

    function _escape(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // Une notification par rafale : notify-send attend l'action choisie et
    // l'écrit, puis l'objet s'en va.
    Component {
        id: receivedNotice
        Process {
            id: notice
            property var files: []
            readonly property string first: notice.files.length > 0 ? notice.files[0] : ""
            readonly property string dir: notice.first.substring(0, notice.first.lastIndexOf("/")) || "/"
            readonly property var names: notice.files.map(p => p.substring(p.lastIndexOf("/") + 1))
            readonly property bool image: notice.files.length === 1
                && /\.(png|jpe?g|gif|webp|heic|avif)$/i.test(notice.first)

            running: true
            command: ["notify-send", "-a", "KDE Connect",
                      "-i", notice.image ? notice.first : "kdeconnect",
                      "-A", "default=" + I18n.tr("common.open"),
                      "-A", "folder=" + I18n.tr("phone.folder"),
                      I18n.trn("phone.received", notice.files.length),
                      root._escape(notice.names.slice(0, 4).join("\n")
                          + (notice.names.length > 4 ? "\n" + I18n.tr("phone.andMore", { n: notice.names.length - 4 }) : ""))]
            stdout: StdioCollector {
                onStreamFinished: {
                    var action = text.trim();
                    if (action === "default" && notice.files.length === 1)
                        Quickshell.execDetached(["xdg-open", notice.files[0]]);
                    else if (action === "default" || action === "folder")
                        DefaultApps.openInExplorer(notice.dir);
                    notice.destroy();
                }
            }
        }
    }

    // L'icône à montrer : son image (une photo, un aperçu), sinon l'icône
    // de l'application, sinon celle de son entrée de bureau. Vide quand le
    // thème ne la connaît pas : la carte s'en passe.
    function iconOf(n) {
        if (!n)
            return "";
        // Un nom d'icône passé en image arrive en image://icon/<nom>.
        var themed = "image://icon/";
        if (n.image && !n.image.startsWith(themed))
            return n.image;
        var names = [n.image ? n.image.substring(themed.length) : "", n.appIcon];
        var entry = n.desktopEntry ? DesktopEntries.byId(n.desktopEntry)
                  : DesktopEntries.heuristicLookup(n.appName);
        if (entry)
            names.push(entry.icon);
        for (var i = 0; i < names.length; i++) {
            var icon = names[i];
            if (!icon)
                continue;
            if (icon.startsWith("/"))
                return "file://" + icon;
            if (icon.indexOf("://") >= 0)
                return icon;
            // Adwaita n'a souvent que la variante symbolique
            // (dialog-information-symbolic).
            var path = Quickshell.iconPath(icon, true) || Quickshell.iconPath(icon + "-symbolic", true);
            if (path)
                return path;
        }
        return "";
    }
}
